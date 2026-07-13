import CoreGraphics
import Foundation

public struct DetectedMotionComponent: Sendable {
    public let normalizedBounds: CGRect
    public let changedFraction: Double
    public let magnitude: Double
    public let kind: VisualMotionKind

    public init(normalizedBounds: CGRect, changedFraction: Double, magnitude: Double, kind: VisualMotionKind) {
        self.normalizedBounds = normalizedBounds
        self.changedFraction = changedFraction
        self.magnitude = magnitude
        self.kind = kind
    }
}

public enum SpatialMotion {
    /// Localized translations immediately following activation are part of
    /// the action response (for example chart bars changing height or a
    /// disclosure expanding). Broad coherent translation still describes the
    /// viewport itself moving and remains excluded from attention framing.
    public static func postActivationResponseComponents(
        _ components: [DetectedMotionComponent],
        broadTranslationCoverage: CGFloat = 0.42
    ) -> [DetectedMotionComponent] {
        let translated = components.filter { $0.kind == .translation }
        guard !translated.isEmpty else { return components }
        let union = translated.dropFirst().reduce(translated[0].normalizedBounds) {
            $0.union($1.normalizedBounds)
        }
        guard union.width * union.height < broadTranslationCoverage else { return components }
        return components.map { component in
            guard component.kind == .translation else { return component }
            return DetectedMotionComponent(
                normalizedBounds: component.normalizedBounds,
                changedFraction: component.changedFraction,
                magnitude: component.magnitude,
                kind: .transformation
            )
        }
    }

    /// Removes response regions that were already moving immediately before
    /// an action. The remaining components are plausible action-caused
    /// changes rather than ambient animation elsewhere in the UI.
    public static func causalComponents(
        baseline: [DetectedMotionComponent],
        response: [DetectedMotionComponent],
        overlapThreshold: CGFloat = 0.35
    ) -> [DetectedMotionComponent] {
        response.filter { candidate in
            !baseline.contains { existing in
                candidate.normalizedBounds.overlapRatio(with: existing.normalizedBounds) >= overlapThreshold
            }
        }
    }

    public static func components(
        previous: [UInt8], current: [UInt8], width: Int, height: Int,
        channelThreshold: Int = 20, changedPixelFraction: Double = 0.00004,
        tileSize: Int = 8, classifyTranslations: Bool = true
    ) -> [DetectedMotionComponent] {
        guard previous.count == current.count, current.count == width * height * 4 else { return [] }
        let columns = Int(ceil(Double(width) / Double(tileSize)))
        let rows = Int(ceil(Double(height) / Double(tileSize)))
        var tileCounts = [Int](repeating: 0, count: columns * rows)
        var tileDelta = [Int](repeating: 0, count: columns * rows)
        var totalChanged = 0
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let delta = max(
                abs(Int(current[offset]) - Int(previous[offset])),
                abs(Int(current[offset + 1]) - Int(previous[offset + 1])),
                abs(Int(current[offset + 2]) - Int(previous[offset + 2]))
            )
            guard delta >= channelThreshold else { continue }
            let x = pixel % width, y = pixel / width
            let tile = (y / tileSize) * columns + x / tileSize
            tileCounts[tile] += 1
            tileDelta[tile] += delta
            totalChanged += 1
        }
        let requiredTotal = max(3, Int(ceil(Double(width * height) * changedPixelFraction)))
        guard totalChanged >= requiredTotal else { return [] }

        var result: [DetectedMotionComponent] = []
        var classified: [VisualMotionKind: Set<Int>] = [.appearance: [], .translation: []]
        for index in tileCounts.indices where tileCounts[index] >= 2 {
            let x = index % columns, y = index / columns
            let raw = CGRect(x: x * tileSize, y: y * tileSize, width: min(tileSize, width - x * tileSize), height: min(tileSize, height - y * tileSize))
            let context = raw.insetBy(dx: -CGFloat(tileSize), dy: -CGFloat(tileSize)).intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let kind: VisualMotionKind = classifyTranslations && bestTranslation(previous: previous, current: current, width: width, height: height, rect: context) ? .translation : .appearance
            classified[kind, default: []].insert(index)
        }

