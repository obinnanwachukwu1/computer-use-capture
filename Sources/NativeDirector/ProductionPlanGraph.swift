import CoreGraphics
import Foundation

/// Immutable evidence substrate for globally inferred production planning.
///
/// The graph intentionally stores alternatives rather than attaching one
/// interpretation to each action. Nothing in this type is allowed to decide
/// shot boundaries or mutate camera state.
public struct ProductionPlanGraph: Sendable {
    public struct TimingHypothesis: Sendable, Equatable {
        public let id: Int
        public let actionID: Int
        public let pointerArrival: Double
        public let activation: Double
        public let responseOnset: Double?
        public let source: String
        public let cost: Double
    }

    public struct AttributionHypothesis: Sendable, Equatable {
        public let observationID: Int
        public let actionID: Int?
        public let cost: Double
        public let temporalDistance: Double
        public let spatialAgreement: Double
    }

    public struct AttentionHypothesis: Sendable {
        public let id: Int
        public let actionID: Int
        public let timingID: Int
        public let bounds: CGRect?
        public let behavior: CameraBehavior?
        public let evidence: [AttentionEvidence]
        public let observationIDs: Set<Int>
        public let observationClass: PlannerObservationClass?
        public let cost: Double
    }

    public struct ActionNode: Sendable {
        public let action: DirectedAction
        public let timings: [TimingHypothesis]
        public let attention: [AttentionHypothesis]
    }

    public struct SurfaceLifecycle: Sendable {
        public let id: Int
        public let bounds: CGRect
        public let gainedAt: Double
        public let releasedAt: Double?
        public let gainedObservationID: Int
        public let releasedObservationID: Int?

        public func contains(_ time: Double) -> Bool {
            time >= gainedAt && time <= (releasedAt ?? .infinity)
        }
    }

    public let size: CGSize
    public let contentRect: CGRect
    public let sourceDuration: Double
    public let actions: [ActionNode]
    public let observations: [VisualMotionObservation]
    public let actionResponseSlices: [ActionResponseSlice]
    public let motionRanges: [ClosedRange<Double>]
    public let lifecycles: [SurfaceLifecycle]
    public let attributions: [AttributionHypothesis]
    public let evaluationCondition: ProductionEvaluationCondition
    public let supportObservationIDs: Set<Int>

    public func observationClass(for observationID: Int) -> PlannerObservationClass {
        if supportObservationIDs.contains(observationID) { return .oracleForegroundSupport }
        switch observations[observationID].kind {
        case .contextTransition: return .requiredContext
        case .focus: return .foregroundEditorial
        case .appearance, .transformation, .translation: return .motionEditorial
        }
    }

    public func editorialEvidenceIsOptional(observationID: Int) -> Bool {
        switch evaluationCondition {
        case .production, .aCurrent, .cOracleCurrent:
            return false
        case .bOptionalMotion:
            return observationClass(for: observationID) != .requiredContext
        case .dOracleGated:
            return observationClass(for: observationID) != .requiredContext
        }
    }

    public func editorialEvidenceIsOptional(timeRange: ClosedRange<Double>) -> Bool {
        switch evaluationCondition {
        case .production, .aCurrent, .cOracleCurrent: return false
        case .bOptionalMotion, .dOracleGated: return true
        }
    }

