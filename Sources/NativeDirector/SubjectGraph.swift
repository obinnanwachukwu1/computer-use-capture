import CoreGraphics
import Foundation

/// Persistent visual subjects inferred from capture facts and scene evidence.
///
/// A subject is deliberately not a camera instruction. It says what exists,
/// where it is, and which actions belong to it. Shot scheduling happens in a
/// later layer so motion detection cannot manufacture an editorial outcome.
public struct SubjectGraph: Sendable {
    public enum Kind: String, Sendable {
        case viewport
        case surface
        case target
        case response
    }

    public struct Subject: Sendable {
        public struct OverviewBlame: Sendable {
            public struct ResponseEvidence: Sendable {
                public let id: Int
                public let startTime: Double
                public let endTime: Double
                public let normalizedBounds: CGRect
                public let changedFraction: Double
                public let confidence: Double
                public let kind: VisualMotionKind

                public init(_ evidence: ActionResponseSlice.Evidence) {
                    id = evidence.id
                    startTime = evidence.startTime
                    endTime = evidence.endTime
                    normalizedBounds = evidence.normalizedBounds
                    changedFraction = evidence.changedFraction
                    confidence = evidence.confidence
                    kind = evidence.kind
                }
            }

            public struct ActionEvidence: Sendable {
                public let actionID: Int
                public let broadObservationIDs: Set<Int>
                public let preexistingBroadObservationIDs: Set<Int>
                public let broadResponseEvidence: [ResponseEvidence]
                public let preexistingResponseEvidence: [ResponseEvidence]
                public let crossBoundaryResponseEvidence: [ResponseEvidence]
                public let broadWeight: Double
                public let localizedObservationIDs: Set<Int>
                public let localizedWeight: Double
                public let causalBasis: String
                public let reason: String

                public init(
                    actionID: Int,
                    broadObservationIDs: Set<Int>,
                    preexistingBroadObservationIDs: Set<Int>,
                    broadResponseEvidence: [ResponseEvidence] = [],
                    preexistingResponseEvidence: [ResponseEvidence] = [],
                    crossBoundaryResponseEvidence: [ResponseEvidence] = [],
                    broadWeight: Double,
                    localizedObservationIDs: Set<Int>,
                    localizedWeight: Double,
                    causalBasis: String = "broad-onset-within-action-clock-window",
                    reason: String
                ) {
                    self.actionID = actionID
                    self.broadObservationIDs = broadObservationIDs
                    self.preexistingBroadObservationIDs = preexistingBroadObservationIDs
                    self.broadResponseEvidence = broadResponseEvidence
                    self.preexistingResponseEvidence = preexistingResponseEvidence
                    self.crossBoundaryResponseEvidence = crossBoundaryResponseEvidence
                    self.broadWeight = broadWeight
                    self.localizedObservationIDs = localizedObservationIDs
                    self.localizedWeight = localizedWeight
                    self.causalBasis = causalBasis
                    self.reason = reason
                }
            }

            public let actions: [ActionEvidence]

            public init(actions: [ActionEvidence]) {
                self.actions = actions
            }
        }

        public struct FramingHypothesis: Sendable {
            public let id: Int
            public let bounds: CGRect
            public let observationIDs: Set<Int>
            /// Fraction of the subject's action-aligned visual evidence that
            /// remains visible in this framing proposal. This is deliberately
            /// not a confidence that the rectangle is an object: hypotheses
            /// are transition-local diagnostics and are not camera facts.
            public let evidenceCoverage: Double

            public init(
                id: Int,
                bounds: CGRect,
                observationIDs: Set<Int> = [],
                evidenceCoverage: Double = 1
            ) {
                self.id = id
                self.bounds = bounds
                self.observationIDs = observationIDs
                self.evidenceCoverage = evidenceCoverage
            }
        }

        public let id: Int
        public let kind: Kind
        public let bounds: CGRect
        public let sourceRange: ClosedRange<Double>
        public let actionIDs: [Int]
        public let observationIDs: Set<Int>
        public let confidence: Double
        /// Earliest source time at which a tight shot may begin. A foreground
        /// surface can exist before the cursor or semantic focus enters it;
        /// that existence is useful for ownership but is not yet permission
        /// to pull the camera away from the outside opener.
        public let framingEligibleAt: Double?
        /// True only when the subject's visible birth and release are backed by
        /// an externally verified foreground-support lifecycle. This is a fact
        /// about the subject, not an instruction to move the camera.
        public let isForegroundSupport: Bool
        /// True when actions in this subject produced only a broad unresolved
        /// visual response. The response extent is scene evidence: until a
        /// localized response is available, a close-up would knowingly hide
        /// part of the effect. This constrains framing without turning motion
        /// into an autonomous camera command.
        public let requiresOverview: Bool
        /// Present only when `requiresOverview` is backed by unresolved broad
        /// response evidence. It records the complete causal blame chain so a
        /// conservative camera decision is auditable rather than opaque.
        public let overviewBlame: OverviewBlame?
        /// The measured disappearance boundary. Kept separate from
        /// `sourceRange` because a causally related close action may be owned
        /// by this subject even when its inferred action time lands just after
        /// the last frame in which the surface was visible.
        public let verifiedReleaseTime: Double?
        /// Competing, action-aligned geometric explanations for the response.
        /// `bounds` remains the complete subject geometry and ownership fact.
        /// These alternatives are preserved for evaluation and debugging, but
        /// are deliberately not consumed by the production scheduler until a
        /// held-out camera gate demonstrates an editorial improvement.
        public let framingHypotheses: [FramingHypothesis]

        public init(
            id: Int,
            kind: Kind,
            bounds: CGRect,
            sourceRange: ClosedRange<Double>,
            actionIDs: [Int],
            observationIDs: Set<Int> = [],
            confidence: Double,
            framingEligibleAt: Double? = nil,
            isForegroundSupport: Bool = false,
            requiresOverview: Bool = false,
            overviewBlame: OverviewBlame? = nil,
            verifiedReleaseTime: Double? = nil,
            framingHypotheses: [FramingHypothesis] = []
        ) {
            self.id = id
            self.kind = kind
            self.bounds = bounds
            self.sourceRange = sourceRange
            self.actionIDs = actionIDs
            self.observationIDs = observationIDs
            self.confidence = confidence
            self.framingEligibleAt = framingEligibleAt
            self.isForegroundSupport = isForegroundSupport
            self.requiresOverview = requiresOverview
            self.overviewBlame = overviewBlame
            self.verifiedReleaseTime = verifiedReleaseTime
            self.framingHypotheses = framingHypotheses
        }
    }

    public struct SceneTransition: Sendable {
        public let observationID: Int
        public let sourceTime: Double
        public let causalActionID: Int?
        public let responseSubjectID: Int?

        public init(
            observationID: Int,
            sourceTime: Double,
            causalActionID: Int?,
            responseSubjectID: Int?
        ) {
            self.observationID = observationID
            self.sourceTime = sourceTime
            self.causalActionID = causalActionID
            self.responseSubjectID = responseSubjectID
        }
    }

    public let size: CGSize
    public let subjects: [Subject]
    public let transitions: [SceneTransition]

    public init(size: CGSize, subjects: [Subject], transitions: [SceneTransition]) {
        self.size = size
        self.subjects = subjects
        self.transitions = transitions
    }

