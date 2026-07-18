import CoreGraphics
import Foundation

/// Competing object hypotheses for complete interaction episodes.
///
/// This graph deliberately stops before editorial framing. It preserves the
/// factual trigger separately from possible response objects and scores those
/// objects over the whole episode. No role, label, or application name is
/// translated into a camera instruction.
public struct InteractionObjectGraph: Sendable {
    public enum Source: String, Sendable {
        case trigger
        case semanticContainer
        case visualLifecycle
        case visualResidual
    }

    public struct Candidate: Sendable {
        public let id: Int
        public let source: Source
        public let bounds: CGRect
        public let sourceRange: ClosedRange<Double>
        public let actionIDs: [Int]
        public let observationIDs: Set<Int>
        public let confidence: Double
        public let causalScore: Double
    }

    public struct Episode: Sendable {
        public let id: Int
        public let actionIDs: [Int]
        public let sourceRange: ClosedRange<Double>
        public let triggerCandidateID: Int?
        public let candidateIDs: [Int]
        public let selectedResponseCandidateID: Int?
    }

    public let candidates: [Candidate]
    public let episodes: [Episode]

    public init(candidates: [Candidate], episodes: [Episode]) {
        self.candidates = candidates
        self.episodes = episodes
    }

    /// Object diagnostics must be driven by each candidate's own evidence
    /// lifetime. An episode is an inference/search boundary, not permission to
    /// display every candidate for the episode's full duration.
    public func activeCandidates(at sourceTime: Double) -> [Candidate] {
        candidates.filter { $0.sourceRange.contains(sourceTime) }
    }

    public func selectedCandidateIDs(at sourceTime: Double) -> Set<Int> {
        Set(episodes.compactMap { episode in
            guard episode.sourceRange.contains(sourceTime),
                  let selected = episode.selectedResponseCandidateID,
                  candidates.first(where: { $0.id == selected })?.sourceRange.contains(sourceTime) == true
            else { return nil }
            return selected
        })
    }

