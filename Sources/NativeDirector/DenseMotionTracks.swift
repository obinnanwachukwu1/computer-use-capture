import CoreGraphics
import Foundation

/// One loss-preserving field sample supplied to the offline lifecycle solver.
/// Only material tiles are required; their exact masks remain attached to the
/// resulting track samples and are never reconstructed from bounding boxes.
public struct DenseMotionSample: Sendable {
    public let time: Double
    public let tileColumns: Int
    public let tileRows: Int
    public let tiles: [MotionEvidenceTile]

    public init(
        time: Double,
        tileColumns: Int,
        tileRows: Int,
        tiles: [MotionEvidenceTile]
    ) {
        self.time = time
        self.tileColumns = tileColumns
        self.tileRows = tileRows
        self.tiles = tiles
    }
}

/// Global space-time grouping over dense motion evidence.
///
/// This is deliberately not an attention model. A track says that several
/// changed regions are most economically explained as one continuing visual
/// object hypothesis. It does not say that the camera should frame that object.
public struct DenseMotionTrackGraph: Sendable {
    public struct Component: Sendable {
        public let id: Int
        public let time: Double
        public let normalizedBounds: CGRect
        public let tileIndices: [Int]
        public let channelWeights: [MotionEvidenceChannel: Double]
        public let energy: Double
        public let confidence: Double
        /// Positive means the current frame carries more local detail than the
        /// previous frame in this exact mask; negative means detail was
        /// removed or occluded. This is evidence, not a semantic role.
        public let detailPolarity: Double
        public let meanLuminanceDelta: Double
    }

    public struct Track: Sendable {
        public let id: Int
        public let componentIDs: [Int]
        public let startTime: Double
        public let endTime: Double
        public let normalizedBounds: CGRect
        public let maximumGap: Double
        public let continuityConfidence: Double
        public let isBroadContext: Bool
        public let entryDetailPolarity: Double
        public let releaseDetailPolarity: Double
    }

    public let components: [Component]
    public let tracks: [Track]

    public static func make(
        samples: [DenseMotionSample],
        maximumGap: Double = 6.0,
        minimumLinkScore: Double = 1.35
    ) -> DenseMotionTrackGraph {
        let orderedSamples = samples.sorted { $0.time < $1.time }
        var components: [Component] = []
        for sample in orderedSamples {
            components += spatialComponents(sample: sample, firstID: components.count)
        }
        guard !components.isEmpty else { return DenseMotionTrackGraph(components: [], tracks: []) }

        var candidates: [TemporalLink] = []
        for left in components.indices {
            for right in (left + 1)..<components.count {
                let dt = components[right].time - components[left].time
                if dt <= 0 { continue }
                if dt > maximumGap { break }
                guard let score = temporalCompatibility(
                    components[left], components[right], deltaTime: dt
                ), score >= minimumLinkScore else { continue }
                candidates.append(TemporalLink(left: left, right: right, score: score))
            }
        }
        let selected = maximumWeightPathCover(
            nodeCount: components.count,
            links: candidates,
            minimumScore: minimumLinkScore
        )
        var successor: [Int: Int] = [:]
        var predecessor: [Int: Int] = [:]
        var scores: [Pair: Double] = [:]
        for link in selected {
            successor[link.left] = link.right
            predecessor[link.right] = link.left
            scores[Pair(left: link.left, right: link.right)] = link.score
        }

        var tracks: [Track] = []
        for start in components.indices where predecessor[start] == nil {
            var chain = [start]
            while let next = successor[chain.last!] { chain.append(next) }
            let members = chain.map { components[$0] }
            let union = members.dropFirst().reduce(members[0].normalizedBounds) {
                $0.union($1.normalizedBounds)
            }
            let gaps = zip(members, members.dropFirst()).map { $1.time - $0.time }
            let linkScores = zip(chain, chain.dropFirst()).compactMap {
                scores[Pair(left: $0, right: $1)]
            }
            let confidence = linkScores.isEmpty
                ? 0
                : min(1, linkScores.reduce(0, +) / Double(linkScores.count) / 3.4)
            let polarity = lifecyclePolarities(members)
            tracks.append(Track(
                id: tracks.count,
                componentIDs: members.map(\.id),
                startTime: members.first!.time,
                endTime: members.last!.time,
                normalizedBounds: union,
                maximumGap: gaps.max() ?? 0,
                continuityConfidence: confidence,
                isBroadContext: union.width * union.height >= 0.58
                    || (union.width >= 0.88 && union.height >= 0.42),
                entryDetailPolarity: polarity.entry,
                releaseDetailPolarity: polarity.release
            ))
        }
        tracks.sort {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.normalizedBounds.minY != $1.normalizedBounds.minY {
                return $0.normalizedBounds.minY < $1.normalizedBounds.minY
            }
            return $0.normalizedBounds.minX < $1.normalizedBounds.minX
        }
        let canonical = tracks.enumerated().map { index, track in
            Track(
                id: index,
                componentIDs: track.componentIDs,
                startTime: track.startTime,
                endTime: track.endTime,
                normalizedBounds: track.normalizedBounds,
                maximumGap: track.maximumGap,
                continuityConfidence: track.continuityConfidence,
                isBroadContext: track.isBroadContext,
                entryDetailPolarity: track.entryDetailPolarity,
                releaseDetailPolarity: track.releaseDetailPolarity
            )
        }
        return DenseMotionTrackGraph(components: components, tracks: canonical)
    }
}