    public static func make(
        graph: ProductionPlanGraph,
        composition: NativeComposition
    ) -> SubjectGraph {
        let canvas = CGRect(origin: .zero, size: graph.size)
        let orderedActions = graph.actions.map(\.action).sorted { $0.time < $1.time }
        let transitionEntries = graph.observations.enumerated().filter {
            $0.element.kind == .contextTransition
        }
        let inferredSceneTransitions = sustainedActionAlignedSceneTransitions(
            graph: graph, actions: orderedActions
        )
        let transitionTimes = transitionEntries.map(\.element.time)
            + inferredSceneTransitions.map(\.sourceTime)
        let transitionCausalActionIDs = Set(transitionEntries.compactMap { entry in
            graph.attributions
                .filter { $0.observationID == entry.offset && $0.actionID != nil }
                .min { $0.cost < $1.cost }?.actionID
        }).union(inferredSceneTransitions.map(\.causalActionID))
        let localizedReveals = localizedRevealEvidence(
            graph: graph, actions: orderedActions, canvas: canvas
        )
        let localizedReleases = localizedReleaseEvidence(
            graph: graph, actions: orderedActions, canvas: canvas
        )
        let broadResponseEvidence = broadUnresolvedResponseActions(
            graph: graph, actions: orderedActions
        )
        var nextSubjectID = 0
        var subjects: [Subject] = []
        var assigned = Set<Int>()

        // A measured focus lifecycle is the strongest persistent-surface fact.
        // Only independently supported foreground lifecycles can own a
        // persistent surface. Detector-only focus remains action evidence; it
        // must not turn a long-lived sidebar highlight or selection state into
        // camera ownership between otherwise unrelated interactions.
        for lifecycle in graph.lifecycles {
            guard graph.supportObservationIDs.contains(lifecycle.gainedObservationID) else {
                continue
            }
            let lifecycleArea = lifecycle.bounds.width * lifecycle.bounds.height
                / max(1, graph.size.width * graph.size.height)
            // Verified geometry is a fact, not a camera proposal. Preserve
            // every non-empty lifecycle here and let ShotSchedule decide
            // whether its readable benefit justifies a move. Applying a
            // minimum-area cutoff in the fact graph silently discarded menus,
            // pickers, and notices before the global objective could compare
            // them with travel cost.
            guard lifecycleArea > 0, lifecycleArea <= 0.75 else { continue }
            let birthAttributions = graph.attributions
                .filter {
                    $0.observationID == lifecycle.gainedObservationID
                        && $0.actionID != nil
                        && $0.cost < 2.5
                }
            // If multiple actions are causally plausible, a control at the
            // measured birth boundary outranks an older action merely because
            // the generic response-delay prior prefers ~280 ms. This keeps a
            // surface from starting before an intervening, adjacent opener.
            // External triggers remain supported through the attribution-cost
            // fallback when no boundary-adjacent action exists.
            let boundaryBirthAction = orderedActions
                .filter {
                    $0.time >= lifecycle.gainedAt - 0.35
                        && $0.time <= lifecycle.gainedAt + (1.0 / 30.0)
                }
                .max { $0.time < $1.time }
            let causalBirthActionID = boundaryBirthAction?.id
                ?? birthAttributions.min { $0.cost < $1.cost }?.actionID
            let actions = orderedActions.filter { action in
                // Capture timestamps and detector boundaries come from
                // independent clocks. Treat one analysis frame around a
                // measured birth as the same boundary so an action at
                // 14.880998 is not split from a surface born at 14.881.
                // This is temporal uncertainty, not permission to pull an
                // unrelated earlier action into the foreground owner.
                let ownsBirthBoundary = action.time >= lifecycle.gainedAt - (1.0 / 30.0)
                    && action.time <= lifecycle.gainedAt + (1.0 / 30.0)
                let ownsReleaseBoundary = lifecycle.releasedAt.map {
                    action.time > $0 && action.time - $0 <= 0.35
                } ?? false
                guard lifecycle.contains(action.time)
                        || ownsBirthBoundary
                        || ownsReleaseBoundary
                        || action.id == causalBirthActionID
                else { return false }
                return action.id == causalBirthActionID
                    || spatiallyRelated(actionBounds(action, canvas: canvas), lifecycle.bounds)
                    || ownsBirthBoundary && spatiallyAdjacentAtBirth(
                        actionBounds(action, canvas: canvas), lifecycle.bounds, canvas: canvas
                    )
            }
            guard !actions.isEmpty else { continue }
            // The lifecycle owns editorial framing geometry. Pointer and AX
            // rectangles remain hard feasibility constraints in the camera
            // compiler, but must not pull the visual center away from the
            // surface itself (for example, an opener just outside a modal).
            let bounds = lifecycle.bounds.insetBy(dx: -18, dy: -18).intersection(canvas)
            let end = lifecycle.releasedAt ?? actions.map { NativeComposition.holdEnd(for: $0) }.max()!
            subjects.append(Subject(
                id: nextSubjectID,
                kind: .surface,
                bounds: bounds,
                sourceRange: min(lifecycle.gainedAt, actions[0].time)...max(end, actions.last!.time),
                actionIDs: actions.map(\.id),
                observationIDs: Set([lifecycle.gainedObservationID, lifecycle.releasedObservationID].compactMap { $0 }),
                confidence: 0.96,
                framingEligibleAt: foregroundFramingEntry(
                    lifecycle: lifecycle,
                    actions: actions,
                    composition: composition,
                    sourceDuration: graph.sourceDuration
                ),
                isForegroundSupport: true,
                verifiedReleaseTime: lifecycle.releasedAt
            ))
            nextSubjectID += 1
            assigned.formUnion(actions.map(\.id))
        }

        // Infer the remaining interaction episodes as a global partition of
        // the ordered actions. The previous implementation appended each
        // action to a mutable run and therefore committed an opener to an
        // earlier nearby action before a later factual anchor could explain
        // the complete episode. Candidate intervals now coexist until a
        // dynamic program selects the most coherent cover of the timeline.
        // This remains a subject proposal, not a shot decision.
        let unassignedBlocks = contiguousUnassignedActionBlocks(
            actions: orderedActions,
            assigned: assigned
        )
        for block in unassignedBlocks {
            let episodes = globallyInferredActionEpisodes(
                actions: block,
                graph: graph,
                composition: composition,
                canvas: canvas,
                transitionTimes: transitionTimes,
                transitionCausalActionIDs: transitionCausalActionIDs,
                localizedReveals: localizedReveals,
                localizedReleases: localizedReleases,
                broadResponseEvidence: broadResponseEvidence
            )
            for (episodeIndex, episode) in episodes.enumerated() {
                let firstAction = episode.actions[0]
                let previousOrderedAction = orderedActions.last {
                    $0.time < firstAction.time && !episode.actions.map(\.id).contains($0.id)
                }
                // Offline inference may know the next subject before it is
                // visible, but an explicit ordered viewport translation owns
                // the frame until the following action begins. Do not let a
                // future localized response pull the camera into geometry
                // that is still arriving through the preceding scroll.
                // This boundary comes from the Computer Use action order—not
                // a fixed delay, control role, or detected pixel coordinate.
                let orderedViewportEntry = previousOrderedAction?.kind == "scroll"
                    ? firstAction.time
                    : nil
                let framingEligibleAt = [
                    episode.framingEligibleAt,
                    orderedViewportEntry
                ].compactMap { $0 }.max()
                let nextAction = episodes.indices.contains(episodeIndex + 1)
                    ? episodes[episodeIndex + 1].actions.first
                    : orderedActions.first { $0.time > episode.actions.last!.time }
                let measuredEnd = (
                    episode.actions.compactMap(\.interactionContainerVerifiedThrough)
                        + [episode.revealEnd].compactMap { $0 }
                ).max() ?? NativeComposition.holdEnd(for: episode.actions.last!)
                let boundaryStart = nextAction.flatMap { action -> Double? in
                    let candidates = [
                        composition.pointerTrip(forActionID: action.id)?.start,
                        NativeComposition.semanticVisibilityStart(for: action)
                    ].compactMap { $0 }
                    return candidates.min() ?? action.time
                }
                let subjectEnd = max(
                    episode.actions.last!.time,
                    boundaryStart.map { min(measuredEnd, $0) } ?? measuredEnd
                )
                let ownedRelease = episode.verifiedReleaseTime.flatMap { releaseTime in
                    releaseTime >= episode.actions.last!.time - 0.000_001 ? releaseTime : nil
                }
                let kind: Kind = episode.actions.count >= 2 || !episode.observationIDs.isEmpty
                    ? .surface : .target
                let padded = episode.bounds.insetBy(
                    dx: kind == .surface ? -18 : -24,
                    dy: kind == .surface ? -18 : -24
                ).intersection(canvas)
                let framingHypotheses = episode.framingHypotheses.map { hypothesis in
                    Subject.FramingHypothesis(
                        id: hypothesis.id,
                        bounds: hypothesis.bounds.insetBy(
                            dx: kind == .surface ? -18 : -24,
                            dy: kind == .surface ? -18 : -24
                        ).intersection(canvas),
                        observationIDs: hypothesis.observationIDs,
                        evidenceCoverage: hypothesis.evidenceCoverage
                    )
                }
                subjects.append(Subject(
                    id: nextSubjectID,
                    kind: kind,
                    bounds: padded,
                    sourceRange: episode.actions[0].time...max(
                        episode.actions.last!.time, subjectEnd
                    ),
                    actionIDs: episode.actions.map(\.id),
                    observationIDs: episode.observationIDs,
                    confidence: kind == .surface ? 0.78 : 0.92,
                    framingEligibleAt: framingEligibleAt,
                    requiresOverview: episode.requiresOverview,
                    overviewBlame: episode.overviewBlame,
                    verifiedReleaseTime: ownedRelease,
                    framingHypotheses: framingHypotheses
                ))
                nextSubjectID += 1
            }
        }


        // A context transition is an observed scene event. Preserve it as a
        // transition fact and attach a localized response proposal when the
        // raw structural stream supplies one; do not encode "must overview"
        // into the observation itself.
        var transitions: [SceneTransition] = []
        for entry in transitionEntries {
            let transition = entry.element
            let responseCandidates = graph.observations.enumerated().filter { candidate in
                let observation = candidate.element
                guard candidate.offset != entry.offset,
                      observation.time >= transition.time - 0.05,
                      observation.time <= transition.time + 1.25,
                      observation.kind == .appearance || observation.kind == .transformation,
                      SpatialMotion.isFramingEligible(observation)
                else { return false }
                let mapped = mapObservation(observation, graph: graph).intersection(canvas)
                let area = mapped.width * mapped.height / max(1, canvas.width * canvas.height)
                return area >= 0.015 && area <= 0.78
            }
            let bestResponse = responseCandidates.max { left, right in
                responseScore(left.element, graph: graph) < responseScore(right.element, graph: graph)
            }
            let responseID: Int?
            if let response = bestResponse {
                let bounds = mapObservation(response.element, graph: graph)
                    .insetBy(dx: -18, dy: -18).intersection(canvas)
                responseID = nextSubjectID
                subjects.append(Subject(
                    id: nextSubjectID,
                    kind: .response,
                    bounds: bounds,
                    sourceRange: transition.time...min(graph.sourceDuration, response.element.time + 2.4),
                    actionIDs: [],
                    observationIDs: [response.offset],
                    confidence: min(0.96, 0.62 + response.element.changedFraction * 10)
                ))
                nextSubjectID += 1
            } else {
                responseID = nil
            }
            let causalAction = graph.attributions
                .filter { $0.observationID == entry.offset && $0.actionID != nil }
                .min { $0.cost < $1.cost }?.actionID
            transitions.append(SceneTransition(
                observationID: entry.offset,
                sourceTime: transition.time,
                causalActionID: causalAction,
                responseSubjectID: responseID
            ))
        }
        // A sustained scene-scale response with a single causal action is an
        // orientation boundary even when the lower-level detector called it
        // appearance/transformation rather than contextTransition. It may
        // return an active close-up to overview, but it never proposes a
        // response close-up of its own. This preserves the distinction between
        // action-aligned global change and autonomous ordinary motion.
        transitions.append(contentsOf: inferredSceneTransitions.map {
            SceneTransition(
                observationID: $0.observationID,
                sourceTime: $0.sourceTime,
                causalActionID: $0.causalActionID,
                responseSubjectID: nil
            )
        })

        return SubjectGraph(
            size: graph.size,
            subjects: subjects.sorted {
                if $0.sourceRange.lowerBound != $1.sourceRange.lowerBound {
                    return $0.sourceRange.lowerBound < $1.sourceRange.lowerBound
                }
                return $0.id < $1.id
            },
            transitions: transitions.sorted { $0.sourceTime < $1.sourceTime }
        )
    }
}