    public static func make(
        from composition: NativeComposition,
        contentRect: CGRect,
        sourceDuration: Double,
        observations: [VisualMotionObservation],
        episodeVisualEvidence: [EpisodeVisualEvidence] = [],
        motionRanges: [ClosedRange<Double>],
        evaluationCondition: ProductionEvaluationCondition = .production,
        supportObservationIDs: Set<Int> = [],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle] = [],
        freezeResolvedTiming: Bool = false
    ) -> ProductionPlanGraph {
        let orderedObservations = observations.enumerated().sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }
        let actionResponseSlices = ActionResponseSlicer.make(
            actions: composition.actions,
            phases: composition.interactionPhases,
            evidence: episodeVisualEvidence,
            sourceDuration: sourceDuration
        )
        let detectorLifecycles = buildLifecycles(
            observations: orderedObservations.filter { !supportObservationIDs.contains($0.offset) },
            contentRect: contentRect,
            size: composition.size
        )
        let oracleLifecycles = oracleSupportLifecycles.enumerated().map { index, lifecycle in
            SurfaceLifecycle(
                id: detectorLifecycles.count + index,
                bounds: mapNormalizedBounds(
                    lifecycle.bounds, contentRect: contentRect, size: composition.size
                ),
                gainedAt: lifecycle.gainedAt,
                releasedAt: lifecycle.releasedAt,
                gainedObservationID: lifecycle.gainedObservationID,
                releasedObservationID: lifecycle.releasedObservationID
            )
        }
        let lifecycles = (detectorLifecycles + oracleLifecycles).sorted { $0.gainedAt < $1.gainedAt }
        let causalOnsets = causalResponseOnsets(
            actions: composition.actions,
            phases: composition.interactionPhases,
            observations: orderedObservations.map(\.element)
        )
        let activationWindows = orderedActivationWindows(
            actions: composition.actions,
            phases: composition.interactionPhases
        )
        let timingByAction = Dictionary(uniqueKeysWithValues: composition.actions.map { action in
            let phase = composition.interactionPhases[action.id]
            if freezeResolvedTiming {
                return (action.id, [TimingHypothesis(
                    id: action.id * 1_000,
                    actionID: action.id,
                    pointerArrival: phase?.pointerArrival ?? action.time,
                    activation: phase?.activation ?? action.time,
                    responseOnset: phase?.responseOnset,
                    source: "factorial-control:\(phase?.source ?? "timeline")",
                    cost: 0
                )])
            }
            return (action.id, timingHypotheses(
                for: action,
                phase: phase,
                causalResponseOnset: causalOnsets[action.id],
                activationWindow: activationWindows[action.id]
            ))
        })

        var allAttributions: [AttributionHypothesis] = []
        var nodes: [ActionNode] = []
        var nextAttentionID = 0
        for action in composition.actions.sorted(by: { $0.time < $1.time }) {
            let timings = timingByAction[action.id] ?? []
            let factual = factualEvidence(for: action)
            var hypotheses: [AttentionHypothesis] = []
            for timing in timings {
                let factualBounds = unionBounds(factual.map(\.bounds))
                if !factual.isEmpty {
                    hypotheses.append(AttentionHypothesis(
                        id: nextAttentionID,
                        actionID: action.id,
                        timingID: timing.id,
                        bounds: factualBounds,
                        behavior: factualBehavior(for: action),
                        evidence: factual,
                        observationIDs: [],
                        observationClass: nil,
                        cost: 0.28
                    ))
                    nextAttentionID += 1
                } else {
                    hypotheses.append(AttentionHypothesis(
                        id: nextAttentionID,
                        actionID: action.id,
                        timingID: timing.id,
                        bounds: nil,
                        behavior: nil,
                        evidence: [],
                        observationIDs: [],
                        observationClass: nil,
                        cost: 0.65
                    ))
                    nextAttentionID += 1
                }

                for entry in orderedObservations {
                    let observation = entry.element
                    guard observationIsAvailable(
                        entry,
                        at: timing.activation,
                        condition: evaluationCondition,
                        supportObservationIDs: supportObservationIDs,
                        lifecycles: lifecycles,
                        observations: orderedObservations
                    ) else { continue }
                    let attribution = attributionHypothesis(
                        observationID: entry.offset,
                        observation: observation,
                        action: action,
                        activation: timing.activation,
                        contentRect: contentRect,
                        size: composition.size,
                        isOracleSupport: supportObservationIDs.contains(entry.offset)
                    )
                    guard attribution.cost < 2.5 else { continue }
                    allAttributions.append(attribution)
                    guard SpatialMotion.isFramingEligible(observation) else { continue }
                    let visual = visualEvidence(
                        observationID: entry.offset,
                        observation: observation,
                        actionID: action.id,
                        contentRect: contentRect,
                        size: composition.size
                    )
                    let combined = factual + [visual]
                    hypotheses.append(AttentionHypothesis(
                        id: nextAttentionID,
                        actionID: action.id,
                        timingID: timing.id,
                        bounds: observation.kind == .contextTransition
                            ? CGRect(origin: .zero, size: composition.size)
                            : unionBounds(combined.map(\.bounds)),
                        behavior: behavior(for: observation, action: action),
                        evidence: combined,
                        observationIDs: [entry.offset],
                        observationClass: plannerObservationClass(
                            observationID: entry.offset,
                            observation: observation,
                            supportObservationIDs: supportObservationIDs
                        ),
                        cost: attribution.cost + (factual.isEmpty ? 0.15 : 0)
                    ))
                    nextAttentionID += 1
                }

                // A foreground surface is persistent evidence. Actions inside
                // its lifetime may use it even when no transition frame occurs
                // near the action itself.
                for lifecycle in lifecycles where lifecycle.contains(timing.activation) {
                    guard lifecycleIsAvailable(
                        lifecycle,
                        at: timing.activation,
                        condition: evaluationCondition,
                        supportObservationIDs: supportObservationIDs,
                        lifecycles: lifecycles,
                        observations: observations
                    ) else { continue }
                    let lifecycleClass = plannerObservationClass(
                        observationID: lifecycle.gainedObservationID,
                        observation: observations[lifecycle.gainedObservationID],
                        supportObservationIDs: supportObservationIDs
                    )
                    let evidence = AttentionEvidence(
                        source: .visualFocus,
                        timeRange: lifecycle.gainedAt...(lifecycle.releasedAt ?? sourceDuration),
                        bounds: lifecycle.bounds,
                        confidence: 0.92,
                        framingWeight: 1.0,
                        persistence: 1.0,
                        causalActionID: action.id
                    )
                    let claimsForegroundBirth = evaluationCondition == .dOracleGated
                        && supportObservationIDs.contains(lifecycle.gainedObservationID)
                        && lifecycle.gainedAt >= timing.activation - 0.35
                        && lifecycle.gainedAt <= timing.activation + 1.75
                    hypotheses.append(AttentionHypothesis(
                        id: nextAttentionID,
                        actionID: action.id,
                        timingID: timing.id,
                        bounds: unionBounds((factual + [evidence]).map(\.bounds)),
                        behavior: .wideResponse,
                        evidence: factual + [evidence],
                        // A high-confidence support lifecycle born at a nearby
                        // factual action is downstream fusion evidence for that
                        // action. Held lifecycles remain framing-only and cannot
                        // repeatedly claim their birth transition.
                        observationIDs: claimsForegroundBirth
                            ? [lifecycle.gainedObservationID] : [],
                        observationClass: lifecycleClass,
                        cost: factual.isEmpty ? 0.34 : 0.18
                    ))
                    nextAttentionID += 1
                }

                // Long-running visual responses remain scene evidence for
                // every action that occurs while they are active. This lets
                // the global solver hold one useful shot through playback,
                // progress animations, and live previews instead of treating
                // the response as a one-frame click decoration and returning
                // to overview at the next locationless control.
                for entry in orderedObservations where
                    entry.element.time - entry.element.startTime >= 0.75
                    && entry.element.timeRange.contains(timing.activation)
                    && SpatialMotion.isFramingEligible(entry.element)
                    && observationIsAvailable(
                        entry,
                        at: timing.activation,
                        condition: evaluationCondition,
                        supportObservationIDs: supportObservationIDs,
                        lifecycles: lifecycles,
                        observations: orderedObservations
                    ) {
                    let evidence = visualEvidence(
                        observationID: entry.offset,
                        observation: entry.element,
                        actionID: action.id,
                        contentRect: contentRect,
                        size: composition.size
                    )
                    hypotheses.append(AttentionHypothesis(
                        id: nextAttentionID,
                        actionID: action.id,
                        timingID: timing.id,
                        bounds: unionBounds((factual + [evidence]).map(\.bounds)),
                        behavior: .wideResponse,
                        evidence: factual + [evidence],
                        // An already-running response is scene context, not
                        // proof that this action caused it. Keep it available
                        // for framing without letting the action claim the
                        // observation in the global explanation objective.
                        observationIDs: [],
                        observationClass: plannerObservationClass(
                            observationID: entry.offset,
                            observation: entry.element,
                            supportObservationIDs: supportObservationIDs
                        ),
                        cost: factual.isEmpty ? 0.16 : 0.10
                    ))
                    nextAttentionID += 1
                }
            }

            // Preserve a diverse top-K lattice. Deduplication is exact in
            // interpretation space, not a spatial nearest-neighbor collapse.
            let ranked = hypotheses.sorted {
                if abs($0.cost - $1.cost) > 0.000_001 { return $0.cost < $1.cost }
                if $0.timingID != $1.timingID { return $0.timingID < $1.timingID }
                return $0.id < $1.id
            }
            var retained: [AttentionHypothesis] = []
            for candidate in ranked {
                let duplicate = retained.contains {
                    $0.timingID == candidate.timingID
                        && $0.behavior == candidate.behavior
                        && $0.observationIDs == candidate.observationIDs
                        && rectApproximatelyEqual($0.bounds, candidate.bounds)
                }
                if !duplicate { retained.append(candidate) }
                if retained.count >= 24 { break }
            }
            nodes.append(ActionNode(action: action, timings: timings, attention: retained))
        }

        for entry in orderedObservations {
            allAttributions.append(AttributionHypothesis(
                observationID: entry.offset,
                actionID: nil,
                cost: entry.element.kind == .translation ? 0.10 : 1.15,
                temporalDistance: .infinity,
                spatialAgreement: 0
            ))
        }
        return ProductionPlanGraph(
            size: composition.size,
            contentRect: contentRect,
            sourceDuration: sourceDuration,
            actions: nodes,
            observations: observations,
            actionResponseSlices: actionResponseSlices,
            motionRanges: motionRanges,
            lifecycles: lifecycles,
            attributions: allAttributions,
            evaluationCondition: evaluationCondition,
            supportObservationIDs: supportObservationIDs
        )
    }

    public func resolvedActions(
        from decisions: [GlobalProductionPlan.Decision]
    ) -> [DirectedAction] {
        let selected = Dictionary(uniqueKeysWithValues: decisions.map { ($0.actionID, $0) })
        return actions.map { node in
            guard let decision = selected[node.action.id],
                  let attention = node.attention.first(where: { $0.id == decision.attentionID })
            else { return node.action }
            let resolvedAttention: AttentionDecision?
            if let bounds = attention.bounds, let behavior = attention.behavior {
                resolvedAttention = AttentionDecision(
                    bounds: bounds,
                    confidence: attention.evidence.map(\.confidence).max() ?? 0,
                    behavior: behavior,
                    evidence: attention.evidence
                )
            } else {
                resolvedAttention = nil
            }
            let action = node.action
            return DirectedAction(
                id: action.id, actionId: action.actionId, kind: action.kind,
                time: decision.activation, point: action.point, from: action.from, to: action.to,
                duration: action.duration, semanticBounds: action.semanticBounds,
                interactionContainerBounds: action.interactionContainerBounds,
                interactionCandidateBounds: action.interactionCandidateBounds,
                interactionContainerVerifiedThrough: action.interactionContainerVerifiedThrough,
                pointProvenance: action.pointProvenance, pointConfidence: action.pointConfidence,
                cursorAllowed: action.cursorAllowed, emphasis: action.emphasis,
                holdExtension: action.holdExtension, requiresExactTarget: action.requiresExactTarget,
                requiresEstablishingTransition: action.requiresEstablishingTransition,
                relocationSettleDelay: action.relocationSettleDelay,
                attention: resolvedAttention, episodeID: nil
            )
        }.sorted { $0.time < $1.time }
    }

    public func resolvedInteractionPhases(
        from decisions: [GlobalProductionPlan.Decision],
        existing: [Int: InteractionPhases]
    ) -> [Int: InteractionPhases] {
        var result = existing
        for decision in decisions {
            guard let node = actions.first(where: { $0.action.id == decision.actionID }),
                  let timing = node.timings.first(where: { $0.id == decision.timingID }),
                  let old = existing[decision.actionID]
            else { continue }
            // A visual response is useful only while it remains causally
            // compatible with the selected activation. Ordered action windows
            // can legitimately reject every response-aligned timing and fall
            // back to the factual telemetry estimate. In that case retain the
            // action, but abstain from the now-impossible response association
            // instead of carrying "effect before cause" into the next fixed
            // point iteration and the camera audit.
            let orderedResponseOnset = timing.responseOnset.flatMap {
                $0 + 0.08 >= timing.activation ? $0 : nil
            }
            result[decision.actionID] = InteractionPhases(
                rawEstimate: old.rawEstimate,
                toolStart: old.toolStart,
                toolEnd: old.toolEnd,
                pointerArrival: timing.pointerArrival,
                activation: timing.activation,
                responseOnset: orderedResponseOnset,
                source: timing.source,
                activityThreshold: old.activityThreshold,
                prePointerActivityEnd: old.prePointerActivityEnd,
                preActivationActivityEnd: old.preActivationActivityEnd,
                pointerArrivalSource: timing.source,
                activityClusters: old.activityClusters
            )
        }
        return result
    }
}