private struct TemporalLink {
    let left: Int
    let right: Int
    let score: Double
}

private struct Pair: Hashable {
    let left: Int
    let right: Int
}

private func spatialComponents(
    sample: DenseMotionSample,
    firstID: Int
) -> [DenseMotionTrackGraph.Component] {
    let material = Dictionary(uniqueKeysWithValues: sample.tiles
        .filter { $0.channel != .unchanged }
        .map { ($0.index, $0) })
    var remaining = Set(material.keys)
    var result: [DenseMotionTrackGraph.Component] = []
    while let seed = remaining.min() {
        remaining.remove(seed)
        var queue = [seed]
        var cursor = 0
        var indices: [Int] = []
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            indices.append(index)
            let x = index % sample.tileColumns
            let y = index / sample.tileColumns
            // Two-tile connectivity binds the sparse edges/textures of one UI
            // surface without filling the space between them. The exact mask
            // remains `indices`; this radius affects only the hypothesis graph.
            for dy in -2...2 {
                for dx in -2...2 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0,
                          nx < sample.tileColumns, ny < sample.tileRows
                    else { continue }
                    let neighbor = ny * sample.tileColumns + nx
                    if remaining.remove(neighbor) != nil { queue.append(neighbor) }
                }
            }
        }
        let tiles = indices.compactMap { material[$0] }
        guard let first = tiles.first else { continue }
        let bounds = tiles.dropFirst().reduce(first.normalizedBounds) {
            $0.union($1.normalizedBounds)
        }
        var channelWeights: [MotionEvidenceChannel: Double] = [:]
        var energyWeight = 0.0
        var confidenceWeight = 0.0
        var detailPolarityWeight = 0.0
        var luminanceWeight = 0.0
        for tile in tiles {
            let weight = max(0.001, tile.changedFraction * max(0.05, tile.energy))
            channelWeights[tile.channel, default: 0] += weight
            energyWeight += tile.energy * weight
            confidenceWeight += tile.confidence * weight
            let detailDenominator = max(1, abs(tile.afterDetail) + abs(tile.beforeDetail))
            detailPolarityWeight += (tile.afterDetail - tile.beforeDetail) / detailDenominator * weight
            luminanceWeight += tile.meanLuminanceDelta * weight
        }
        let total = max(0.001, channelWeights.values.reduce(0, +))
        result.append(DenseMotionTrackGraph.Component(
            id: firstID + result.count,
            time: sample.time,
            normalizedBounds: bounds,
            tileIndices: indices.sorted(),
            channelWeights: channelWeights.mapValues { $0 / total },
            energy: energyWeight / total,
            confidence: confidenceWeight / total,
            detailPolarity: detailPolarityWeight / total,
            meanLuminanceDelta: luminanceWeight / total
        ))
    }
    return result
}

private func lifecyclePolarities(
    _ components: [DenseMotionTrackGraph.Component]
) -> (entry: Double, release: Double) {
    guard components.count > 1 else {
        let value = components.first?.detailPolarity ?? 0
        return (value, value)
    }
    let gaps = zip(components.indices, components.indices.dropFirst()).map { index, next in
        (index: index, duration: components[next].time - components[index].time)
    }
    let largest = gaps.max { $0.duration < $1.duration }
    let entry: ArraySlice<DenseMotionTrackGraph.Component>
    let release: ArraySlice<DenseMotionTrackGraph.Component>
    if let largest, largest.duration >= 0.75 {
        entry = components[...largest.index]
        release = components[(largest.index + 1)...]
    } else {
        let shoulder = max(1, components.count / 3)
        entry = components.prefix(shoulder)
        release = components.suffix(shoulder)
    }
    func average(_ values: ArraySlice<DenseMotionTrackGraph.Component>) -> Double {
        let weighted = values.map { component in
            let area = component.normalizedBounds.width * component.normalizedBounds.height
            return (value: component.detailPolarity, weight: max(0.000_1, area * max(0.05, component.energy)))
        }
        let total = weighted.reduce(0.0) { $0 + $1.weight }
        return weighted.reduce(0.0) { $0 + $1.value * $1.weight } / max(0.000_1, total)
    }
    return (average(entry), average(release))
}

