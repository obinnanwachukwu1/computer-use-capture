import CoreGraphics
import Foundation

public struct DenseTransportFrame: Sendable {
    public let time: Double
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init(time: Double, width: Int, height: Int, pixels: [UInt8]) {
        self.time = time
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Appearance-conditioned surfaces that move without requiring their flat
/// interiors to exceed the material frame-difference threshold.
///
/// This remains observational evidence. A transport track says that one
/// low-contrast surface is consistently displaced through time; it does not
/// decide whether the camera should follow it.
public struct DenseMotionTransportGraph: Sendable {
    public struct Component: Sendable {
        public let id: Int
        public let time: Double
        public let normalizedBounds: CGRect
        public let pixelCount: Int
        public let rectangularity: Double
        public let meanRed: Double
        public let meanGreen: Double
        public let meanBlue: Double
    }

    public enum Axis: String, Sendable {
        case horizontal
        case vertical
    }

    public struct Track: Sendable {
        public let id: Int
        public let componentIDs: [Int]
        public let startTime: Double
        public let endTime: Double
        public let dominantAxis: Axis
        public let normalizedTravel: Double
        public let directionalCoherence: Double
        public let confidence: Double
    }

    public let components: [Component]
    public let tracks: [Track]

    public static func make(
        frames: [DenseTransportFrame],
        evidence: DenseMotionTrackGraph? = nil,
        quantizationStep: Int = 6
    ) -> DenseMotionTransportGraph {
        let orderedFrames = frames.sorted { $0.time < $1.time }
        guard let first = orderedFrames.first,
              first.width > 0, first.height > 0,
              first.pixels.count == first.width * first.height * 4
        else { return DenseMotionTransportGraph(components: [], tracks: []) }

        var components: [Component] = []
        var byFrame: [[Int]] = []
        for frame in orderedFrames {
            guard frame.width == first.width, frame.height == first.height,
                  frame.pixels.count == first.pixels.count
            else { continue }
            let extracted = appearanceComponents(
                frame: frame,
                firstID: components.count,
                quantizationStep: max(2, quantizationStep)
            )
            byFrame.append(Array(components.count..<(components.count + extracted.count)))
            components += extracted
        }
        guard byFrame.count >= 2, !components.isEmpty else {
            return DenseMotionTransportGraph(components: components, tracks: [])
        }

        var successor: [Int: Int] = [:]
        var predecessor: [Int: Int] = [:]
        for frameIndex in 0..<(byFrame.count - 1) {
            let left = byFrame[frameIndex], right = byFrame[frameIndex + 1]
            var bestRight: [Int: (id: Int, score: Double)] = [:]
            var bestLeft: [Int: (id: Int, score: Double)] = [:]
            for leftID in left {
                for rightID in right {
                    guard let score = transportCompatibility(components[leftID], components[rightID]) else {
                        continue
                    }
                    if isBetter(score: score, id: rightID, than: bestRight[leftID]) {
                        bestRight[leftID] = (rightID, score)
                    }
                    if isBetter(score: score, id: leftID, than: bestLeft[rightID]) {
                        bestLeft[rightID] = (leftID, score)
                    }
                }
            }
            for (leftID, match) in bestRight where match.score >= 0.68 {
                guard bestLeft[match.id]?.id == leftID else { continue }
                successor[leftID] = match.id
                predecessor[match.id] = leftID
            }
        }

        let evidenceComponents = evidence?.components ?? []
        var accepted: [(members: [Component], axis: Axis, travel: Double, coherence: Double, confidence: Double)] = []
        for start in components.indices where predecessor[start] == nil {
            var chain = [start]
            while let next = successor[chain.last!] { chain.append(next) }
            let members = chain.map { components[$0] }
            guard members.count >= 4 else { continue }
            let metrics = trajectoryMetrics(members)
            guard metrics.movingSteps >= 3,
                  metrics.span >= 0.025,
                  metrics.coherence >= 0.58,
                  metrics.medianArea >= 0.0025,
                  metrics.meanRectangularity >= 0.52
            else { continue }
            if !evidenceComponents.isEmpty {
                let support = members.reduce(0) { count, member in
                    count + (evidenceComponents.contains {
                        abs($0.time - member.time) <= 0.09
                            && $0.normalizedBounds.intersects(member.normalizedBounds)
                    } ? 1 : 0)
                }
                guard support >= 2 else { continue }
            }
            let confidence = min(1,
                metrics.coherence * 0.38
                    + min(1, metrics.span / 0.14) * 0.34
                    + metrics.meanRectangularity * 0.28
            )
            accepted.append((members, metrics.axis, metrics.travel, metrics.coherence, confidence))
        }

        accepted.sort {
            if $0.members[0].time != $1.members[0].time { return $0.members[0].time < $1.members[0].time }
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            return $0.members[0].id < $1.members[0].id
        }
        let tracks = accepted.enumerated().map { id, item in
            Track(
                id: id,
                componentIDs: item.members.map(\.id),
                startTime: item.members.first!.time,
                endTime: item.members.last!.time,
                dominantAxis: item.axis,
                normalizedTravel: item.travel,
                directionalCoherence: item.coherence,
                confidence: item.confidence
            )
        }
        return DenseMotionTransportGraph(components: components, tracks: tracks)
    }
}

private func appearanceComponents(
    frame: DenseTransportFrame,
    firstID: Int,
    quantizationStep: Int
) -> [DenseMotionTransportGraph.Component] {
    let pixelCount = frame.width * frame.height
    var labels = [Int](repeating: 0, count: pixelCount)
    for pixel in 0..<pixelCount {
        let offset = pixel * 4
        let red = Int(frame.pixels[offset]) / quantizationStep
        let green = Int(frame.pixels[offset + 1]) / quantizationStep
        let blue = Int(frame.pixels[offset + 2]) / quantizationStep
        labels[pixel] = (red << 12) | (green << 6) | blue
    }
    var visited = [Bool](repeating: false, count: pixelCount)
    let minimumPixels = max(40, Int(Double(pixelCount) * 0.0015))
    let maximumPixels = Int(Double(pixelCount) * 0.34)
    var result: [DenseMotionTransportGraph.Component] = []
    var queue: [Int] = []
    queue.reserveCapacity(pixelCount / 8)

    for seed in 0..<pixelCount where !visited[seed] {
        visited[seed] = true
        queue.removeAll(keepingCapacity: true)
        queue.append(seed)
        var cursor = 0
        let label = labels[seed]
        var count = 0, minX = frame.width, maxX = 0, minY = frame.height, maxY = 0
        var redSum = 0.0, greenSum = 0.0, blueSum = 0.0
        while cursor < queue.count {
            let pixel = queue[cursor]
            cursor += 1
            let x = pixel % frame.width, y = pixel / frame.width
            count += 1
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            let offset = pixel * 4
            redSum += Double(frame.pixels[offset])
            greenSum += Double(frame.pixels[offset + 1])
            blueSum += Double(frame.pixels[offset + 2])
            if x > 0 {
                let next = pixel - 1
                if !visited[next] && labels[next] == label { visited[next] = true; queue.append(next) }
            }
            if x + 1 < frame.width {
                let next = pixel + 1
                if !visited[next] && labels[next] == label { visited[next] = true; queue.append(next) }
            }
            if y > 0 {
                let next = pixel - frame.width
                if !visited[next] && labels[next] == label { visited[next] = true; queue.append(next) }
            }
            if y + 1 < frame.height {
                let next = pixel + frame.width
                if !visited[next] && labels[next] == label { visited[next] = true; queue.append(next) }
            }
        }
        guard count >= minimumPixels, count <= maximumPixels else { continue }
        let boxWidth = maxX - minX + 1, boxHeight = maxY - minY + 1
        guard boxWidth >= 8, boxHeight >= 8,
              Double(boxWidth) / Double(frame.width) >= 0.025,
              Double(boxHeight) / Double(frame.height) >= 0.025
        else { continue }
        let rectangularity = Double(count) / Double(boxWidth * boxHeight)
        guard rectangularity >= 0.42 else { continue }
        result.append(DenseMotionTransportGraph.Component(
            id: firstID + result.count,
            time: frame.time,
            normalizedBounds: CGRect(
                x: Double(minX) / Double(frame.width),
                y: Double(minY) / Double(frame.height),
                width: Double(boxWidth) / Double(frame.width),
                height: Double(boxHeight) / Double(frame.height)
            ),
            pixelCount: count,
            rectangularity: rectangularity,
            meanRed: redSum / Double(count),
            meanGreen: greenSum / Double(count),
            meanBlue: blueSum / Double(count)
        ))
    }
    return result.sorted {
        if $0.pixelCount != $1.pixelCount { return $0.pixelCount > $1.pixelCount }
        if $0.normalizedBounds.minY != $1.normalizedBounds.minY {
            return $0.normalizedBounds.minY < $1.normalizedBounds.minY
        }
        return $0.normalizedBounds.minX < $1.normalizedBounds.minX
    }.prefix(32).enumerated().map { index, component in
        DenseMotionTransportGraph.Component(
            id: firstID + index,
            time: component.time,
            normalizedBounds: component.normalizedBounds,
            pixelCount: component.pixelCount,
            rectangularity: component.rectangularity,
            meanRed: component.meanRed,
            meanGreen: component.meanGreen,
            meanBlue: component.meanBlue
        )
    }
}

private func transportCompatibility(
    _ left: DenseMotionTransportGraph.Component,
    _ right: DenseMotionTransportGraph.Component
) -> Double? {
    let colorDistance = sqrt(
        pow(left.meanRed - right.meanRed, 2)
            + pow(left.meanGreen - right.meanGreen, 2)
            + pow(left.meanBlue - right.meanBlue, 2)
    )
    let areaRatio = Double(min(left.pixelCount, right.pixelCount)) / Double(max(left.pixelCount, right.pixelCount))
    let widthRatio = min(left.normalizedBounds.width, right.normalizedBounds.width)
        / max(left.normalizedBounds.width, right.normalizedBounds.width)
    let heightRatio = min(left.normalizedBounds.height, right.normalizedBounds.height)
        / max(left.normalizedBounds.height, right.normalizedBounds.height)
    let distance = hypot(
        left.normalizedBounds.midX - right.normalizedBounds.midX,
        left.normalizedBounds.midY - right.normalizedBounds.midY
    )
    guard colorDistance <= 12, areaRatio >= 0.45,
          widthRatio >= 0.48, heightRatio >= 0.48,
          distance <= 0.18
    else { return nil }
    let colorScore = exp(-colorDistance / 7)
    let distanceScore = exp(-distance / 0.08)
    let shapeScore = sqrt(widthRatio * heightRatio)
    let occupancyScore = min(left.rectangularity, right.rectangularity)
    return colorScore * 0.25
        + areaRatio * 0.22
        + shapeScore * 0.20
        + distanceScore * 0.20
        + occupancyScore * 0.13
}

private func isBetter(
    score: Double,
    id: Int,
    than current: (id: Int, score: Double)?
) -> Bool {
    guard let current else { return true }
    return score > current.score + 0.000_000_1
        || (abs(score - current.score) <= 0.000_000_1 && id < current.id)
}

private func trajectoryMetrics(
    _ components: [DenseMotionTransportGraph.Component]
) -> (
    axis: DenseMotionTransportGraph.Axis,
    travel: Double,
    span: Double,
    coherence: Double,
    movingSteps: Int,
    medianArea: Double,
    meanRectangularity: Double
) {
    let centers = components.map { CGPoint(x: $0.normalizedBounds.midX, y: $0.normalizedBounds.midY) }
    let steps = zip(centers, centers.dropFirst()).map { (dx: $1.x - $0.x, dy: $1.y - $0.y) }
    let xTravel = steps.reduce(0.0) { $0 + abs($1.dx) }
    let yTravel = steps.reduce(0.0) { $0 + abs($1.dy) }
    let axis: DenseMotionTransportGraph.Axis = xTravel >= yTravel ? .horizontal : .vertical
    let signed = axis == .horizontal ? steps.map(\.dx) : steps.map(\.dy)
    let travel = signed.reduce(0.0) { $0 + abs($1) }
    let coherence = abs(signed.reduce(0, +)) / max(0.000_001, travel)
    let positions = axis == .horizontal ? centers.map(\.x) : centers.map(\.y)
    let span = (positions.max() ?? 0) - (positions.min() ?? 0)
    let movingSteps = signed.filter { abs($0) >= 0.0025 }.count
    let areas = components.map { $0.normalizedBounds.width * $0.normalizedBounds.height }.sorted()
    return (
        axis,
        travel,
        span,
        coherence,
        movingSteps,
        areas[areas.count / 2],
        components.map(\.rectangularity).reduce(0, +) / Double(components.count)
    )
}