private func timingHypotheses(
    for action: DirectedAction,
    phase: InteractionPhases?,
    causalResponseOnset: Double? = nil,
    activationWindow: ClosedRange<Double>? = nil
) -> [ProductionPlanGraph.TimingHypothesis] {
    guard let phase else {
        return [ProductionPlanGraph.TimingHypothesis(
            id: action.id * 1_000,
            actionID: action.id,
            pointerArrival: action.time,
            activation: action.time,
            responseOnset: nil,
            source: "timeline",
            cost: 0.45
        )]
    }
    struct Seed { let activation: Double; let source: String; let cost: Double }
    var seeds = [
        Seed(activation: phase.activation, source: phase.source, cost: 0.08),
        Seed(activation: phase.rawEstimate, source: "telemetry-estimate", cost: 0.72),
        Seed(activation: phase.toolEnd, source: "tool-completion", cost: 0.58),
    ]
    if let causalResponseOnset {
        seeds.append(Seed(
            activation: causalResponseOnset,
            source: "causal-response-onset",
            cost: 0.02
        ))
    }
    let threshold = max(0.001, phase.activityThreshold ?? 1)
    for cluster in phase.activityClusters {
        guard cluster.start >= phase.toolStart - 0.08,
              cluster.start <= phase.toolEnd + 0.25 else { continue }
        let strength = min(1, cluster.peak / (threshold * 5))
        seeds.append(Seed(
            activation: cluster.start,
            source: "visual-cluster-start",
            cost: 0.48 - strength * 0.32
        ))
        seeds.append(Seed(
            activation: cluster.peakTime,
            source: "visual-cluster-peak",
            cost: 0.55 - strength * 0.30
        ))
    }
    // A completed hover/arrival cluster is observed chronology, not an
    // editorial preference. Later visual clusters remain useful competing
    // activation candidates, but no hypothesis may move the click to before
    // that factual activity has settled.
    if causalResponseOnset == nil, let activityEnd = phase.preActivationActivityEnd {
        let causalFloor = activityEnd + 0.05
        seeds.removeAll { $0.activation < causalFloor - 0.001 }
    }
    if let causalResponseOnset {
        // Apply this after visual-cluster candidates are added. A sustained
        // response owns the activity at its onset, so that activity cannot
        // simultaneously be treated as pre-click hover evidence or permit a
        // later cluster/tool-completion candidate to reverse cause and effect.
        seeds.removeAll { $0.activation > causalResponseOnset + 0.08 }
    }
    if let activationWindow {
        seeds.removeAll { !activationWindow.contains($0.activation) }
    }
    // The adapter's estimate is the ordered factual fallback. Visual timing
    // may refine it, but an ambiguous or over-constrained visual lattice must
    // never erase the action itself.
    if seeds.isEmpty {
        seeds = [Seed(
            activation: phase.rawEstimate,
            source: "telemetry-order-fallback",
            cost: 0.76
        )]
    }
    seeds.sort {
        if abs($0.cost - $1.cost) > 0.000_001 { return $0.cost < $1.cost }
        return $0.activation < $1.activation
    }
    var unique: [Seed] = []
    for seed in seeds where !unique.contains(where: { abs($0.activation - seed.activation) < 0.025 }) {
        unique.append(seed)
        if unique.count >= 8 { break }
    }
    return unique.enumerated().map { index, seed in
        let shift = seed.activation - phase.activation
        return ProductionPlanGraph.TimingHypothesis(
            id: action.id * 1_000 + index,
            actionID: action.id,
            pointerArrival: min(seed.activation, max(phase.toolStart, phase.pointerArrival + shift)),
            activation: seed.activation,
            responseOnset: causalResponseOnset ?? phase.responseOnset.map { $0 + shift },
            source: seed.source,
            cost: seed.cost
        )
    }
}

