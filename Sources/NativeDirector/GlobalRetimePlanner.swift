import Foundation

/// Clip-wide retiming derived from the complete selected action set and all
/// detected motion ranges. It never scans gaps and commits them incrementally;
/// instead it labels one global interval partition, then emits the time map.
public enum GlobalRetimePlanner {
    private enum Label: Int { case staticGap, ambientMotion, unverified, protectedResponse, action }

    /// Converts globally retained structural observations into source ranges
    /// whose UI animation and settled result must remain readable. The scene
    /// model owns the evidence duration; the small tail is editorial dwell.
    public static func protectedResponseRanges(
        observations: [VisualMotionObservation],
        observationIDs: Set<Int>? = nil,
        sourceDuration: Double,
        readingHold: Double = 0.42
    ) -> [ClosedRange<Double>] {
        observations.enumerated().compactMap { index, observation in
            if let observationIDs, !observationIDs.contains(index) { return nil }
            guard SpatialMotion.isFramingEligible(observation) else { return nil }
            let start = max(0, observation.timeRange.lowerBound)
            let end = min(sourceDuration, observation.timeRange.upperBound + max(0, readingHold))
            return end > start ? start...end : nil
        }
    }

    public static func plan(
        actions: [DirectedAction],
        sourceDuration: Double,
        motionRanges: [ClosedRange<Double>],
        protectedInteractionRanges: [ClosedRange<Double>] = [],
        protectedResponseRanges: [ClosedRange<Double>] = [],
        verifiedIdleRanges: [ClosedRange<Double>]? = nil,
        provenIdleActionIDs: Set<Int> = [],
        reduceWaiting: Bool,
        waitingTime: Double,
        deadTimeRate: Double
    ) -> [RetimeSegment] {
        guard sourceDuration > 0 else { return [] }
        let actionRanges = actions.filter { !provenIdleActionIDs.contains($0.id) }.map { action in
            max(0, action.time - 0.82)...min(sourceDuration, NativeComposition.holdEnd(for: action))
        } + protectedInteractionRanges.map {
            max(0, $0.lowerBound)...min(sourceDuration, $0.upperBound)
        }.filter { $0.upperBound > $0.lowerBound }
            + [0...min(sourceDuration, 1.4), max(0, sourceDuration - 1.1)...sourceDuration]
        let motion = motionRanges.map {
            max(0, $0.lowerBound)...min(sourceDuration, $0.upperBound)
        }.filter { $0.upperBound > $0.lowerBound }
        let protectedResponses = protectedResponseRanges.map {
            max(0, $0.lowerBound)...min(sourceDuration, $0.upperBound)
        }.filter { $0.upperBound > $0.lowerBound }
        let verifiedIdle = verifiedIdleRanges?.map {
            max(0, $0.lowerBound)...min(sourceDuration, $0.upperBound)
        }.filter { $0.upperBound > $0.lowerBound }
        var boundaryValues = [0, sourceDuration]
        boundaryValues += actionRanges.flatMap { [$0.lowerBound, $0.upperBound] }
        boundaryValues += motion.flatMap { [$0.lowerBound, $0.upperBound] }
        boundaryValues += protectedResponses.flatMap { [$0.lowerBound, $0.upperBound] }
        boundaryValues += (verifiedIdle ?? []).flatMap { [$0.lowerBound, $0.upperBound] }
        let boundaries = Set(boundaryValues).sorted()
        var labeled: [(start: Double, end: Double, label: Label)] = []
        for pair in zip(boundaries, boundaries.dropFirst()) where pair.1 - pair.0 > 0.000_001 {
            let midpoint = (pair.0 + pair.1) / 2
            let label: Label
            if actionRanges.contains(where: { $0.contains(midpoint) }) { label = .action }
            else if protectedResponses.contains(where: { $0.contains(midpoint) }) { label = .protectedResponse }
            else if let verifiedIdle {
                if verifiedIdle.contains(where: { $0.contains(midpoint) }) { label = .staticGap }
                else if motion.contains(where: { $0.contains(midpoint) }) { label = .ambientMotion }
                else { label = .unverified }
            } else if motion.contains(where: { $0.contains(midpoint) }) { label = .ambientMotion }
            else { label = .staticGap }
            if let previous = labeled.last, previous.label == label, abs(previous.end - pair.0) < 0.000_001 {
                labeled[labeled.count - 1].end = pair.1
            } else {
                labeled.append((pair.0, pair.1, label))
            }
        }

        var raw: [(Double, Double, Double)] = []
        for interval in labeled {
            switch interval.label {
            case .action, .protectedResponse:
                raw.append((interval.start, interval.end, 1))
            case .unverified:
                // Missing provenance is not evidence of idleness. Preserve it
                // at source speed rather than allowing an editorial detector
                // to erase a factual interval.
                raw.append((interval.start, interval.end, 1))
            case .ambientMotion:
                raw.append((interval.start, interval.end, max(1, deadTimeRate)))
            case .staticGap:
                if !reduceWaiting {
                    raw.append((interval.start, interval.end, max(1, deadTimeRate)))
                    continue
                }
                let retained = min(interval.end - interval.start, max(0, waitingTime))
                let leading = retained / 2
                if leading > 0 { raw.append((interval.start, interval.start + leading, 1)) }
                let trailing = retained - leading
                if trailing > 0 { raw.append((interval.end - trailing, interval.end, 1)) }
            }
        }
        var outputStart = 0.0
        return raw.filter { $0.1 - $0.0 > 0.001 }.map {
            let segment = RetimeSegment(
                sourceStart: $0.0, sourceEnd: $0.1,
                rate: $0.2, outputStart: outputStart
            )
            outputStart += segment.outputDuration
            return segment
        }
    }
}