private struct LocalizedRevealEvidence {
    let bounds: CGRect
    let sourceEnd: Double
    let observationIDs: Set<Int>
    /// A later factual action may independently confirm where an earlier
    /// unresolved interaction occurred. Keeping the anchor explicit lets the
    /// run builder span that factual boundary without turning elapsed time or
    /// a UI role into evidence of subject identity.
    let forwardAnchorActionID: Int?
    let isAnchorRelated: Bool
    /// Relative support within the transition-local response window. This is
    /// used only to order equally admissible geometry; it never creates a
    /// lifecycle, ownership claim, or camera move by itself.
    let evidenceWeight: Double
}

private struct LocalizedReleaseEvidence {
    let bounds: CGRect
    let sourceEnd: Double
    let observationIDs: Set<Int>
    /// Nil when the localized region disappeared but an enclosing surface was
    /// independently observed as still held. The geometry remains valid
    /// backward-looking evidence; only subject release is vetoed.
    let verifiedReleaseTime: Double?
}

private struct InferredSceneTransitionEvidence {
    let observationID: Int
    let sourceTime: Double
    let causalActionID: Int
}

private struct InferredActionEpisode {
    let actions: [DirectedAction]
    let bounds: CGRect
    let observationIDs: Set<Int>
    let revealEnd: Double?
    let verifiedReleaseTime: Double?
    let framingEligibleAt: Double?
    let requiresOverview: Bool
    let overviewBlame: SubjectGraph.Subject.OverviewBlame?
    let partitionScore: Double
    let framingHypotheses: [SubjectGraph.Subject.FramingHypothesis]
}

private struct BroadResponseCandidate {
    let observationID: Int?
    let responseEvidence: [ActionResponseSlice.Evidence]
    let start: Double
    let end: Double
    let weight: Double
}

private struct ActionBroadResponseEvidence {
    let aligned: [BroadResponseCandidate]
    let preexisting: [BroadResponseCandidate]
    let crossBoundary: [BroadResponseCandidate]

    var strongestAlignedWeight: Double? {
        aligned.map(\.weight).max()
    }
}

private struct ActionEpisodeEvidence {
    let directBounds: CGRect?
    let reveals: [LocalizedRevealEvidence]
    let fallbackBounds: CGRect
    let release: LocalizedReleaseEvidence?

    var reveal: LocalizedRevealEvidence? {
        reveals.filter(\.isAnchorRelated).max { left, right in
            if left.evidenceWeight != right.evidenceWeight {
                return left.evidenceWeight < right.evidenceWeight
            }
            return left.bounds.width * left.bounds.height
                < right.bounds.width * right.bounds.height
        }
    }

    var localizedBounds: CGRect? {
        switch (reveal?.bounds, release?.bounds) {
        case let (reveal?, release?): return reveal.union(release)
        case let (reveal?, nil): return reveal
        case let (nil, release?): return release
        case (nil, nil): return nil
        }
    }

    /// Geometry independently grounded by a Computer Use fact or by a visual
    /// response that the causal graph associated with this action. Optional
    /// attention is intentionally excluded so a scene-sized fallback cannot
    /// dilute an otherwise compact completed episode.
    var groundedBounds: CGRect? {
        switch (directBounds, localizedBounds) {
        case let (direct?, localized?): return direct.union(localized)
        case let (direct?, nil): return direct
        case let (nil, localized?): return localized
        case (nil, nil): return nil
        }
    }
}

/// Assigned foreground lifecycles are hard ownership facts. They divide the
/// remaining action order into independent inference problems without making
/// any local grouping decision inside those blocks.
private func contiguousUnassignedActionBlocks(
    actions: [DirectedAction],
    assigned: Set<Int>
) -> [[DirectedAction]] {
    var blocks: [[DirectedAction]] = []
    var block: [DirectedAction] = []
    for action in actions {
        if assigned.contains(action.id) {
            if !block.isEmpty { blocks.append(block) }
            block.removeAll(keepingCapacity: true)
        } else {
            block.append(action)
        }
    }
    if !block.isEmpty { blocks.append(block) }
    return blocks
}