private func orderedActivationWindows(
    actions: [DirectedAction],
    phases: [Int: InteractionPhases]
) -> [Int: ClosedRange<Double>] {
    // Computer Use log order is factual across tool envelopes, not only
    // within one shared node_repl call. Visual response timing may refine an
    // action, but it cannot move that action across either adjacent recorded
    // action. Partition the entire ordered action sequence at the midpoints
    // between its factual estimates. This leaves a wide refinement interval
    // while preventing a response onset from reversing cause and effect.
    let ordered = actions.sorted {
        if abs($0.time - $1.time) > 0.000_001 { return $0.time < $1.time }
        return $0.id < $1.id
    }
    let estimates = ordered.map { action in
        phases[action.id]?.rawEstimate ?? action.time
    }
    var result: [Int: ClosedRange<Double>] = [:]
    for index in ordered.indices {
        guard let phase = phases[ordered[index].id] else { continue }
        let estimate = estimates[index]
        let lower = index == ordered.startIndex
            ? min(phase.toolStart, estimate)
            : (estimates[index - 1] + estimate) / 2 + 0.001
        let upper = index == ordered.index(before: ordered.endIndex)
            ? max(phase.toolEnd, estimate)
            : (estimate + estimates[index + 1]) / 2 - 0.001
        // A malformed or duplicate timestamp must not erase the factual raw
        // estimate. The composition has already imposed a strict log order,
        // so this is only a numerical guard around coincident boundaries.
        result[ordered[index].id] = min(lower, estimate)...max(upper, estimate)
    }
    return result
}