        for kind in [VisualMotionKind.appearance, .translation] {
            // Classify before dilation so the source and destination of a
            // translation cannot swallow the newly revealed component.
            var active = Set<Int>()
            for index in classified[kind, default: []] {
                let x = index % columns, y = index / columns
                for oy in -1...1 { for ox in -1...1 {
                    let nx = x + ox, ny = y + oy
                    if nx >= 0, nx < columns, ny >= 0, ny < rows { active.insert(ny * columns + nx) }
                }}
            }
            while let seed = active.first {
            var queue = [seed], cursor = 0
            active.remove(seed)
            var members: [Int] = []
            while cursor < queue.count {
                let index = queue[cursor]; cursor += 1; members.append(index)
                let x = index % columns, y = index / columns
                for (nx, ny) in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)] {
                    let neighbor = ny * columns + nx
                    if nx >= 0, nx < columns, ny >= 0, ny < rows, active.remove(neighbor) != nil { queue.append(neighbor) }
                }
            }
            let xs = members.map { $0 % columns }, ys = members.map { $0 / columns }
            let x0 = max(0, (xs.min() ?? 0) * tileSize)
            let y0 = max(0, (ys.min() ?? 0) * tileSize)
            let x1 = min(width, ((xs.max() ?? 0) + 1) * tileSize)
            let y1 = min(height, ((ys.max() ?? 0) + 1) * tileSize)
            let rect = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            let changed = members.reduce(0) { $0 + tileCounts[$1] }
            guard changed >= 3, rect.width * rect.height >= 16 else { continue }
            let delta = members.reduce(0) { $0 + tileDelta[$1] }
            result.append(DetectedMotionComponent(
                normalizedBounds: CGRect(x: rect.minX / CGFloat(width), y: rect.minY / CGFloat(height), width: rect.width / CGFloat(width), height: rect.height / CGFloat(height)),
                changedFraction: Double(changed) / Double(width * height),
                magnitude: min(1, Double(delta) / Double(max(1, changed)) / 80),
                kind: kind
            ))
            }
        }
        return result
    }

    private static func bestTranslation(previous: [UInt8], current: [UInt8], width: Int, height: Int, rect: CGRect) -> Bool {
        let x0 = Int(rect.minX), y0 = Int(rect.minY), x1 = Int(rect.maxX), y1 = Int(rect.maxY)
        func score(dx: Int, dy: Int) -> Double? {
            guard x0 + dx >= 0, y0 + dy >= 0, x1 + dx <= width, y1 + dy <= height else { return nil }
            var total = 0, samples = 0
            for y in stride(from: y0, to: y1, by: 4) { for x in stride(from: x0, to: x1, by: 4) {
                let a = (y * width + x) * 4
                let b = ((y + dy) * width + x + dx) * 4
                total += abs(Int(current[a]) - Int(previous[b]))
                total += abs(Int(current[a+1]) - Int(previous[b+1]))
                total += abs(Int(current[a+2]) - Int(previous[b+2]))
                samples += 3
            }}
            return samples == 0 ? nil : Double(total) / Double(samples)
        }
        guard let stationary = score(dx: 0, dy: 0), stationary >= 5 else { return false }
        var best = stationary
        for dy in stride(from: -56, through: 56, by: 4) { for dx in stride(from: -56, through: 56, by: 4) {
            if dx == 0, dy == 0 { continue }
            if let candidate = score(dx: dx, dy: dy) { best = min(best, candidate) }
        }}
        return best < 12 && best < stationary * 0.58
    }
}

private extension CGRect {
    func overlapRatio(with other: CGRect) -> CGFloat {
        let shared = intersection(other)
        guard !shared.isNull else { return 0 }
        let smaller = min(width * height, other.width * other.height)
        return smaller > 0 ? shared.width * shared.height / smaller : 0
    }
}