/// Selects one globally coherent, contiguous cover of an action block.
///
/// Every possible interval is evaluated before any boundary is committed.
/// Strong completed evidence—most importantly a localized response confirmed
/// by the first later factual target—can therefore outvote an attractive but
/// weak spatial join with a preceding action. The scoring uses only geometry,
/// causal attribution, total action order, and observed transitions. It never
/// inspects application names, accessibility roles, labels, or control types.
private func globallyInferredActionEpisodes(
    actions: [DirectedAction],
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    canvas: CGRect,
    transitionTimes: [Double],
    transitionCausalActionIDs: Set<Int>,
    localizedReveals: [Int: [LocalizedRevealEvidence]],
    localizedReleases: [Int: LocalizedReleaseEvidence],
    broadResponseEvidence: [Int: ActionBroadResponseEvidence]
) -> [InferredActionEpisode] {
    guard !actions.isEmpty else { return [] }
    let evidence = actions.map { action -> ActionEpisodeEvidence in
        let direct = directActionBounds(action, canvas: canvas)
        let reveals = localizedReveals[action.id] ?? []
        let release = localizedReleases[action.id]
        return ActionEpisodeEvidence(
            directBounds: direct,
            reveals: reveals,
            fallbackBounds: direct
                ?? action.attention?.bounds.intersection(canvas)
                ?? canvas,
            release: release
        )
    }

    var candidates: [[InferredActionEpisode?]] = Array(
        repeating: Array(repeating: nil, count: actions.count),
        count: actions.count
    )
    for start in actions.indices {
        for end in start..<actions.count {
            candidates[start][end] = actionEpisodeCandidate(
                actions: actions,
                evidence: evidence,
                range: start...end,
                graph: graph,
                composition: composition,
                canvas: canvas,
                transitionTimes: transitionTimes,
                transitionCausalActionIDs: transitionCausalActionIDs,
                broadResponseEvidence: broadResponseEvidence
            )
        }
    }

    // Viterbi-style interval partition. A singleton has zero association
    // value, so an interval must provide positive evidence to remove a
    // boundary. Stable tie-breaking prefers fewer actions, keeping ambiguous
    // evidence separate for ShotSchedule to reconcile spatially if useful.
    var bestScore = Array(repeating: -Double.infinity, count: actions.count + 1)
    var bestCount = Array(repeating: Int.max, count: actions.count + 1)
    var previous = Array(repeating: -1, count: actions.count + 1)
    var chosen: [InferredActionEpisode?] = Array(repeating: nil, count: actions.count + 1)
    bestScore[0] = 0
    bestCount[0] = 0
    for endExclusive in 1...actions.count {
        for start in 0..<endExclusive {
            guard bestScore[start].isFinite,
                  let candidate = candidates[start][endExclusive - 1]
            else { continue }
            let score = bestScore[start] + candidate.partitionScore
            let count = bestCount[start] + 1
            if score > bestScore[endExclusive] + 0.000_001
                || abs(score - bestScore[endExclusive]) <= 0.000_001
                    && count < bestCount[endExclusive] {
                bestScore[endExclusive] = score
                bestCount[endExclusive] = count
                previous[endExclusive] = start
                chosen[endExclusive] = candidate
            }
        }
    }

    var result: [InferredActionEpisode] = []
    var cursor = actions.count
    while cursor > 0, previous[cursor] >= 0 {
        if let episode = chosen[cursor] { result.append(episode) }
        cursor = previous[cursor]
    }
    return result.reversed()
}

private func actionEpisodeCandidate(
    actions: [DirectedAction],
    evidence: [ActionEpisodeEvidence],
    range: ClosedRange<Int>,
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    canvas: CGRect,
    transitionTimes: [Double],
    transitionCausalActionIDs: Set<Int>,
    broadResponseEvidence: [Int: ActionBroadResponseEvidence]
) -> InferredActionEpisode? {
    let indices = Array(range)
    let episodeActions = indices.map { actions[$0] }
    guard let first = episodeActions.first, episodeActions.last != nil else { return nil }

    if indices.count > 1 {
        for index in indices.dropFirst() {
            let prior = actions[index - 1]
            let action = actions[index]
            let crossesTransition = transitionTimes.contains {
                $0 > prior.time && $0 <= action.time
            } && evidence[index].release == nil
            if crossesTransition { return nil }
        }
    }

    let anchorIntervals: [(source: Int, anchor: Int)] = indices.compactMap { index in
        guard let anchorID = evidence[index].reveal?.forwardAnchorActionID,
              let anchorIndex = actions.firstIndex(where: { $0.id == anchorID }),
              range.contains(anchorIndex),
              anchorIndex > index
        else { return nil }
        return (index, anchorIndex)
    }
    // A completed forward-grounded interval is an evidence-defined episode,
    // not merely a high-scoring pair inside a larger spatial cluster. Keep
    // unexplained neighbors as separate subject hypotheses; ShotSchedule may
    // still hold one pose across them when that is globally preferable.
    if !anchorIntervals.isEmpty,
       indices.contains(where: { index in
           !anchorIntervals.contains { $0.source <= index && $0.anchor >= index }
       }) {
        return nil
    }
    func coveredByAnchor(_ left: Int, _ right: Int) -> Bool {
        anchorIntervals.contains { $0.source <= left && $0.anchor >= right }
    }

    var groundedUnion = CGRect.null
    for index in indices {
        guard let bounds = evidence[index].groundedBounds, !bounds.isNull else { continue }
        if !groundedUnion.isNull,
           !spatiallyCohesive(bounds, with: groundedUnion, canvas: canvas) {
            return nil
        }
        groundedUnion = groundedUnion.union(bounds)
    }
    let bounds: CGRect
    if groundedUnion.isNull {
        bounds = indices.reduce(CGRect.null) {
            $0.union(evidence[$1].fallbackBounds)
        }
    } else {
        bounds = groundedUnion
    }
    guard !bounds.isNull else { return nil }
    let area = bounds.width * bounds.height / max(1, graph.size.width * graph.size.height)
    if indices.count > 1, area >= 0.45 { return nil }

    var score = -0.18 * Double(max(0, indices.count - 1))
    if indices.count > 1 {
        for index in indices.dropFirst() {
            let priorIndex = index - 1
            let prior = actions[priorIndex]
            let action = actions[index]
            let gap = action.time - prior.time
            let insideCompletedAnchor = coveredByAnchor(priorIndex, index)
            let priorBounds = evidence[priorIndex].groundedBounds
            let currentBounds = evidence[index].groundedBounds
            let revealOwnsPrior = evidence[index].reveal.map {
                spatiallyRelated(priorBounds, $0.bounds)
            } ?? false
            let releaseOwnsPrior = evidence[index].release.map {
                spatiallyRelated(priorBounds, $0.bounds)
            } ?? false

            if gap >= 9,
               !insideCompletedAnchor,
               !revealOwnsPrior,
               !releaseOwnsPrior {
                return nil
            }
            if revealOwnsPrior || releaseOwnsPrior {
                score += 1.8
            } else if let priorBounds, let currentBounds,
                      spatiallyCohesive(currentBounds, with: priorBounds, canvas: canvas),
                      gap < 9 {
                score += 0.75
            } else if insideCompletedAnchor {
                // An unresolved action between two independently grounded
                // endpoints is preserved as part of the episode without
                // inventing geometry for it.
                score += 0.08
            } else if priorBounds == nil || currentBounds == nil {
                // Weak adjacency remains a competing hypothesis, but the
                // complexity cost above makes separation win absent stronger
                // evidence elsewhere in the interval.
                score += 0.05
            }
        }
    }

    score += Double(anchorIntervals.count) * 4.0
    // Prefer compact explanations when two partitions carry otherwise equal
    // evidence, without making smallness itself a camera instruction.
    score -= Double(area) * 0.20

    var observationIDs = Set<Int>()
    var revealEnd: Double?
    var verifiedReleaseTime: Double?
    var unresolvedBroad = Set<Int>()
    var overviewEvidenceByAction: [Int: SubjectGraph.Subject.OverviewBlame.ActionEvidence] = [:]
    let allReveals = indices.flatMap { evidence[$0].reveals }
    for index in indices {
        let action = actions[index]
        // A localized cluster is an alternative explanation, not proof that
        // it covers an independently observed broad response. Do not let the
        // mere existence of one compact rectangle erase scene-extent negative
        // evidence; only a measured release currently closes that uncertainty.
        let localizedResponseWeight = evidence[index].reveals.reduce(0) {
            $0 + $1.evidenceWeight
        }
        if let broad = broadResponseEvidence[action.id],
           let broadWeight = broad.strongestAlignedWeight,
           localizedResponseWeight < broadWeight,
           evidence[index].release == nil {
            unresolvedBroad.insert(action.id)
            overviewEvidenceByAction[action.id] = .init(
                actionID: action.id,
                broadObservationIDs: Set(broad.aligned.compactMap(\.observationID)),
                preexistingBroadObservationIDs: Set(
                    broad.preexisting.compactMap(\.observationID)
                ),
                broadResponseEvidence: broad.aligned.flatMap(\.responseEvidence).map { .init($0) },
                preexistingResponseEvidence: broad.preexisting
                    .flatMap(\.responseEvidence).map { .init($0) },
                crossBoundaryResponseEvidence: broad.crossBoundary
                    .flatMap(\.responseEvidence).map { .init($0) },
                broadWeight: broadWeight,
                localizedObservationIDs: Set(
                    evidence[index].reveals.flatMap(\.observationIDs)
                ),
                localizedWeight: localizedResponseWeight,
                causalBasis: graph.actionResponseSlices.isEmpty
                    ? "broad-onset-within-action-clock-window"
                    : "exclusive-action-response-slice",
                reason: "localized-weight-below-action-aligned-broad-weight-without-verified-release"
            )
        }
        for reveal in evidence[index].reveals {
            observationIDs.formUnion(reveal.observationIDs)
        }
        if let reveal = evidence[index].reveal {
            revealEnd = max(revealEnd ?? 0, reveal.sourceEnd)
        }
        if let release = evidence[index].release {
            observationIDs.formUnion(release.observationIDs)
            revealEnd = max(revealEnd ?? 0, release.sourceEnd)
            verifiedReleaseTime = release.verifiedReleaseTime
            unresolvedBroad.removeAll()
            overviewEvidenceByAction.removeAll()
        }
    }
    let framingEligibleAt: Double?
    if episodeActions.count > 1,
       transitionCausalActionIDs.contains(first.id),
       let next = episodeActions.dropFirst().first {
        framingEligibleAt = [
            composition.pointerTrip(forActionID: next.id)?.start,
            NativeComposition.semanticVisibilityStart(for: next),
            next.time
        ].compactMap { $0 }.min()
    } else {
        framingEligibleAt = nil
    }

    let responseObservationIDs = Set(allReveals.flatMap(\.observationIDs))
    let primaryObservationIDs = Set(indices.compactMap { evidence[$0].reveal }
        .flatMap(\.observationIDs))
    let factualUnion = indices.reduce(CGRect.null) { partial, index in
        guard let direct = evidence[index].directBounds else { return partial }
        return partial.union(direct)
    }
    var rawFraming: [(bounds: CGRect, observationIDs: Set<Int>)] = [
        (bounds, primaryObservationIDs)
    ]
    if !factualUnion.isNull {
        rawFraming.append((factualUnion, []))
    }
    for reveal in allReveals {
        rawFraming.append((
            factualUnion.isNull ? reveal.bounds : factualUnion.union(reveal.bounds),
            reveal.observationIDs
        ))
    }
    if !allReveals.isEmpty {
        let allResponseBounds = allReveals.reduce(CGRect.null) {
            $0.union($1.bounds)
        }
        rawFraming.append((
            factualUnion.isNull ? allResponseBounds : factualUnion.union(allResponseBounds),
            responseObservationIDs
        ))
    }
    var framingHypotheses: [SubjectGraph.Subject.FramingHypothesis] = []
    for proposal in rawFraming where !proposal.bounds.isNull {
        let coverage = responseObservationIDs.isEmpty ? 1 : Double(
            proposal.observationIDs.intersection(responseObservationIDs).count
        ) / Double(responseObservationIDs.count)
        if let existing = framingHypotheses.firstIndex(where: {
            rectApproximatelyEqual($0.bounds, proposal.bounds)
        }) {
            if coverage > framingHypotheses[existing].evidenceCoverage {
                framingHypotheses[existing] = .init(
                    id: framingHypotheses[existing].id,
                    bounds: proposal.bounds,
                    observationIDs: proposal.observationIDs,
                    evidenceCoverage: coverage
                )
            }
            continue
        }
        framingHypotheses.append(.init(
            id: framingHypotheses.count,
            bounds: proposal.bounds,
            observationIDs: proposal.observationIDs,
            evidenceCoverage: coverage
        ))
    }
    return InferredActionEpisode(
        actions: episodeActions,
        bounds: bounds,
        observationIDs: observationIDs,
        revealEnd: revealEnd,
        verifiedReleaseTime: verifiedReleaseTime,
        framingEligibleAt: framingEligibleAt,
        requiresOverview: !unresolvedBroad.isEmpty,
        overviewBlame: unresolvedBroad.isEmpty ? nil : .init(actions:
            unresolvedBroad.sorted().compactMap { overviewEvidenceByAction[$0] }
        ),
        partitionScore: indices.count == 1 ? 0 : score,
        framingHypotheses: framingHypotheses
    )
}

