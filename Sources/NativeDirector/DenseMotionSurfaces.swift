import CoreGraphics
import Foundation

public struct DenseMotionRasterFrame: Sendable {
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

/// A foreground-support veil inferred from the complete lifecycle rather than
/// a single frame difference. The held frame must differ from both the scene
/// before birth and the scene after release, which suppresses unrelated edits
/// that occur on only one side of a transient surface.
public struct DenseMotionSurfaceGraph: Sendable {
    public struct Surface: Sendable {
        public let objectID: Int
        public let normalizedBounds: CGRect
        public let tileIndices: [Int]
        public let beforeTime: Double
        public let heldTime: Double
        public let afterTime: Double
        public let confidence: Double
    }

    public let surfaces: [Surface]

    public static func make(
        tracks: DenseMotionTrackGraph,
        objects: DenseMotionObjectGraph,
        frames: [DenseMotionRasterFrame],
        tileColumns: Int,
        tileRows: Int
    ) -> DenseMotionSurfaceGraph {
        guard let firstFrame = frames.first,
              firstFrame.pixels.count == firstFrame.width * firstFrame.height * 4,
              tileColumns > 0, tileRows > 0
        else { return DenseMotionSurfaceGraph(surfaces: []) }
        let orderedFrames = frames.sorted { $0.time < $1.time }
        let components = Dictionary(uniqueKeysWithValues: tracks.components.map { ($0.id, $0) })
        let trackByID = Dictionary(uniqueKeysWithValues: tracks.tracks.map { ($0.id, $0) })
        var result: [Surface] = []

        for object in objects.ensembles where object.kind == .compactObject {
            let memberTracks = object.trackIDs.compactMap { trackByID[$0] }
            let memberComponents = memberTracks.flatMap { track in
                track.componentIDs.compactMap { components[$0] }
            }.sorted { $0.time < $1.time }
            guard memberComponents.count >= 2,
                  let hold = strongestStaticHold(memberComponents),
                  hold.duration >= 0.75,
                  let before = orderedFrames.last(where: { $0.time < object.startTime - 0.04 }),
                  let held = orderedFrames.min(by: {
                      abs($0.time - hold.midpoint) < abs($1.time - hold.midpoint)
                  }),
                  let after = orderedFrames.first(where: { $0.time > object.endTime + 0.04 }),
                  before.width == held.width, held.width == after.width,
                  before.height == held.height, held.height == after.height
            else { continue }

            let seedTiles = Set(memberComponents.flatMap(\.tileIndices))
            guard let support = bidirectionalSupport(
                before: before,
                held: held,
                after: after,
                seedTiles: seedTiles,
                evidenceBounds: object.normalizedBounds,
                tileColumns: tileColumns,
                tileRows: tileRows
            ) else { continue }
            result.append(Surface(
                objectID: object.id,
                normalizedBounds: support.bounds,
                tileIndices: support.tiles,
                beforeTime: before.time,
                heldTime: held.time,
                afterTime: after.time,
                confidence: support.confidence
            ))
        }
        return DenseMotionSurfaceGraph(surfaces: result.sorted { $0.objectID < $1.objectID })
    }
}

private func strongestStaticHold(
    _ components: [DenseMotionTrackGraph.Component]
) -> (duration: Double, midpoint: Double)? {
    let times = components.map(\.time).sorted().reduce(into: [Double]()) { result, time in
        if result.last.map({ abs($0 - time) > 0.04 }) ?? true { result.append(time) }
    }
    guard times.count >= 2 else { return nil }
    return zip(times, times.dropFirst()).map { left, right in
        (duration: right - left, midpoint: (left + right) * 0.5)
    }.max { $0.duration < $1.duration }
}

private func bidirectionalSupport(
    before: DenseMotionRasterFrame,
    held: DenseMotionRasterFrame,
    after: DenseMotionRasterFrame,
    seedTiles: Set<Int>,
    evidenceBounds _: CGRect,
    tileColumns: Int,
    tileRows: Int
) -> (bounds: CGRect, tiles: [Int], confidence: Double)? {
    let width = held.width, height = held.height
    var active: Set<Int> = []
    var tileScores: [Int: Double] = [:]
    var supportedPixels: [Int: [Int]] = [:]

    for tileY in 0..<tileRows {
        for tileX in 0..<tileColumns {
            let tile = tileY * tileColumns + tileX
            let x0 = tileX * width / tileColumns
            let x1 = max(x0 + 1, (tileX + 1) * width / tileColumns)
            let y0 = tileY * height / tileRows
            let y1 = max(y0 + 1, (tileY + 1) * height / tileRows)
            var pixels: [Int] = []
            var totalScore = 0.0
            var material = 0
            for y in y0..<min(height, y1) {
                for x in x0..<min(width, x1) {
                    let pixel = y * width + x
                    let entry = pixelDelta(before.pixels, held.pixels, pixel: pixel)
                    let release = pixelDelta(after.pixels, held.pixels, pixel: pixel)
                    let score = min(entry, release)
                    totalScore += Double(score)
                    if score >= 10 {
                        material += 1
                        pixels.append(pixel)
                    }
                }
            }
            let count = max(1, (min(height, y1) - y0) * (min(width, x1) - x0))
            let fraction = Double(material) / Double(count)
            let mean = totalScore / Double(count)
            if (fraction >= 0.12 && mean >= 4.0) || fraction >= 0.28 {
                active.insert(tile)
                tileScores[tile] = fraction * min(1, mean / 24)
                supportedPixels[tile] = pixels
            }
        }
    }
    guard !active.isEmpty else { return nil }

    var components: [[Int]] = []
    var remaining = active
    while let seed = remaining.min() {
        remaining.remove(seed)
        var queue = [seed], cursor = 0, component: [Int] = []
        while cursor < queue.count {
            let tile = queue[cursor]
            cursor += 1
            component.append(tile)
            let x = tile % tileColumns, y = tile / tileColumns
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < tileColumns, ny < tileRows else { continue }
                    let neighbor = ny * tileColumns + nx
                    if remaining.remove(neighbor) != nil { queue.append(neighbor) }
                }
            }
        }
        components.append(component.sorted())
    }
    let ranked = components.map { tiles -> (tiles: [Int], overlap: Int, score: Double) in
        let overlap = tiles.reduce(0) { $0 + (seedTiles.contains($1) ? 1 : 0) }
        let score = tiles.reduce(0.0) { $0 + (tileScores[$1] ?? 0) }
        return (tiles, overlap, score)
    }.filter { $0.overlap > 0 }
    guard let chosen = ranked.max(by: {
        if $0.overlap != $1.overlap { return $0.overlap < $1.overlap }
        return $0.score < $1.score
    }) else { return nil }

    let pixels = chosen.tiles.flatMap { supportedPixels[$0] ?? [] }
    guard let first = pixels.first else { return nil }
    var minX = first % width, maxX = minX, minY = first / width, maxY = minY
    for pixel in pixels.dropFirst() {
        let x = pixel % width, y = pixel / width
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
    }
    let bounds = CGRect(
        x: Double(minX) / Double(width),
        y: Double(minY) / Double(height),
        width: Double(maxX - minX + 1) / Double(width),
        height: Double(maxY - minY + 1) / Double(height)
    )
    let confidence = min(1, chosen.score / Double(max(1, chosen.tiles.count)) * 1.7)
    return (bounds, chosen.tiles, confidence)
}

private func pixelDelta(_ left: [UInt8], _ right: [UInt8], pixel: Int) -> UInt8 {
    let offset = pixel * 4
    return max(
        UInt8(abs(Int(left[offset]) - Int(right[offset]))),
        UInt8(abs(Int(left[offset + 1]) - Int(right[offset + 1]))),
        UInt8(abs(Int(left[offset + 2]) - Int(right[offset + 2])))
    )
}