private func causalResponseOnsets(
    actions: [DirectedAction],
    phases: [Int: InteractionPhases],
    observations: [VisualMotionObservation]
) -> [Int: Double] {
    // Sustained structural motion is clip-level evidence. Assign each onset
    // once to the chronologically nearest action whose factual tool envelope
    // begins with it. This prevents one long animation from constraining every
    // later action while still allowing the global solver to use information
    // that a target-local hover detector cannot see.
    let candidates = observations.filter { observation in
        observation.kind != .translation
            && observation.time - observation.startTime >= 0.75
            && SpatialMotion.isFramingEligible(observation)
    }.sorted { $0.startTime < $1.startTime }
    var result: [Int: Double] = [:]
    for observation in candidates {
        let eligible = actions.compactMap { action -> (DirectedAction, InteractionPhases, Double)? in
            guard result[action.id] == nil,
                  ["click", "drag"].contains(action.kind),
                  let phase = phases[action.id],
                  observation.startTime >= phase.toolStart - 0.35,
                  observation.startTime <= phase.toolEnd + 0.10,
                  observation.time >= phase.toolStart + 0.30
            else { return nil }
            let boundedOnset = max(phase.toolStart, observation.startTime)
            return (action, phase, boundedOnset)
        }
        guard let owner = eligible.min(by: { left, right in
            let leftDistance = abs(left.1.rawEstimate - left.2)
            let rightDistance = abs(right.1.rawEstimate - right.2)
            if abs(leftDistance - rightDistance) > 0.000_001 {
                return leftDistance < rightDistance
            }
            return left.0.time < right.0.time
        }) else { continue }
        result[owner.0.id] = owner.2
    }
    return result
}