private func rectApproximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
    abs(left.minX - right.minX) < 0.5
        && abs(left.minY - right.minY) < 0.5
        && abs(left.width - right.width) < 0.5
        && abs(left.height - right.height) < 0.5
}

/// A viewport-spanning bounding box is not itself proof of scene-scale
/// change. Require the changed pixels to occupy a meaningful fraction of that
/// extent so sparse labels, chrome fragments, and periodic counters cannot be
/// promoted into an orientation boundary merely because their union is wide.
private func isSpatiallySubstantialSceneResponse(
    _ observation: VisualMotionObservation
) -> Bool {
    let bounds = observation.normalizedBounds
    let area = Double(max(0, bounds.width * bounds.height))
    guard area >= 0.45,
          bounds.width >= 0.90 || bounds.height >= 0.90
    else { return false }
    let occupancy = observation.changedFraction / max(0.000_001, area)
    return occupancy >= 0.025
}

private func isSparseDistributedSceneExtent(
    _ observation: VisualMotionObservation
) -> Bool {
    let bounds = observation.normalizedBounds
    let area = Double(max(0, bounds.width * bounds.height))
    let duration = max(0, observation.time - observation.startTime)
    guard duration >= 1.0 / 30.0,
          area >= 0.45,
          bounds.width >= 0.90 || bounds.height >= 0.90
    else { return false }
    return observation.changedFraction / max(0.000_001, area) < 0.025
}

/// Promotes only sustained, scene-scale, action-attributed change to an
/// orientation boundary. Sparse single-frame detector boxes and motion that
/// began before the action cannot acquire this authority.
private func sustainedActionAlignedSceneTransitions(
    graph: ProductionPlanGraph,
    actions: [DirectedAction]
) -> [InferredSceneTransitionEvidence] {
    let actionsByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    return graph.observations.enumerated().compactMap { entry in
        let observation = entry.element
        guard observation.kind == .appearance || observation.kind == .transformation,
              !observation.normalizedBounds.isNull
        else { return nil }
        let duration = max(0, observation.time - observation.startTime)
        guard duration >= 1.0 / 30.0,
              isSpatiallySubstantialSceneResponse(observation)
        else { return nil }
        let attribution = graph.attributions
            .filter {
                $0.observationID == entry.offset
                    && $0.actionID != nil
                    && $0.cost < 1.35
            }
            .min { $0.cost < $1.cost }
        guard let actionID = attribution?.actionID,
              let action = actionsByID[actionID],
              observation.startTime >= action.time - (1.0 / 30.0),
              observation.startTime <= action.time + 1.25
        else { return nil }
        return InferredSceneTransitionEvidence(
            observationID: entry.offset,
            sourceTime: max(action.time, observation.startTime),
            causalActionID: actionID
        )
    }
}