private func temporalCompatibility(
    _ left: DenseMotionTrackGraph.Component,
    _ right: DenseMotionTrackGraph.Component,
    deltaTime: Double
) -> Double? {
    let shared = left.normalizedBounds.intersection(right.normalizedBounds)
    let leftArea = max(0.000_001, left.normalizedBounds.width * left.normalizedBounds.height)
    let rightArea = max(0.000_001, right.normalizedBounds.width * right.normalizedBounds.height)
    let overlap = shared.isNull ? 0 : shared.width * shared.height / min(leftArea, rightArea)
    let dx = left.normalizedBounds.midX - right.normalizedBounds.midX
    let dy = left.normalizedBounds.midY - right.normalizedBounds.midY
    let distance = hypot(dx, dy)
    let spatialScale = max(
        0.035,
        0.5 * max(
            hypot(left.normalizedBounds.width, left.normalizedBounds.height),
            hypot(right.normalizedBounds.width, right.normalizedBounds.height)
        )
    )
    guard overlap >= 0.12 || distance <= spatialScale else { return nil }
    if deltaTime > 1.0, overlap < 0.34 || distance > max(0.06, spatialScale * 0.82) {
        return nil
    }
    let distanceScore = exp(-distance / spatialScale)
    let sizeScore = min(leftArea, rightArea) / max(leftArea, rightArea)
    let channels = Set(left.channelWeights.keys).union(right.channelWeights.keys)
    let channelScore = channels.reduce(0.0) {
        $0 + sqrt((left.channelWeights[$1] ?? 0) * (right.channelWeights[$1] ?? 0))
    }
    let gapPenalty = min(1.4, max(0, deltaTime - 0.20) * 0.16)
    return overlap * 2.15
        + distanceScore * 1.05
        + sizeScore * 0.48
        + channelScore * 0.38
        - gapPenalty
}

/// Sparse min-cost flow produces a global maximum-weight predecessor/successor
/// assignment. Residual edges permit earlier choices to be revised; this is
/// the important distinction from the previous greedy overlap tracker.
private func maximumWeightPathCover(
    nodeCount: Int,
    links: [TemporalLink],
    minimumScore: Double
) -> [TemporalLink] {
    struct Edge {
        var to: Int
        var reverse: Int
        var capacity: Int
        var cost: Double
        var link: TemporalLink?
    }
    let source = nodeCount * 2
    let sink = source + 1
    var graph = [[Edge]](repeating: [], count: sink + 1)
    func addEdge(_ from: Int, _ to: Int, _ capacity: Int, _ cost: Double, _ link: TemporalLink? = nil) {
        let forward = Edge(to: to, reverse: graph[to].count, capacity: capacity, cost: cost, link: link)
        let reverse = Edge(to: from, reverse: graph[from].count, capacity: 0, cost: -cost, link: nil)
        graph[from].append(forward)
        graph[to].append(reverse)
    }
    for node in 0..<nodeCount {
        addEdge(source, node, 1, 0)
        addEdge(nodeCount + node, sink, 1, 0)
    }
    for link in links { addEdge(link.left, nodeCount + link.right, 1, -link.score, link) }

    while true {
        var distance = [Double](repeating: .infinity, count: graph.count)
        var parentVertex = [Int](repeating: -1, count: graph.count)
        var parentEdge = [Int](repeating: -1, count: graph.count)
        var queued = [Bool](repeating: false, count: graph.count)
        var queue = [source]
        distance[source] = 0
        queued[source] = true
        var cursor = 0
        while cursor < queue.count {
            let vertex = queue[cursor]
            cursor += 1
            queued[vertex] = false
            for edgeIndex in graph[vertex].indices {
                let edge = graph[vertex][edgeIndex]
                guard edge.capacity > 0,
                      distance[vertex] + edge.cost < distance[edge.to] - 0.000_000_1
                else { continue }
                distance[edge.to] = distance[vertex] + edge.cost
                parentVertex[edge.to] = vertex
                parentEdge[edge.to] = edgeIndex
                if !queued[edge.to] {
                    queued[edge.to] = true
                    queue.append(edge.to)
                }
            }
        }
        // Every candidate edge was already gated by `minimumScore`. An
        // augmenting path may replace one strong edge with two strong edges,
        // so its *marginal* gain can be smaller than that gate. Continue while
        // the global objective improves at all.
        guard distance[sink] < -0.000_000_1 else { break }
        var vertex = sink
        while vertex != source {
            let parent = parentVertex[vertex]
            let edgeIndex = parentEdge[vertex]
            guard parent >= 0, edgeIndex >= 0 else { break }
            let reverse = graph[parent][edgeIndex].reverse
            graph[parent][edgeIndex].capacity -= 1
            graph[vertex][reverse].capacity += 1
            vertex = parent
        }
    }
    var selected: [TemporalLink] = []
    for left in 0..<nodeCount {
        for edge in graph[left] where edge.link != nil && edge.capacity == 0 {
            selected.append(edge.link!)
        }
    }
    return selected.sorted {
        if $0.left != $1.left { return $0.left < $1.left }
        return $0.right < $1.right
    }
}