    public static func make(
        graph: ProductionPlanGraph,
        composition: NativeComposition,
        episodeVisualEvidence: [EpisodeVisualEvidence] = []
    ) -> InteractionObjectGraph {
        let canvas = CGRect(origin: .zero, size: graph.size)
        let actions = graph.actions.map(\.action).sorted { $0.time < $1.time }
        let groups = episodeGroups(actions: actions, canvas: canvas)
        var candidates: [Candidate] = []
        var episodes: [Episode] = []
        var nextCandidateID = 0

        for (episodeID, group) in groups.enumerated() {
            guard let first = group.first, let last = group.last else { continue }
            let episodeRange = first.time...min(
                graph.sourceDuration,
                max(NativeComposition.holdEnd(for: last), last.time + 2.4)
            )
            var ids: [Int] = []
            let triggerBounds = group.compactMap { factualBounds($0, canvas: canvas) }
                .reduce(CGRect.null) { $0.union($1) }
            let triggerID: Int?
            if !triggerBounds.isNull {
                triggerID = nextCandidateID
                candidates.append(Candidate(
                    id: nextCandidateID,
                    source: .trigger,
                    bounds: triggerBounds,
                    sourceRange: first.time...last.time,
                    actionIDs: group.map(\.id),
                    observationIDs: [],
                    confidence: 1,
                    causalScore: 0
                ))
                ids.append(nextCandidateID)
                nextCandidateID += 1
            } else {
                triggerID = nil
            }

            // Stable semantic containers are retained independently from the
            // controls they contain. Repetition raises causal confidence: if
            // the same trigger changes the same surrounding surface several
            // times, the surface is a stronger response hypothesis than the
            // stationary pointer itself.
            let containers = group.flatMap { action in
                action.interactionCandidateBounds.isEmpty
                    ? [action.interactionContainerBounds].compactMap { $0 }
                    : action.interactionCandidateBounds
            }
            for container in deduplicated(containers, canvas: canvas) {
                let area = areaFraction(container, canvas: canvas)
                guard area >= 0.008, area <= 0.68 else { continue }
                let repetitions = group.filter {
                    $0.interactionCandidateBounds.contains { intersectionOverUnion($0, container) >= 0.82 }
                        || ($0.interactionContainerBounds.map { intersectionOverUnion($0, container) >= 0.82 } ?? false)
                }.count
                let causal = 1.0
                    + min(1.2, Double(max(0, repetitions - 1)) * 0.62)
                    + semanticMinimality(area)
                candidates.append(Candidate(
                    id: nextCandidateID,
                    source: .semanticContainer,
                    bounds: container.intersection(canvas),
                    sourceRange: episodeRange,
                    actionIDs: group.map(\.id),
                    observationIDs: [],
                    confidence: min(0.96, 0.76 + Double(repetitions) * 0.06),
                    causalScore: causal
                ))
                ids.append(nextCandidateID)
                nextCandidateID += 1
            }

            // Detector lifecycles remain hypotheses even when they are not
            // externally verified. The production subject graph may require
            // verification before granting ownership; this object graph keeps
            // the evidence so newly born transient output is not erased.
            for lifecycle in graph.lifecycles where
                lifecycle.gainedAt >= first.time - 0.05
                    && lifecycle.gainedAt <= episodeRange.upperBound {
                let bounds = lifecycle.bounds.intersection(canvas)
                let area = areaFraction(bounds, canvas: canvas)
                guard area >= 0.006, area <= 0.68 else { continue }
                let delay = max(0, lifecycle.gainedAt - first.time)
                // A localized region born after the trigger is direct response
                // evidence. It should outrank an already-existing semantic
                // stage when both are plausible, while remaining only a
                // hypothesis until the camera layer chooses a shot.
                let causal = 2.10 + exp(-delay / 2.4) + areaPreference(area)
                candidates.append(Candidate(
                    id: nextCandidateID,
                    source: .visualLifecycle,
                    bounds: bounds,
                    sourceRange: lifecycle.gainedAt...(lifecycle.releasedAt ?? episodeRange.upperBound),
                    actionIDs: group.map(\.id),
                    observationIDs: Set([
                        lifecycle.gainedObservationID,
                        lifecycle.releasedObservationID
                    ].compactMap { $0 }),
                    confidence: min(0.94, 0.70 + exp(-delay / 2.4) * 0.20),
                    causalScore: causal
                ))
                ids.append(nextCandidateID)
                nextCandidateID += 1
            }

            // Localized structural residuals compete with semantic containers
            // and lifecycles. Page-sized changes remain context and are not
            // allowed to win merely by accumulating more changed pixels.
            let actionIDs = Set(group.map(\.id))
            for (observationID, observation) in graph.observations.enumerated() {
                guard observation.kind != .contextTransition,
                      observation.startTime >= first.time - 0.05,
                      observation.startTime <= episodeRange.upperBound,
                      graph.attributions.contains(where: {
                          $0.observationID == observationID
                              && $0.actionID.map(actionIDs.contains) == true
                              && $0.cost < 1.5
                      })
                else { continue }
                let bounds = mapped(observation, graph: graph).intersection(canvas)
                let area = areaFraction(bounds, canvas: canvas)
                guard area >= 0.006, area <= 0.62 else { continue }
                let delay = max(0, observation.startTime - first.time)
                let causal = 0.8
                    + exp(-delay / 1.8)
                    + min(0.9, observation.changedFraction * 18)
                    + areaPreference(area)
                candidates.append(Candidate(
                    id: nextCandidateID,
                    source: .visualResidual,
                    bounds: bounds,
                    sourceRange: observation.startTime...max(observation.time, observation.startTime + 0.25),
                    actionIDs: group.map(\.id),
                    observationIDs: [observationID],
                    confidence: min(0.92, 0.58 + observation.magnitude * 0.22 + observation.changedFraction * 8),
                    causalScore: causal
                ))
                ids.append(nextCandidateID)
                nextCandidateID += 1
            }

            // Multi-frame residual tracks retain objects that are visible in
            // the response sequence but disappear when the interval is
            // collapsed to one before/after comparison. Requiring coherent
            // support across distinct temporal intervals rejects one-frame
            // navigation fragments without naming any UI component.
            let trackedResiduals = trackedVisualResiduals(
                evidence: episodeVisualEvidence.filter { actionIDs.contains($0.actionID) },
                canvas: canvas,
                graph: graph
            )
            for track in trackedResiduals where track.sampleCount >= 2 {
                let area = areaFraction(track.bounds, canvas: canvas)
                guard area >= 0.004, area <= 0.45 else { continue }
                let causal = 2.0
                    + min(1.4, Double(track.sampleCount - 1) * 0.65)
                    + min(0.8, track.changedFraction * 14)
                    + areaPreference(area)
                candidates.append(Candidate(
                    id: nextCandidateID,
                    source: .visualResidual,
                    bounds: track.bounds,
                    sourceRange: track.startTime...track.endTime,
                    actionIDs: group.map(\.id),
                    observationIDs: [],
                    confidence: min(0.96, 0.64 + Double(track.sampleCount) * 0.08 + track.confidence * 0.14),
                    causalScore: causal
                ))
                ids.append(nextCandidateID)
                nextCandidateID += 1
            }

            let selected = ids.compactMap { id in candidates.first { $0.id == id } }
                .filter { $0.source != .trigger && $0.causalScore >= 1.45 }
                .max {
                    if abs($0.causalScore - $1.causalScore) > 0.000_001 {
                        return $0.causalScore < $1.causalScore
                    }
                    return areaFraction($0.bounds, canvas: canvas)
                        > areaFraction($1.bounds, canvas: canvas)
                }?.id
            episodes.append(Episode(
                id: episodeID,
                actionIDs: group.map(\.id),
                sourceRange: episodeRange,
                triggerCandidateID: triggerID,
                candidateIDs: ids,
                selectedResponseCandidateID: selected
            ))
        }

        // Visual-only episodes are first-class proposals. They cover native
        // application animation, deterministic scene runs, delayed output,
        // and any other meaningful change that is not contemporaneous with a
        // Computer Use action. They remain separate from action-attributed
        // episodes so the camera can later distinguish causal certainty from
        // purely visual persistence.
        let globalTracks = trackedVisualResiduals(
            evidence: episodeVisualEvidence.filter { $0.actionID < 0 },
            canvas: canvas,
            graph: graph
        )
        for track in globalTracks where track.sampleCount >= 2 {
            let area = areaFraction(track.bounds, canvas: canvas)
            guard area >= 0.004, area <= 0.55 else { continue }
            let candidateID = nextCandidateID
            let causal = 1.35
                + min(1.6, Double(track.sampleCount - 1) * 0.32)
                + min(0.8, track.changedFraction * 14)
                + areaPreference(area)
            candidates.append(Candidate(
                id: candidateID,
                source: .visualResidual,
                bounds: track.bounds,
                sourceRange: track.startTime...track.endTime,
                actionIDs: [],
                observationIDs: [],
                confidence: min(
                    0.96,
                    0.58 + Double(track.sampleCount) * 0.05 + track.confidence * 0.16
                ),
                causalScore: causal
            ))
            episodes.append(Episode(
                id: episodes.count,
                actionIDs: [],
                sourceRange: track.startTime...track.endTime,
                triggerCandidateID: nil,
                candidateIDs: [candidateID],
                selectedResponseCandidateID: candidateID
            ))
            nextCandidateID += 1
        }
        return InteractionObjectGraph(candidates: candidates, episodes: episodes)
    }
}