/// Broad action-aligned change is useful negative framing evidence even when
/// it is not a readable subject. If no localized reveal is recovered for the
/// same subject, cropping into its controls would hide an unresolved part of
/// the observed result. The SubjectGraph carries that uncertainty forward so
/// the global scheduler can abstain rather than guessing a response center.
private func broadUnresolvedResponseActions(
    graph: ProductionPlanGraph,
    actions: [DirectedAction]
) -> [Int: ActionBroadResponseEvidence] {
    if !graph.actionResponseSlices.isEmpty {
        var sliced: [Int: ActionBroadResponseEvidence] = [:]
        for slice in graph.actionResponseSlices {
            let aligned = broadResponseCandidates(slice.exclusiveEvidence)
            let preexisting = broadResponseCandidates(slice.preexistingEvidence)
            let crossBoundary = broadResponseCandidates(slice.crossBoundaryEvidence)
            guard !aligned.isEmpty || !preexisting.isEmpty || !crossBoundary.isEmpty else {
                continue
            }
            sliced[slice.actionID] = ActionBroadResponseEvidence(
                aligned: aligned,
                preexisting: preexisting,
                crossBoundary: crossBoundary
            )
        }
        return sliced
    }

    let broadResponses: [BroadResponseCandidate] = graph.observations.enumerated()
        .compactMap { entry -> BroadResponseCandidate? in
        let observation = entry.element
        guard observation.kind == .appearance || observation.kind == .transformation,
              !observation.normalizedBounds.isNull
        else { return nil }
        // Response extent is defined in source-window coordinates. Measuring
        // against the composed canvas would make the same full-window change
        // appear smaller merely because a wallpaper margin is wider.
        let area = observation.normalizedBounds.width * observation.normalizedBounds.height
        let duration = max(0, observation.time - observation.startTime)
        // A single sampled frame with a wide bounding box is not enough to
        // assert that the meaningful response occupies the whole scene. It
        // remains available as raw diagnostics, but cannot veto a factual
        // subject's readable framing without temporal support.
        // Sparse distributed change is insufficient to assert a scene
        // transition, but it is still valid negative framing evidence. Until
        // a localized action-aligned reveal resolves it, cropping would hide
        // an observed part of the response (for example, a delayed remote
        // notice outside the clicked controls).
        guard area >= 0.70, duration >= 1.0 / 30.0 else { return nil }
        return BroadResponseCandidate(
            observationID: entry.offset,
            responseEvidence: [],
            start: min(observation.startTime, observation.time),
            end: max(observation.startTime, observation.time),
            weight: max(0, observation.changedFraction)
                * max(0.25, observation.magnitude)
        )
    }
    var result: [Int: ActionBroadResponseEvidence] = [:]
    for action in actions {
        let aligned = broadResponses.filter { response in
            // A response already underway before this action is context from
            // an earlier cause, not negative framing evidence produced by the
            // current action. One analysis frame is the clock-uncertainty
            // boundary used elsewhere in the graph; beyond it we abstain from
            // the causal claim even when the intervals overlap.
            response.start >= action.time - (1.0 / 30.0)
                && response.start <= action.time + 1.25
        }
        let preexisting = broadResponses.filter { response in
            response.start < action.time - (1.0 / 30.0)
                && response.end >= action.time - (1.0 / 30.0)
        }
        guard !aligned.isEmpty || !preexisting.isEmpty else { continue }
        result[action.id] = ActionBroadResponseEvidence(
            aligned: aligned,
            preexisting: preexisting,
            crossBoundary: []
        )
    }
    return result
}

private func broadResponseCandidates(
    _ evidence: [ActionResponseSlice.Evidence]
) -> [BroadResponseCandidate] {
    let eligible = evidence.filter {
        $0.kind == .appearance || $0.kind == .transformation
    }.sorted {
        if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
        if $0.endTime != $1.endTime { return $0.endTime < $1.endTime }
        return $0.id < $1.id
    }
    guard !eligible.isEmpty else { return [] }

    // Reconstruct response fields only inside the already-exclusive causal
    // slice. Overlapping analyzer windows and simultaneous disconnected
    // components describe one visual response; a temporal gap ends the field.
    // This recovers distributed page/table changes without creating any
    // clip-global object, identity, or ownership track.
    var groups: [[ActionResponseSlice.Evidence]] = []
    var groupEnd = -Double.infinity
    for item in eligible {
        if groups.isEmpty || item.startTime > groupEnd + (1.0 / 30.0) {
            groups.append([item])
            groupEnd = item.endTime
        } else {
            groups[groups.count - 1].append(item)
            groupEnd = max(groupEnd, item.endTime)
        }
    }
    return groups.compactMap { group in
        guard let first = group.first else { return nil }
        let bounds = group.dropFirst().reduce(first.normalizedBounds) {
            $0.union($1.normalizedBounds)
        }.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let start = group.map(\.startTime).min() ?? first.startTime
        let end = group.map(\.endTime).max() ?? first.endTime
        let area = bounds.width * bounds.height
        let duration = max(0, end - start)
        guard !bounds.isNull, area >= 0.70, duration >= 1.0 / 30.0 else {
            return nil
        }
        let sampleWindows = Set(group.map {
            "\(Int(($0.startTime * 1_000).rounded())):\(Int(($0.endTime * 1_000).rounded()))"
        })
        let changed = min(
            1,
            group.reduce(0) { $0 + max(0, $1.changedFraction) }
                / Double(max(1, sampleWindows.count))
        )
        let confidenceWeight = group.reduce(0) {
            $0 + max(0.000_001, $1.changedFraction)
        }
        let confidence = group.reduce(0) {
            $0 + $1.confidence * max(0.000_001, $1.changedFraction)
        } / max(0.000_001, confidenceWeight)
        return BroadResponseCandidate(
            observationID: nil,
            responseEvidence: group,
            start: start,
            end: end,
            weight: changed * max(0.25, confidence)
        )
    }
}

private func foregroundFramingEntry(
    lifecycle: ProductionPlanGraph.SurfaceLifecycle,
    actions: [DirectedAction],
    composition: NativeComposition,
    sourceDuration: Double
) -> Double {
    let bounds = lifecycle.bounds
    let ordered = actions.sorted(by: { $0.time < $1.time })
    let birthTrigger = ordered
        .filter {
            $0.time >= lifecycle.gainedAt - 0.35
                && $0.time <= lifecycle.gainedAt + (1.0 / 30.0)
        }
        .max { $0.time < $1.time }
    if let birthTrigger {
        let triggerBounds = actionBounds(
            birthTrigger,
            canvas: CGRect(origin: .zero, size: composition.size)
        )
        if spatiallyRelated(triggerBounds, bounds) {
            // Offline planning may establish one compact region before the
            // click when the trigger and its verified response occupy that
            // same region. This shows cause and effect in one continuous shot.
            return birthTrigger.time
        }
    }
    var factualEntries: [Double] = []
    for action in ordered where action.id != birthTrigger?.id {
        if let trip = composition.pointerTrip(forActionID: action.id),
           trip.end >= lifecycle.gainedAt,
           bounds.contains(trip.to),
           let fraction = segmentEntryFraction(from: trip.from, to: trip.to, rect: bounds) {
            factualEntries.append(max(
                lifecycle.gainedAt,
                trip.start + (trip.end - trip.start) * fraction
            ))
            continue
        }
        if let semantic = action.semanticBounds,
           bounds.intersects(semantic) {
            factualEntries.append(max(
                lifecycle.gainedAt,
                NativeComposition.semanticVisibilityStart(for: action) ?? action.time
            ))
            continue
        }
        if let point = action.point,
           bounds.contains(point),
           action.time >= lifecycle.gainedAt {
            factualEntries.append(action.time)
        }
    }
    guard let firstEntry = factualEntries.min() else {
        // A verified response with no later cursor entry (for example, a
        // timed notice) is still a readable editorial subject. It may frame
        // only after its measured birth, never in anticipation of a remote
        // trigger.
        return birthTrigger == nil
            ? (lifecycle.releasedAt ?? sourceDuration)
            : lifecycle.gainedAt
    }
    // A surface that owns several interactions is a workflow destination:
    // keep the establishing view until the cursor actually enters. A short
    // transient surface with a verified later selection may frame from its
    // measured birth and hold, avoiding a zoom-in/out reversal around the
    // selection click itself.
    if actions.count >= 3 { return firstEntry }
    return lifecycle.gainedAt
}