private func factualEvidence(for action: DirectedAction) -> [AttentionEvidence] {
    let interval = action.time...(action.time + max(0.15, action.duration))
    var result: [AttentionEvidence] = []
    if action.kind == "drag", let from = action.from, let to = action.to {
        result.append(AttentionEvidence(
            source: .dragPath,
            timeRange: interval,
            bounds: CGRect(
                x: min(from.x, to.x), y: min(from.y, to.y),
                width: abs(to.x - from.x), height: abs(to.y - from.y)
            ).insetBy(dx: -36, dy: -36),
            confidence: 0.99, framingWeight: 1, persistence: 0.8,
            causalActionID: action.id
        ))
    } else if let point = action.point, ["click", "drag"].contains(action.kind) {
        result.append(AttentionEvidence(
            source: action.pointProvenance == "visual-inferred" ? .visualPointer : .pointer,
            timeRange: interval,
            bounds: CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52),
            confidence: action.pointProvenance == "visual-inferred" ? 0.52 : 0.99,
            framingWeight: action.pointProvenance == "visual-inferred" ? 0.22 : 0.9,
            persistence: 0.45,
            causalActionID: action.id
        ))
    }
    if let bounds = action.semanticBounds {
        result.append(AttentionEvidence(
            source: .accessibility,
            timeRange: interval,
            bounds: bounds.insetBy(dx: -12, dy: -12),
            confidence: 0.99, framingWeight: 1.15, persistence: 0.95,
            causalActionID: action.id
        ))
    }
    return result
}

private func attributionHypothesis(
    observationID: Int,
    observation: VisualMotionObservation,
    action: DirectedAction,
    activation: Double,
    contentRect: CGRect,
    size: CGSize,
    isOracleSupport: Bool = false
) -> ProductionPlanGraph.AttributionHypothesis {
    // A sustained response is attributed by its onset, while its complete
    // range remains available for reading holds and camera continuity.
    let responseOnset = observation.startTime
    let delta = responseOnset - activation
    let analysisTolerance = isOracleSupport || observation.time - observation.startTime >= 0.75
        ? 0.35 : 0.08
    guard responseOnset >= activation - analysisTolerance, delta <= 1.75 else {
        return .init(observationID: observationID, actionID: action.id, cost: 9, temporalDistance: abs(delta), spatialAgreement: 0)
    }
    let mapped = mapObservation(observation, contentRect: contentRect, size: size)
    let facts = factualEvidence(for: action)
    let factualBounds = unionBounds(facts.map(\.bounds))
    let agreement: Double
    if let factualBounds {
        let intersection = mapped.intersection(factualBounds)
        agreement = intersection.isNull ? 0 : Double(intersection.width * intersection.height / max(1, min(mapped.width * mapped.height, factualBounds.width * factualBounds.height)))
    } else {
        agreement = 0.35
    }
    let preferredDelay = observation.kind == .focus || observation.kind == .contextTransition ? 0.28 : 0.38
    let effectiveDelta = max(0, delta)
    let temporal = abs(effectiveDelta - preferredDelay)
    let futurePenalty = delta < -analysisTolerance ? 1.0 : 0
    return .init(
        observationID: observationID,
        actionID: action.id,
        cost: temporal * 1.35 + (1 - agreement) * 0.55 + futurePenalty,
        temporalDistance: temporal,
        spatialAgreement: agreement
    )
}

