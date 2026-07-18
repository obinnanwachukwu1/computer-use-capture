import CoreGraphics
import Foundation

public struct TimedMotionSample: Sendable {
    public let time: Double
    public let components: [DetectedMotionComponent]

    public init(time: Double, components: [DetectedMotionComponent]) {
        self.time = time
        self.components = components
    }
}

public struct TextInputEvidence: Sendable {
    public let time: Double
    public let validFrom: Double
    public let validThrough: Double?
    public let normalizedBounds: CGRect

    public init(
        time: Double,
        normalizedBounds: CGRect,
        validFrom: Double? = nil,
        validThrough: Double? = nil
    ) {
        self.time = time
        self.validFrom = validFrom ?? time
        self.validThrough = validThrough
        self.normalizedBounds = normalizedBounds
    }

    fileprivate func contains(_ sampleTime: Double) -> Bool {
        sampleTime >= validFrom && validThrough.map { sampleTime <= $0 } != false
    }
}

/// Recognizes the insertion caret as an editorially incidental animation.
///
/// This is deliberately narrower than a generic "small motion" detector. A
/// candidate must be a thin, vertical, spatially stationary delta inside a
/// text input known from Computer Use/Accessibility evidence, and it must
/// recur at a stable cadence. Spinners, progress indicators, counters, and
/// other application-owned animation therefore remain ordinary visible
/// motion and are preserved by waiting reduction.
public enum CaretBlinkDetection {
    private struct Candidate {
        let time: Double
        let input: Int
        let bounds: CGRect
    }

    public static func ranges(
        samples: [TimedMotionSample],
        textInputs: [TextInputEvidence]
    ) -> [ClosedRange<Double>] {
        guard !samples.isEmpty, !textInputs.isEmpty else { return [] }
        let ordered = samples.sorted { $0.time < $1.time }
        var runs: [[Candidate]] = []
        var active: [Candidate] = []

        func finishRun() {
            if !active.isEmpty { runs.append(active) }
            active.removeAll(keepingCapacity: true)
        }

        for sample in ordered {
            guard let candidate = candidate(
                for: sample,
                textInputs: textInputs
            ) else {
                // Any simultaneous non-caret change breaks the proof. This is
                // what keeps a real application response from being erased
                // merely because a caret happened to blink at the same time.
                finishRun()
                continue
            }
            if let previous = active.last,
               (previous.input != candidate.input
                    || candidate.time - previous.time > 0.82
                    || centerDistance(previous.bounds, candidate.bounds) > 0.015) {
                finishRun()
            }
            active.append(candidate)
        }
        finishRun()

        // Do not add temporal handles or merge neighboring runs. A single
        // non-caret frame is an explicit proof boundary and must remain
        // application-owned even when caret toggles surround it.
        return runs.compactMap(periodicRange)
    }

    private static func candidate(
        for sample: TimedMotionSample,
        textInputs: [TextInputEvidence]
    ) -> Candidate? {
        guard !sample.components.isEmpty else { return nil }
        let bounds = sample.components.dropFirst().reduce(
            sample.components[0].normalizedBounds
        ) { $0.union($1.normalizedBounds) }
        guard bounds.width > 0, bounds.height > 0,
              bounds.width <= 0.04,
              bounds.height <= 0.09,
              bounds.height >= bounds.width * 1.25,
              bounds.width * bounds.height <= 0.0025,
              sample.components.reduce(0, { $0 + $1.changedFraction }) <= 0.0018
        else { return nil }

        let input = textInputs.enumerated().filter { _, evidence in
            evidence.contains(sample.time)
                && containment(of: bounds, in: evidence.normalizedBounds) >= 0.92
        }.min { left, right in
            let leftDistance = abs(sample.time - left.element.time)
            let rightDistance = abs(sample.time - right.element.time)
            return leftDistance == rightDistance
                ? left.element.normalizedBounds.width * left.element.normalizedBounds.height
                    < right.element.normalizedBounds.width * right.element.normalizedBounds.height
                : leftDistance < rightDistance
        }
        guard let input else { return nil }
        return Candidate(time: sample.time, input: input.offset, bounds: bounds)
    }

    private static func periodicRange(_ run: [Candidate]) -> ClosedRange<Double>? {
        guard run.count >= 4,
              let first = run.first,
              let last = run.last,
              last.time - first.time >= 1.35
        else { return nil }
        let gaps = zip(run, run.dropFirst()).map { $1.time - $0.time }
        guard gaps.allSatisfy({ $0 >= 0.28 && $0 <= 0.72 }) else { return nil }
        let orderedGaps = gaps.sorted()
        let median = orderedGaps[orderedGaps.count / 2]
        guard gaps.allSatisfy({ abs($0 - median) <= max(0.14, median * 0.30) }) else {
            return nil
        }
        let union = run.dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
        guard union.width <= 0.05, union.height <= 0.10 else { return nil }
        return first.time...last.time
    }

    private static func containment(of inner: CGRect, in outer: CGRect) -> CGFloat {
        let area = inner.width * inner.height
        guard area > 0 else { return 0 }
        let intersection = inner.intersection(outer)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height / area
    }

    private static func centerDistance(_ left: CGRect, _ right: CGRect) -> CGFloat {
        hypot(left.midX - right.midX, left.midY - right.midY)
    }

}