public struct EpisodeVisualEvidence: Sendable, Codable {
    public let actionID: Int
    public let startTime: Double
    public let endTime: Double
    public let normalizedBounds: CGRect
    public let changedFraction: Double
    public let confidence: Double
    /// Observational channel only. It lets downstream inference distinguish a
    /// coherent displacement from appearance residuals without assigning UI
    /// identity, ownership, or editorial authority to either one.
    public let kind: VisualMotionKind

    public init(
        actionID: Int,
        startTime: Double,
        endTime: Double,
        normalizedBounds: CGRect,
        changedFraction: Double,
        confidence: Double,
        kind: VisualMotionKind = .appearance
    ) {
        self.actionID = actionID
        self.startTime = startTime
        self.endTime = endTime
        self.normalizedBounds = normalizedBounds
        self.changedFraction = changedFraction
        self.confidence = confidence
        self.kind = kind
    }
}

private struct TrackedResidual {
    var normalizedBounds: CGRect
    var bounds: CGRect
    var startTime: Double
    var endTime: Double
    var changedFraction: Double
    var confidence: Double
    var sampleCount: Int
}

private func trackedVisualResiduals(
    evidence: [EpisodeVisualEvidence],
    canvas: CGRect,
    graph: ProductionPlanGraph
) -> [TrackedResidual] {
    // Batched Computer Use actions can observe the same frame interval. Treat
    // identical interval/geometry records as one sample so action batching
    // cannot manufacture temporal persistence.
    var unique: [EpisodeVisualEvidence] = []
    for sample in evidence.sorted(by: {
        $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime
    }) {
        if unique.contains(where: {
            abs($0.startTime - sample.startTime) < 0.001
                && abs($0.endTime - sample.endTime) < 0.001
                && intersectionOverUnion($0.normalizedBounds, sample.normalizedBounds) >= 0.92
        }) { continue }
        unique.append(sample)
    }
    var tracks: [TrackedResidual] = []
    for sample in unique {
        let mappedBounds = mappedNormalized(sample.normalizedBounds, graph: graph).intersection(canvas)
        guard !mappedBounds.isNull else { continue }
        let match = tracks.indices.filter { index in
            let track = tracks[index]
            return sample.startTime <= track.endTime + 0.45
                && overlap(track.normalizedBounds, sample.normalizedBounds) >= 0.32
        }.max { left, right in
            overlap(tracks[left].normalizedBounds, sample.normalizedBounds)
                < overlap(tracks[right].normalizedBounds, sample.normalizedBounds)
        }
        if let match {
            tracks[match].normalizedBounds = tracks[match].normalizedBounds.union(sample.normalizedBounds)
            tracks[match].bounds = tracks[match].bounds.union(mappedBounds).intersection(canvas)
            tracks[match].endTime = max(tracks[match].endTime, sample.endTime)
            tracks[match].changedFraction += sample.changedFraction
            tracks[match].confidence = max(tracks[match].confidence, sample.confidence)
            tracks[match].sampleCount += 1
        } else {
            tracks.append(TrackedResidual(
                normalizedBounds: sample.normalizedBounds,
                bounds: mappedBounds,
                startTime: sample.startTime,
                endTime: sample.endTime,
                changedFraction: sample.changedFraction,
                confidence: sample.confidence,
                sampleCount: 1
            ))
        }
    }
    return tracks
}

