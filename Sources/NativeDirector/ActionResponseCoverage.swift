import CoreGraphics
import Foundation

/// Audits whether a planned camera preserves the visible result of a factual
/// interaction.
///
/// This is deliberately a negative diagnostic, not an object detector. It
/// never names a surface, chooses a camera center, or grants motion ownership.
/// It only asks whether a material response that is exclusive to one action's
/// causal slice was cropped by the already-selected trajectory.
public struct ActionResponseCoverageAudit: Sendable {
    public struct Policy: Sendable {
        /// Rolling motion fields are sampled at 12 Hz. Allow two sample
        /// intervals when joining fragmented bands from the same response.
        public var maximumTemporalGap = 0.18
        /// Normalized padding used only for response-component connectivity.
        /// It bridges sparse text/interior bands without turning distant
        /// simultaneous changes into one object hypothesis.
        public var spatialConnectionPadding: CGFloat = 0.04
        public var minimumEvidenceCount = 2
        public var minimumEnvelopeArea = 0.002
        /// Larger fields are scene/context hypotheses. They remain available
        /// to the existing broad-response overview logic, but cannot make
        /// ordinary diffuse motion a hard localized crop constraint.
        public var maximumEnvelopeArea = 0.35
        public var minimumChangedFraction = 0.0015
        /// Preserve every response hypothesis for blame, but only the
        /// near-optimal set for an action may veto a crop. This prevents weak
        /// background fragments from outranking a much stronger covered
        /// response while retaining multiple genuinely competing effects.
        public var minimumRelativeSignal = 0.80
        public var minimumVisibleFraction = 0.98
        public var safeInset: CGFloat = 50

        public init() {}
        public static let `default` = Policy()
    }

    public struct Response: Sendable {
        public let actionID: Int
        public let evidenceIDs: [Int]
        public let sourceOwnedEvidenceIDs: [Int]
        public let sourceRange: ClosedRange<Double>
        public let normalizedBounds: CGRect
        public let evidenceCount: Int
        public let totalChangedFraction: Double
        public let relativeSignal: Double
        public let maximumConfidence: Double
        public let material: Bool
        public let minimumVisibleFraction: Double
        public let minimumSafeVisibleFraction: Double
        public let worstSourceTime: Double
        public let cropped: Bool
    }

    /// A response envelope with enough exclusive, near-optimal evidence to
    /// reject a crop. It is a visibility constraint only: it carries no
    /// object identity, center preference, or persistent ownership.
    public struct Constraint: Sendable {
        public let actionID: Int
        public let sourceRange: ClosedRange<Double>
        public let normalizedBounds: CGRect
        public let evidenceIDs: [Int]
        public let relativeSignal: Double

        public init(
            actionID: Int,
            sourceRange: ClosedRange<Double>,
            normalizedBounds: CGRect,
            evidenceIDs: [Int],
            relativeSignal: Double
        ) {
            self.actionID = actionID
            self.sourceRange = sourceRange
            self.normalizedBounds = normalizedBounds
            self.evidenceIDs = evidenceIDs
            self.relativeSignal = relativeSignal
        }
    }

    public let responses: [Response]

    public var materialResponses: [Response] { responses.filter(\.material) }
    public var croppedMaterialResponses: [Response] {
        responses.filter { $0.material && $0.cropped }
    }

    public static func constraints(
        slices: [ActionResponseSlice],
        policy: Policy = .default
    ) -> [Constraint] {
        slices.flatMap { slice -> [Constraint] in
            let responseClusters = clusters(in: slice.exclusiveEvidence, policy: policy)
            let maximumSignal = responseClusters.map(responseSignal).max() ?? 0
            return responseClusters.compactMap { cluster in
                guard !cluster.isEmpty else { return nil }
                let signal = responseSignal(cluster)
                let relativeSignal = maximumSignal > 0 ? signal / maximumSignal : 0
                let bounds = cluster.reduce(CGRect.null) {
                    $0.union($1.normalizedBounds)
                }
                let sourceOwned = cluster.filter { $0.sourceActionID == slice.actionID }
                guard isMaterial(
                    cluster: cluster,
                    sourceOwned: sourceOwned,
                    bounds: bounds,
                    signal: signal,
                    relativeSignal: relativeSignal,
                    policy: policy
                ) else { return nil }
                return Constraint(
                    actionID: slice.actionID,
                    sourceRange: cluster.map(\.startTime).min()!...cluster.map(\.endTime).max()!,
                    normalizedBounds: bounds,
                    evidenceIDs: cluster.map(\.id).sorted(),
                    relativeSignal: relativeSignal
                )
            }
        }.sorted {
            if $0.sourceRange.lowerBound != $1.sourceRange.lowerBound {
                return $0.sourceRange.lowerBound < $1.sourceRange.lowerBound
            }
            if $0.actionID != $1.actionID { return $0.actionID < $1.actionID }
            return $0.evidenceIDs.lexicographicallyPrecedes($1.evidenceIDs)
        }
    }