private func visualEvidence(
    observationID: Int,
    observation: VisualMotionObservation,
    actionID: Int,
    contentRect: CGRect,
    size: CGSize
) -> AttentionEvidence {
    let mapped = mapObservation(observation, contentRect: contentRect, size: size)
    let source: EvidenceSource = switch observation.kind {
    case .focus: .visualFocus
    case .contextTransition: .contextTransition
    default: .visualResponse
    }
    let area = mapped.width * mapped.height / max(1, size.width * size.height)
    return AttentionEvidence(
        source: source,
        timeRange: observation.timeRange,
        bounds: mapped.insetBy(dx: -16, dy: -16).intersection(CGRect(origin: .zero, size: size)),
        confidence: min(0.96, max(0.58, 0.58 + observation.changedFraction * 18 + observation.magnitude * 0.8)),
        framingWeight: min(1.1, max(0.3, Double(area) * 5 + observation.changedFraction * 16)),
        persistence: min(1, max(0.25, Double(area) * 3)),
        causalActionID: actionID,
        focusTransition: observation.focusTransition
    )
}

private func plannerObservationClass(
    observationID: Int,
    observation: VisualMotionObservation,
    supportObservationIDs: Set<Int>
) -> PlannerObservationClass {
    if supportObservationIDs.contains(observationID) { return .oracleForegroundSupport }
    switch observation.kind {
    case .contextTransition: return .requiredContext
    case .focus: return .foregroundEditorial
    case .appearance, .transformation, .translation: return .motionEditorial
    }
}

/// In condition D, oracle support is a gate rather than another rectangle the
/// planner must explain. While a support span is active (or being born),
/// unrelated ordinary motion is excluded from that action's hypothesis set.
/// With no oracle support nearby, the gate is neutral and preserves recall.
private func observationIsAvailable(
    _ entry: (offset: Int, element: VisualMotionObservation),
    at time: Double,
    condition: ProductionEvaluationCondition,
    supportObservationIDs: Set<Int>,
    lifecycles: [ProductionPlanGraph.SurfaceLifecycle],
    observations: [(offset: Int, element: VisualMotionObservation)]
) -> Bool {
    guard condition.gatesMotionWithOracleSupport,
          !supportObservationIDs.contains(entry.offset),
          entry.element.kind != .contextTransition else { return true }
    let supportBounds = observations.compactMap { candidate -> CGRect? in
        guard supportObservationIDs.contains(candidate.offset) else { return nil }
        let lifecycleActive = candidate.element.focusTransition == .gained && lifecycles.contains {
            $0.gainedObservationID == candidate.offset && $0.contains(time)
        }
        let boundaryIsNear = candidate.element.time >= time - 0.35
            && candidate.element.time <= time + 1.75
        return lifecycleActive || boundaryIsNear ? candidate.element.normalizedBounds : nil
    }
    guard !supportBounds.isEmpty else { return true }
    return supportBounds.contains { overlap($0, entry.element.normalizedBounds) >= 0.15 }
}

private func lifecycleIsAvailable(
    _ lifecycle: ProductionPlanGraph.SurfaceLifecycle,
    at time: Double,
    condition: ProductionEvaluationCondition,
    supportObservationIDs: Set<Int>,
    lifecycles: [ProductionPlanGraph.SurfaceLifecycle],
    observations: [VisualMotionObservation]
) -> Bool {
    guard condition.gatesMotionWithOracleSupport,
          !supportObservationIDs.contains(lifecycle.gainedObservationID) else { return true }
    let activeOracle = lifecycles.filter { lifecycle in
        guard supportObservationIDs.contains(lifecycle.gainedObservationID) else { return false }
        let boundaryIDs = [lifecycle.gainedObservationID, lifecycle.releasedObservationID].compactMap { $0 }
        let boundaryIsNear = boundaryIDs.contains { observationID in
            let boundary = observations[observationID].time
            return boundary >= time - 0.35 && boundary <= time + 1.75
        }
        return lifecycle.contains(time) || boundaryIsNear
    }
    guard !activeOracle.isEmpty else { return true }
    return activeOracle.contains { overlap($0.bounds, lifecycle.bounds) >= 0.15 }
}