private func segmentEntryFraction(from: CGPoint, to: CGPoint, rect: CGRect) -> Double? {
    if rect.contains(from) { return 0 }
    let dx = to.x - from.x
    let dy = to.y - from.y
    var lower: CGFloat = 0
    var upper: CGFloat = 1
    for (p, q) in [
        (-dx, from.x - rect.minX),
        (dx, rect.maxX - from.x),
        (-dy, from.y - rect.minY),
        (dy, rect.maxY - from.y)
    ] {
        if abs(p) < 0.000_001 {
            if q < 0 { return nil }
            continue
        }
        let ratio = q / p
        if p < 0 { lower = max(lower, ratio) }
        else { upper = min(upper, ratio) }
        if lower > upper { return nil }
    }
    return Double(lower)
}

/// Retains transition-local, action-caused response geometry as competing
/// subject hypotheses. It deliberately does not claim object identity or
/// foreground ownership: observations are clustered only inside one causal
/// response window and remain alternatives until shot planning.
private func localizedRevealEvidence(
    graph: ProductionPlanGraph,
    actions: [DirectedAction],
    canvas: CGRect
) -> [Int: [LocalizedRevealEvidence]] {
    let actionByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    var observationsByAction: [Int: [(id: Int, observation: VisualMotionObservation)]] = [:]
    for (observationID, observation) in graph.observations.enumerated() {
        guard !graph.supportObservationIDs.contains(observationID),
              observation.kind == .appearance || observation.kind == .transformation,
              observation.polarity != .vanish
        else { continue }
        // Preserve every admissible causal attribution through subject fusion.
        // Batched click/type actions often share one observed response interval;
        // choosing the cheapest edge here is a greedy decision that can erase
        // the later action before a factual anchor has a chance to resolve the
        // episode spatially.
        let attributedActionIDs = Set(graph.attributions.compactMap { attribution -> Int? in
            guard attribution.observationID == observationID,
                  attribution.cost < 1.5,
                  let actionID = attribution.actionID,
                  let action = actionByID[actionID]
            else { return nil }
            return observation.startTime >= action.time - 0.05
                && observation.startTime <= action.time + 1.25
                ? action.id : nil
        })
        for actionID in attributedActionIDs {
            observationsByAction[actionID, default: []].append((observationID, observation))
        }
    }

    var result: [Int: [LocalizedRevealEvidence]] = [:]
    for (actionID, allEntries) in observationsByAction {
        // A detector-only focus observation is an optional competing
        // hypothesis; it must neither create foreground ownership nor erase
        // an independently measured structural response from the same frame.
        // Keep the response available as ordinary subject geometry. The
        // resulting run remains an unverified proposal (`isForegroundSupport`
        // is false), so only the global readability objective can choose it.
        // This preserves alternatives instead of making evidence acceptance
        // depend on whether another detector happened to emit alongside it.
        guard let action = actionByID[actionID]
        else { continue }
        // A change that occupies nearly a full scene axis and most of the
        // viewport is a response/context transition, not evidence for the
        // compact persistent surface containing the controls that caused it.
        // Preserve it in the production graph, but do not let it replace the
        // subject's factual geometry. This is based only on scene extent—not
        // UI role, application, or recording identity.
        // Optional attention may already contain this same visual response;
        // treating it as an independent anchor would be circular. Only
        // geometry carried by the Computer Use fact itself can ground the
        // response here.
        let factual = directActionBounds(action, canvas: canvas)
        let nextFactualAction = factual == nil ? actions.first(where: {
            $0.time > action.time && directActionBounds($0, canvas: canvas) != nil
        }) : nil
        let forwardAnchor = factual == nil ? nextFactualAnchor(
            after: action,
            actions: actions,
            observations: graph.observations,
            canvas: canvas
        ) : nil
        let crossesSceneBeforeNextFact = nextFactualAction.map { next in
            graph.observations.contains {
                $0.kind == .contextTransition
                    && $0.time > action.time
                    && $0.time <= next.time
            }
        } ?? false
        if factual == nil, crossesSceneBeforeNextFact { continue }
        let anchorBounds = factual ?? forwardAnchor?.bounds

        typealias MappedEntry = (
            id: Int, observation: VisualMotionObservation, bounds: CGRect
        )
        let entries: [MappedEntry] = allEntries.compactMap { entry in
            guard !isSparseDistributedSceneExtent(entry.observation),
                  SpatialMotion.isFramingEligible(entry.observation),
                  !isSpatiallySubstantialSceneResponse(entry.observation)
            else { return nil }
            // A context transition is a hard total-order boundary. Motion on
            // its far side belongs to the new scene, even when a permissive
            // response-delay prior also attributed it to the earlier action.
            guard !graph.observations.contains(where: {
                $0.kind == .contextTransition
                    && $0.time > action.time
                    && $0.time <= entry.observation.startTime
            }) else { return nil }
            let mapped = mapObservation(entry.observation, graph: graph).intersection(canvas)
            let area = mapped.width * mapped.height / max(1, canvas.width * canvas.height)
            guard !mapped.isNull, area >= 0.0015, area <= 0.35 else { return nil }
            return (entry.id, entry.observation, mapped)
        }.sorted { $0.id < $1.id }
        guard !entries.isEmpty else { continue }

        // Connected clustering is scoped to this one attributed transition;
        // it cannot bridge time gaps, build clip-global tracks, or acquire an
        // identity. Multiple disconnected responses deliberately survive as
        // separate hypotheses instead of being unioned into a page-sized box.
        var clusters: [[MappedEntry]] = []
        for entry in entries {
            let related = clusters.indices.filter { clusterIndex in
                let established = clusters[clusterIndex].reduce(CGRect.null) {
                    $0.union($1.bounds)
                }
                return spatiallyCohesive(entry.bounds, with: established, canvas: canvas)
            }
            guard let destination = related.first else {
                clusters.append([entry])
                continue
            }
            clusters[destination].append(entry)
            for index in related.dropFirst().reversed() {
                clusters[destination].append(contentsOf: clusters[index])
                clusters.remove(at: index)
            }
        }

        let hypotheses = clusters.compactMap { cluster -> LocalizedRevealEvidence? in
            let bounds = cluster.reduce(CGRect.null) { $0.union($1.bounds) }
            let area = bounds.width * bounds.height / max(1, canvas.width * canvas.height)
            guard !bounds.isNull, area >= 0.0015, area <= 0.35 else { return nil }
            let anchorRelated = anchorBounds.map { spatiallyRelated(bounds, $0) } ?? false
            // When an unresolved action has a nearer future factual target,
            // that target closes the admissible interpretation. Retaining a
            // spatially unrelated cluster would skip known ordered evidence
            // in favor of a convenient retrospective motion rectangle.
            if factual == nil, forwardAnchor != nil, !anchorRelated { return nil }
            let evidenceWeight = cluster.reduce(0.0) { partial, entry in
                partial + max(0, entry.observation.changedFraction)
                    * max(0.25, entry.observation.magnitude)
            }
            return LocalizedRevealEvidence(
                bounds: bounds,
                sourceEnd: min(
                    graph.sourceDuration,
                    max(
                        (cluster.map { $0.observation.time }.max() ?? action.time) + 2.4,
                        anchorRelated
                            ? (forwardAnchor.map { NativeComposition.holdEnd(for: $0.action) } ?? 0)
                            : 0
                    )
                ),
                observationIDs: Set(cluster.map(\.id)),
                forwardAnchorActionID: anchorRelated ? forwardAnchor?.action.id : nil,
                isAnchorRelated: anchorRelated,
                evidenceWeight: evidenceWeight
            )
        }.sorted { left, right in
            if left.isAnchorRelated != right.isAnchorRelated {
                return left.isAnchorRelated && !right.isAnchorRelated
            }
            if left.evidenceWeight != right.evidenceWeight {
                return left.evidenceWeight > right.evidenceWeight
            }
            return left.observationIDs.min() ?? Int.max
                < right.observationIDs.min() ?? Int.max
        }
        if !hypotheses.isEmpty { result[actionID] = hypotheses }
    }
    return result
}

private struct FactualInteractionAnchor {
    let action: DirectedAction
    let bounds: CGRect
}