    public static func evaluate(
        slices: [ActionResponseSlice],
        contentRect: CGRect,
        outputSize: CGSize,
        cameraAtSourceTime: (Double) -> CameraState,
        policy: Policy = .default
    ) -> ActionResponseCoverageAudit {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let safeRect = outputRect.insetBy(dx: policy.safeInset, dy: policy.safeInset)
        var responses: [Response] = []

        for slice in slices {
            let responseClusters = clusters(in: slice.exclusiveEvidence, policy: policy)
            let maximumSignal = responseClusters.map(responseSignal).max() ?? 0
            for cluster in responseClusters {
                guard !cluster.isEmpty else { continue }
                let responseStart = cluster.map(\.startTime).min()!
                let responseEnd = cluster.map(\.endTime).max()!
                let normalizedBounds = cluster.reduce(CGRect.null) {
                    $0.union($1.normalizedBounds)
                }
                guard !normalizedBounds.isNull, !normalizedBounds.isEmpty else { continue }

                let evidenceIDs = cluster.map(\.id).sorted()
                let sourceOwnedEvidenceIDs = cluster.filter {
                    $0.sourceActionID == slice.actionID
                }.map(\.id).sorted()
                let totalChangedFraction = responseSignal(cluster)
                let maximumConfidence = cluster.map(\.confidence).max() ?? 0
                let relativeSignal = maximumSignal > 0
                    ? totalChangedFraction / maximumSignal : 0
                let material = isMaterial(
                    cluster: cluster,
                    sourceOwned: cluster.filter { $0.sourceActionID == slice.actionID },
                    bounds: normalizedBounds,
                    signal: totalChangedFraction,
                    relativeSignal: relativeSignal,
                    policy: policy
                )

                // Evaluate the accumulated response at every measured
                // completion boundary. A moving appearance is often emitted
                // as several disjoint bands; the prefix union preserves the
                // full visible result without asserting that it is an object.
                let sampleTimes = Array(Set(cluster.map(\.endTime))).sorted()
                var minimumVisible = 1.0
                var minimumSafeVisible = 1.0
                var worstTime = responseEnd
                for sampleTime in sampleTimes {
                    let prefix = cluster.filter { $0.startTime <= sampleTime + 0.000_001 }
                    let prefixBounds = prefix.reduce(CGRect.null) {
                        $0.union($1.normalizedBounds)
                    }
                    guard !prefixBounds.isNull else { continue }
                    let canvasBounds = CGRect(
                        x: contentRect.minX + prefixBounds.minX * contentRect.width,
                        y: contentRect.maxY - prefixBounds.maxY * contentRect.height,
                        width: prefixBounds.width * contentRect.width,
                        height: prefixBounds.height * contentRect.height
                    )
                    let projected = project(
                        canvasBounds,
                        through: cameraAtSourceTime(sampleTime),
                        outputSize: outputSize
                    )
                    let visible = areaFraction(of: projected, inside: outputRect)
                    let safeVisible = areaFraction(of: projected, inside: safeRect)
                    if visible < minimumVisible {
                        minimumVisible = visible
                        worstTime = sampleTime
                    }
                    minimumSafeVisible = min(minimumSafeVisible, safeVisible)
                }

                responses.append(Response(
                    actionID: slice.actionID,
                    evidenceIDs: evidenceIDs,
                    sourceOwnedEvidenceIDs: sourceOwnedEvidenceIDs,
                    sourceRange: responseStart...responseEnd,
                    normalizedBounds: normalizedBounds,
                    evidenceCount: cluster.count,
                    totalChangedFraction: totalChangedFraction,
                    relativeSignal: relativeSignal,
                    maximumConfidence: maximumConfidence,
                    material: material,
                    minimumVisibleFraction: minimumVisible,
                    minimumSafeVisibleFraction: minimumSafeVisible,
                    worstSourceTime: worstTime,
                    cropped: minimumVisible < policy.minimumVisibleFraction
                ))
            }
        }

        return ActionResponseCoverageAudit(responses: responses.sorted {
            if $0.sourceRange.lowerBound != $1.sourceRange.lowerBound {
                return $0.sourceRange.lowerBound < $1.sourceRange.lowerBound
            }
            if $0.actionID != $1.actionID { return $0.actionID < $1.actionID }
            return $0.evidenceIDs.lexicographicallyPrecedes($1.evidenceIDs)
        })
    }
}

