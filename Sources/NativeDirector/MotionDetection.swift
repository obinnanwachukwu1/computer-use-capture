import Foundation

public enum MotionDetection {
    public static func hasMotion(
        previous: [UInt8],
        current: [UInt8],
        channelThreshold: Int,
        changedPixelFraction: Double
    ) -> Bool {
        guard previous.count == current.count, !current.isEmpty else { return true }
        let pixels = current.count / 4
        let requiredChangedPixels = max(3, Int(ceil(Double(pixels) * changedPixelFraction)))
        var changed = 0
        var deltaTotal = 0
        var index = 0
        while index < current.count {
            let red = abs(Int(current[index]) - Int(previous[index]))
            let green = abs(Int(current[index + 1]) - Int(previous[index + 1]))
            let blue = abs(Int(current[index + 2]) - Int(previous[index + 2]))
            let delta = max(red, max(green, blue))
            deltaTotal += delta
            if delta >= channelThreshold {
                changed += 1
                if changed >= requiredChangedPixels { return true }
            }
            index += 4
        }
        return Double(deltaTotal) / Double(pixels) >= 1.4
    }

    public static func ranges(forMotionTimes times: [Double]) -> [ClosedRange<Double>] {
        var ranges: [ClosedRange<Double>] = []
        for time in times {
            let candidate = max(0, time - 0.35)...(time + 0.35)
            if let last = ranges.last, candidate.lowerBound <= last.upperBound + 0.75 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, candidate.upperBound)
            } else {
                ranges.append(candidate)
            }
        }
        return ranges
    }
}