private func buildLifecycles(
    observations: [(offset: Int, element: VisualMotionObservation)],
    contentRect: CGRect,
    size: CGSize
) -> [ProductionPlanGraph.SurfaceLifecycle] {
    var active: [(id: Int, bounds: CGRect, time: Double, observationID: Int)] = []
    var result: [ProductionPlanGraph.SurfaceLifecycle] = []
    var nextID = 0
    for entry in observations where entry.element.kind == .focus {
        let bounds = mapObservation(entry.element, contentRect: contentRect, size: size)
        switch entry.element.focusTransition {
        case .gained:
            active.append((nextID, bounds, entry.element.time, entry.offset))
            nextID += 1
        case .held, .updated:
            if let match = active.indices.max(by: {
                overlap(active[$0].bounds, bounds) < overlap(active[$1].bounds, bounds)
            }), overlap(active[match].bounds, bounds) >= 0.45 {
                let current = active[match]
                active[match] = (current.id, current.bounds.union(bounds), current.time, current.observationID)
            }
        case .released:
            guard let match = active.enumerated().max(by: {
                overlap($0.element.bounds, bounds) < overlap($1.element.bounds, bounds)
            }), overlap(match.element.bounds, bounds) >= 0.45 else { continue }
            let birth = active.remove(at: match.offset)
            result.append(.init(
                id: birth.id,
                bounds: birth.bounds,
                gainedAt: birth.time,
                releasedAt: entry.element.time,
                gainedObservationID: birth.observationID,
                releasedObservationID: entry.offset
            ))
        case .invalidated, .reset:
            for birth in active {
                result.append(.init(
                    id: birth.id,
                    bounds: birth.bounds,
                    gainedAt: birth.time,
                    releasedAt: entry.element.time,
                    gainedObservationID: birth.observationID,
                    releasedObservationID: entry.offset
                ))
            }
            active.removeAll()
        case nil:
            continue
        }
    }
    result += active.map {
        .init(id: $0.id, bounds: $0.bounds, gainedAt: $0.time, releasedAt: nil, gainedObservationID: $0.observationID, releasedObservationID: nil)
    }
    return result.sorted { $0.gainedAt < $1.gainedAt }
}

private func mapObservation(_ observation: VisualMotionObservation, contentRect: CGRect, size: CGSize) -> CGRect {
    mapNormalizedBounds(observation.normalizedBounds, contentRect: contentRect, size: size)
}

private func mapNormalizedBounds(_ bounds: CGRect, contentRect: CGRect, size: CGSize) -> CGRect {
    CGRect(
        x: contentRect.minX + bounds.minX * contentRect.width,
        y: contentRect.maxY - bounds.maxY * contentRect.height,
        width: bounds.width * contentRect.width,
        height: bounds.height * contentRect.height
    ).intersection(CGRect(origin: .zero, size: size))
}

private func behavior(for observation: VisualMotionObservation, action: DirectedAction) -> CameraBehavior {
    if observation.kind == .contextTransition { return .overview }
    if observation.kind == .focus { return .wideResponse }
    if action.semanticBounds != nil || action.point != nil { return .region }
    return .wideResponse
}

private func factualBehavior(for action: DirectedAction) -> CameraBehavior {
    action.semanticBounds != nil || action.kind == "drag" ? .region : .point
}

private func unionBounds(_ values: [CGRect]) -> CGRect? {
    guard let first = values.first else { return nil }
    return values.dropFirst().reduce(first) { $0.union($1) }
}

private func overlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
    let intersection = left.intersection(right)
    guard !intersection.isNull else { return 0 }
    return intersection.width * intersection.height / max(1, min(left.width * left.height, right.width * right.height))
}

private func rectApproximatelyEqual(_ left: CGRect?, _ right: CGRect?) -> Bool {
    switch (left, right) {
    case (nil, nil): return true
    case let (left?, right?):
        return abs(left.minX - right.minX) < 0.5
            && abs(left.minY - right.minY) < 0.5
            && abs(left.width - right.width) < 0.5
            && abs(left.height - right.height) < 0.5
    default: return false
    }
}
