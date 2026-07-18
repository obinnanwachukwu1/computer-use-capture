import CoreGraphics
import Foundation

/// A causal partition of the rolling visual evidence stream.
///
/// Motion analysis deliberately uses overlapping frame windows so it does not
/// miss short visual changes. Those windows are observations, not action
/// ownership. This type records the smaller set of intervals that can be
/// assigned to exactly one resolved action without crossing a later factual
/// activation boundary. Cross-boundary and already-underway intervals remain
/// available for diagnostics, but cannot become negative framing evidence for
/// an individual action.
public struct ActionResponseSlice: Sendable {
    public struct Evidence: Sendable {
        public let id: Int
        public let sourceActionID: Int
        public let startTime: Double
        public let endTime: Double
        public let normalizedBounds: CGRect
        public let changedFraction: Double
        public let confidence: Double
        public let kind: VisualMotionKind

        public init(id: Int, source: EpisodeVisualEvidence) {
            self.id = id
            self.sourceActionID = source.actionID
            self.startTime = min(source.startTime, source.endTime)
            self.endTime = max(source.startTime, source.endTime)
            self.normalizedBounds = source.normalizedBounds
            self.changedFraction = source.changedFraction
            self.confidence = source.confidence
            self.kind = source.kind
        }
    }

    public let actionID: Int
    public let activation: Double
    public let exclusiveEnd: Double
    public let exclusiveEvidence: [Evidence]
    public let preexistingEvidence: [Evidence]
    public let crossBoundaryEvidence: [Evidence]

    public init(
        actionID: Int,
        activation: Double,
        exclusiveEnd: Double,
        exclusiveEvidence: [Evidence],
        preexistingEvidence: [Evidence] = [],
        crossBoundaryEvidence: [Evidence] = []
    ) {
        self.actionID = actionID
        self.activation = activation
        self.exclusiveEnd = exclusiveEnd
        self.exclusiveEvidence = exclusiveEvidence
        self.preexistingEvidence = preexistingEvidence
        self.crossBoundaryEvidence = crossBoundaryEvidence
    }
}

public enum ActionResponseSlicer {
    /// The motion analyzer samples at 12 Hz, while action clocks may have
    /// higher precision. One 30 Hz frame is enough to absorb clock rounding
    /// without allowing an already-running response to become newly caused.
    private static let clockUncertainty = 1.0 / 30.0
    private static let maximumResponseHorizon = 1.25

    public static func make(
        actions: [DirectedAction],
        phases: [Int: InteractionPhases],
        evidence: [EpisodeVisualEvidence],
        sourceDuration: Double
    ) -> [ActionResponseSlice] {
        // An empty stream means the cache predates rolling response evidence
        // (or a focused unit test supplied only aggregate observations). It is
        // not evidence that every action had an empty exclusive response.
        // Preserve the legacy aggregate path rather than manufacturing an
        // authoritative all-empty partition.
        guard !evidence.isEmpty else { return [] }

        struct Boundary {
            let actionID: Int
            let activation: Double
            let nextActivation: Double
        }

        let ordered = actions.map { action in
            (action.id, phases[action.id]?.activation ?? action.time)
        }.sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }
        let boundaries = ordered.indices.map { index in
            Boundary(
                actionID: ordered[index].0,
                activation: ordered[index].1,
                nextActivation: index + 1 < ordered.count
                    ? ordered[index + 1].1 : sourceDuration
            )
        }
        let samples = evidence.enumerated().map {
            ActionResponseSlice.Evidence(id: $0.offset, source: $0.element)
        }.filter {
            !$0.normalizedBounds.isNull
                && !$0.normalizedBounds.isEmpty
                && $0.endTime > $0.startTime
        }

        return boundaries.map { boundary in
            let exclusiveEnd = min(
                sourceDuration,
                boundary.activation + maximumResponseHorizon,
                boundary.nextActivation
            )
            var exclusive: [ActionResponseSlice.Evidence] = []
            var preexisting: [ActionResponseSlice.Evidence] = []
            var crossBoundary: [ActionResponseSlice.Evidence] = []

            for sample in samples {
                // Action-specific response fields are authoritative only for
                // their own action. Global rolling fields may be considered by
                // any one compatible window, but never by more than one.
                guard sample.sourceActionID < 0
                        || sample.sourceActionID == boundary.actionID
                else { continue }

                let intersectsResponseWindow = sample.endTime
                        >= boundary.activation - clockUncertainty
                    && sample.startTime <= exclusiveEnd + clockUncertainty
                let crossesLaterActivation = intersectsResponseWindow
                    && boundary.nextActivation < sourceDuration
                    && sample.startTime < boundary.nextActivation - clockUncertainty
                    && sample.endTime > boundary.nextActivation + clockUncertainty
                if crossesLaterActivation {
                    crossBoundary.append(sample)
                    continue
                }

                if sample.startTime < boundary.activation - clockUncertainty,
                   sample.endTime >= boundary.activation - clockUncertainty {
                    // An action-specific comparison is allowed to straddle its
                    // own activation because its before frame is intentionally
                    // the last pre-activation sample. A global rolling window
                    // has no such causal guarantee and remains preexisting.
                    if sample.sourceActionID < 0 {
                        preexisting.append(sample)
                        continue
                    }
                }

                let midpoint = (sample.startTime + sample.endTime) / 2
                guard sample.endTime > boundary.activation - clockUncertainty,
                      midpoint >= boundary.activation - clockUncertainty,
                      midpoint <= exclusiveEnd + clockUncertainty,
                      sample.endTime <= boundary.nextActivation + clockUncertainty
                else { continue }
                exclusive.append(sample)
            }

            return ActionResponseSlice(
                actionID: boundary.actionID,
                activation: boundary.activation,
                exclusiveEnd: exclusiveEnd,
                exclusiveEvidence: exclusive.sorted(by: evidenceComesBefore),
                preexistingEvidence: preexisting.sorted(by: evidenceComesBefore),
                crossBoundaryEvidence: crossBoundary.sorted(by: evidenceComesBefore)
            )
        }
    }

    private static func evidenceComesBefore(
        _ left: ActionResponseSlice.Evidence,
        _ right: ActionResponseSlice.Evidence
    ) -> Bool {
        if left.startTime != right.startTime { return left.startTime < right.startTime }
        if left.endTime != right.endTime { return left.endTime < right.endTime }
        return left.id < right.id
    }
}