private extension ActionResponseCoverageAudit {
    static func responseSignal(_ cluster: [ActionResponseSlice.Evidence]) -> Double {
        cluster.reduce(0) { $0 + max(0, $1.changedFraction) }
    }

    static func isMaterial(
        cluster: [ActionResponseSlice.Evidence],
        sourceOwned: [ActionResponseSlice.Evidence],
        bounds: CGRect,
        signal: Double,
        relativeSignal: Double,
        policy: Policy
    ) -> Bool {
        let area = Double(bounds.width * bounds.height)
        return cluster.count >= policy.minimumEvidenceCount
            && !sourceOwned.isEmpty
            && area >= policy.minimumEnvelopeArea
            && area <= policy.maximumEnvelopeArea
            && signal >= policy.minimumChangedFraction
            && relativeSignal >= policy.minimumRelativeSignal
    }

    static func clusters(
        in evidence: [ActionResponseSlice.Evidence],
        policy: Policy
    ) -> [[ActionResponseSlice.Evidence]] {
        let ordered = evidence.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
            return $0.id < $1.id
        }
        var result: [[ActionResponseSlice.Evidence]] = []
        for item in ordered {
            let related = result.indices.filter { index in
                result[index].contains { existing in
                    temporallyConnected(item, existing, gap: policy.maximumTemporalGap)
                        && spatiallyConnected(
                            item.normalizedBounds,
                            existing.normalizedBounds,
                            padding: policy.spatialConnectionPadding
                        )
                }
            }
            guard let destination = related.first else {
                result.append([item])
                continue
            }
            result[destination].append(item)
            for index in related.dropFirst().reversed() {
                result[destination].append(contentsOf: result[index])
                result.remove(at: index)
            }
        }
        return result.map {
            $0.sorted {
                if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
                if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
                return $0.id < $1.id
            }
        }
    }

    static func temporallyConnected(
        _ left: ActionResponseSlice.Evidence,
        _ right: ActionResponseSlice.Evidence,
        gap: Double
    ) -> Bool {
        left.startTime <= right.endTime + gap && right.startTime <= left.endTime + gap
    }

    static func spatiallyConnected(
        _ left: CGRect,
        _ right: CGRect,
        padding: CGFloat
    ) -> Bool {
        left.insetBy(dx: -padding, dy: -padding)
            .intersects(right.insetBy(dx: -padding, dy: -padding))
    }

    static func project(
        _ rect: CGRect,
        through camera: CameraState,
        outputSize: CGSize
    ) -> CGRect {
        let minimum = projectPointThroughCamera(
            rect.origin, camera: camera, outputSize: outputSize
        )
        let maximum = projectPointThroughCamera(
            CGPoint(x: rect.maxX, y: rect.maxY),
            camera: camera,
            outputSize: outputSize
        )
        return CGRect(
            x: min(minimum.x, maximum.x),
            y: min(minimum.y, maximum.y),
            width: abs(maximum.x - minimum.x),
            height: abs(maximum.y - minimum.y)
        )
    }

    static func areaFraction(of rect: CGRect, inside container: CGRect) -> Double {
        guard !rect.isNull, !rect.isEmpty else { return 0 }
        let intersection = rect.intersection(container)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return Double(intersection.width * intersection.height)
            / Double(rect.width * rect.height)
    }
}