private func episodeGroups(actions: [DirectedAction], canvas: CGRect) -> [[DirectedAction]] {
    var groups: [[DirectedAction]] = []
    for action in actions {
        guard action.kind == "click", let bounds = factualBounds(action, canvas: canvas) else {
            groups.append([action])
            continue
        }
        if let previous = groups.last,
           let tail = previous.last,
           tail.kind == "click",
           action.time - tail.time <= 3.5,
           let tailBounds = factualBounds(tail, canvas: canvas),
           overlap(bounds, tailBounds) >= 0.72 {
            groups[groups.count - 1].append(action)
        } else {
            groups.append([action])
        }
    }
    return groups
}

private func factualBounds(_ action: DirectedAction, canvas: CGRect) -> CGRect? {
    if let bounds = action.semanticBounds { return bounds.intersection(canvas) }
    if let point = action.point {
        return CGRect(x: point.x - 24, y: point.y - 24, width: 48, height: 48).intersection(canvas)
    }
    return nil
}

private func deduplicated(_ rects: [CGRect], canvas: CGRect) -> [CGRect] {
    var result: [CGRect] = []
    for rect in rects.map({ $0.intersection(canvas) }).filter({ !$0.isNull }) {
        if let index = result.firstIndex(where: { intersectionOverUnion($0, rect) >= 0.88 }) {
            result[index] = result[index].union(rect).intersection(canvas)
        } else {
            result.append(rect)
        }
    }
    return result
}

private func overlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
    let shared = left.intersection(right)
    guard !shared.isNull else { return 0 }
    let smallerArea = min(left.width * left.height, right.width * right.height)
    guard smallerArea > .leastNonzeroMagnitude else { return 0 }
    return shared.width * shared.height / smallerArea
}

private func intersectionOverUnion(_ left: CGRect, _ right: CGRect) -> CGFloat {
    let shared = left.intersection(right)
    guard !shared.isNull else { return 0 }
    let sharedArea = shared.width * shared.height
    let unionArea = left.width * left.height + right.width * right.height - sharedArea
    return unionArea > 0 ? sharedArea / unionArea : 0
}

private func mapped(_ observation: VisualMotionObservation, graph: ProductionPlanGraph) -> CGRect {
    mappedNormalized(observation.normalizedBounds, graph: graph)
}

private func mappedNormalized(_ bounds: CGRect, graph: ProductionPlanGraph) -> CGRect {
    CGRect(
        x: graph.contentRect.minX + bounds.minX * graph.contentRect.width,
        y: graph.contentRect.maxY - bounds.maxY * graph.contentRect.height,
        width: bounds.width * graph.contentRect.width,
        height: bounds.height * graph.contentRect.height
    )
}

private func areaFraction(_ rect: CGRect, canvas: CGRect) -> Double {
    Double(rect.width * rect.height / max(1, canvas.width * canvas.height))
}

private func areaPreference(_ area: Double) -> Double {
    // A smooth, application-independent prior. Tiny controls and near-page
    // regions are less likely response objects; medium localized surfaces are
    // most useful hypotheses. This never examines semantic roles or labels.
    let center = 0.12
    return max(-0.45, 0.48 - abs(log(max(0.001, area) / center)) * 0.18)
}

private func semanticMinimality(_ area: Double) -> Double {
    // When nested stable candidates explain the same repeated interaction,
    // prefer the smallest complete surface. This is minimum-description-
    // length reasoning, not a preferred UI size: tiny wrappers were already
    // rejected during candidate generation and larger containers remain when
    // they carry independent visual evidence.
    guard area >= 0.012 else { return -0.25 }
    return max(-0.35, 0.58 - log1p(area / 0.05) * 0.24)
}