/// Returns the first later action carrying factual geometry, provided no
/// observed scene transition intervenes. "First" comes from the total action
/// order: skipping a nearer resolved action in favor of a convenient remote
/// one would be retrospective target guessing.
private func nextFactualAnchor(
    after action: DirectedAction,
    actions: [DirectedAction],
    observations: [VisualMotionObservation],
    canvas: CGRect
) -> FactualInteractionAnchor? {
    guard let anchor = actions.first(where: {
        $0.time > action.time && directActionBounds($0, canvas: canvas) != nil
    }),
    !observations.contains(where: {
        $0.kind == .contextTransition
            && $0.time > action.time
            && $0.time <= anchor.time
    }),
    let bounds = directActionBounds(anchor, canvas: canvas)
    else { return nil }
    return FactualInteractionAnchor(action: anchor, bounds: bounds)
}

/// Uses a localized, action-attributed disappearance as backward-looking
/// evidence for the surface that existed immediately before the action. This
/// is an offline lifecycle fact, not a forward persistence guess: its measured
/// time is the subject's release boundary and it never extends ownership into
/// later frames.
private func localizedReleaseEvidence(
    graph: ProductionPlanGraph,
    actions: [DirectedAction],
    canvas: CGRect
) -> [Int: LocalizedReleaseEvidence] {
    let actionByID = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
    var observationsByAction: [Int: [(id: Int, observation: VisualMotionObservation)]] = [:]
    for (observationID, observation) in graph.observations.enumerated() {
        guard !graph.supportObservationIDs.contains(observationID),
              observation.kind == .appearance || observation.kind == .transformation,
              observation.polarity == .vanish,
              !isSparseDistributedSceneExtent(observation)
        else { continue }
        let attribution = graph.attributions
            .filter {
                $0.observationID == observationID
                    && $0.actionID != nil
                    && $0.cost < 1.35
            }
            .min { $0.cost < $1.cost }
        guard let actionID = attribution?.actionID,
              let action = actionByID[actionID],
              observation.startTime >= action.time - 0.05,
              observation.startTime <= action.time + 1.25
        else { continue }
        observationsByAction[actionID, default: []].append((observationID, observation))
    }

    var result: [Int: LocalizedReleaseEvidence] = [:]
    for (actionID, entries) in observationsByAction {
        guard let action = actionByID[actionID],
              let factual = actionBounds(action, canvas: canvas),
              entries.contains(where: { SpatialMotion.isFramingEligible($0.observation) })
        else { continue }
        let release = entries.reduce(CGRect.null) {
            $0.union(mapObservation($1.observation, graph: graph).intersection(canvas))
        }
        guard !release.isNull,
              spatiallyCohesive(release, with: factual, canvas: canvas)
        else { continue }
        // A structural region may disappear inside a foreground surface while
        // the surface itself remains established (for example, collapsing a
        // nested section in an open dialog). An unverified focus hypothesis is
        // intentionally too weak to create camera ownership, but a same-frame
        // `held` measurement is valid negative evidence against declaring the
        // enclosing surface released. This only vetoes an inverse lifecycle;
        // it cannot manufacture a subject or a shot.
        let releaseComparisonTimes = entries.map(\.observation.time)
        let enclosingFocusStillHeld = graph.observations.contains { observation in
            guard observation.kind == .focus,
                  observation.focusTransition == .held,
                  releaseComparisonTimes.contains(where: {
                      abs($0 - observation.time) <= 1.0 / 30.0 + 0.000_001
                  })
            else { return false }
            let focus = mapObservation(observation, graph: graph).intersection(canvas)
            guard !focus.isNull else { return false }
            let focusArea = focus.width * focus.height
            let releaseArea = release.width * release.height
            return focusArea >= releaseArea && spatiallyRelated(release, focus)
        }
        let area = release.width * release.height / max(1, canvas.width * canvas.height)
        guard area >= 0.015, area <= 0.55,
              actions.contains(where: { prior in
                  prior.time < action.time
                      && action.time - prior.time <= 20
                      && spatiallyRelated(actionBounds(prior, canvas: canvas), release)
              })
        else { continue }
        result[actionID] = LocalizedReleaseEvidence(
            bounds: release,
            sourceEnd: action.time,
            observationIDs: Set(entries.map(\.id)),
            verifiedReleaseTime: enclosingFocusStillHeld ? nil : action.time
        )
    }
    return result
}

private func spatiallyCohesive(
    _ candidate: CGRect,
    with established: CGRect,
    canvas: CGRect
) -> Bool {
    guard !candidate.isNull, !established.isNull else { return false }
    if candidate.intersects(established) { return true }
    let gapX = max(0, max(established.minX - candidate.maxX, candidate.minX - established.maxX))
    let gapY = max(0, max(established.minY - candidate.maxY, candidate.minY - established.maxY))
    let gap = hypot(gapX, gapY)
    // Scale with the composed canvas rather than pixels or a particular UI.
    // Nearby controls in one panel remain cohesive; cross-region navigation
    // targets form a new subject proposal.
    return gap <= hypot(canvas.width, canvas.height) * 0.12
}

private func actionBounds(_ action: DirectedAction, canvas: CGRect) -> CGRect? {
    directActionBounds(action, canvas: canvas)
        ?? action.attention?.bounds.intersection(canvas)
}

/// Geometry carried by the ordered Computer Use fact itself. This remains
/// separate from optional attention so localized response geometry can replace
/// an uncertain broad fallback without weakening factual visibility.
private func directActionBounds(
    _ action: DirectedAction,
    canvas: CGRect
) -> CGRect? {
    // The direct drag path remains the factual cursor constraint. A separately
    // verified stable AX container supplies the subject extent, preventing a
    // tiny thumb or track segment from standing in for the surface the user is
    // actually manipulating.
    if action.kind == "drag", let bounds = action.interactionContainerBounds {
        return bounds.intersection(canvas)
    }
    if let bounds = action.semanticBounds { return bounds.intersection(canvas) }
    if action.kind == "drag", let from = action.from, let to = action.to {
        return CGRect(
            x: min(from.x, to.x), y: min(from.y, to.y),
            width: max(1, abs(to.x - from.x)), height: max(1, abs(to.y - from.y))
        ).insetBy(dx: -30, dy: -30).intersection(canvas)
    }
    if let point = action.point {
        return CGRect(x: point.x - 30, y: point.y - 30, width: 60, height: 60)
            .intersection(canvas)
    }
    return nil
}

private func spatiallyRelated(_ left: CGRect?, _ right: CGRect) -> Bool {
    guard let left, !left.isNull, !right.isNull else { return false }
    if right.contains(CGPoint(x: left.midX, y: left.midY)) { return true }
    let intersection = left.intersection(right)
    guard !intersection.isNull else { return false }
    return intersection.width * intersection.height
        / max(1, min(left.width * left.height, right.width * right.height)) >= 0.08
}

private func spatiallyAdjacentAtBirth(
    _ left: CGRect?, _ right: CGRect, canvas: CGRect
) -> Bool {
    guard let left, !left.isNull, !right.isNull else { return false }
    let gapX = max(0, max(right.minX - left.maxX, left.minX - right.maxX))
    let gapY = max(0, max(right.minY - left.maxY, left.minY - right.maxY))
    // Popovers and menus are normally adjacent to the control that creates
    // them, not overlapping it. This relation is allowed only inside the
    // one-frame birth boundary above, so ordinary nearby controls cannot
    // acquire a long-lived foreground owner.
    return hypot(gapX, gapY) <= hypot(canvas.width, canvas.height) * 0.035
}

private func mapObservation(
    _ observation: VisualMotionObservation,
    graph: ProductionPlanGraph
) -> CGRect {
    CGRect(
        x: graph.contentRect.minX + observation.normalizedBounds.minX * graph.contentRect.width,
        y: graph.contentRect.maxY - observation.normalizedBounds.maxY * graph.contentRect.height,
        width: observation.normalizedBounds.width * graph.contentRect.width,
        height: observation.normalizedBounds.height * graph.contentRect.height
    )
}

private func responseScore(
    _ observation: VisualMotionObservation,
    graph: ProductionPlanGraph
) -> Double {
    let bounds = mapObservation(observation, graph: graph)
    let area = Double(bounds.width * bounds.height / max(1, graph.size.width * graph.size.height))
    return observation.changedFraction * 10 + observation.magnitude * 0.8 + min(0.65, area) * 2
}
