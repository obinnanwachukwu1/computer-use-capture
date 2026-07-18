import CoreGraphics
import Dispatch
import Foundation

public struct GlobalProductionPlan: Sendable {
    public struct SearchStep: Sendable {
        public let actionID: Int
        public let candidateCount: Int
        public let incomingPathCount: Int
        public let proposalCount: Int
        public let uniqueTrajectoryCount: Int
        public let feasibleTrajectoryCount: Int
        public let outputPathCount: Int
    }

    public struct Decision: Sendable {
        public let actionID: Int
        public let timingID: Int
        public let attentionID: Int
        public let activation: Double
        public let timingSource: String
        public let observationIDs: Set<Int>
        public let evidenceSources: [EvidenceSource]
        public let observationClass: PlannerObservationClass?
        public let arrivalPose: CameraState
        public let pose: CameraState
        public let cumulativeCost: Double
    }

    public let camera: CameraPlan
    public let decisions: [Decision]
    public let hypothesisCount: Int
    public let beamWidth: Int
    public let searchTrace: [SearchStep]

    public init(
        camera: CameraPlan,
        decisions: [Decision],
        hypothesisCount: Int,
        beamWidth: Int,
        searchTrace: [SearchStep]
    ) {
        self.camera = camera
        self.decisions = decisions
        self.hypothesisCount = hypothesisCount
        self.beamWidth = beamWidth
        self.searchTrace = searchTrace
    }
}

/// Clip-wide production solver.
///
/// Unlike V2, the solver has no precomputed shots or episode boundaries and no
/// forced return-to-base state. It ranks timing, causal/attention, and camera
/// alternatives together across the full action sequence. Rendering facts are
/// hard constraints; editorial taste is expressed only as additive cost.
public enum ProductionPlanner {
    public struct Policy: Sendable {
        public var beamWidth = 160
        public var maximumPosePool = 72
        public var minimumMoveDuration = 0.18
        /// Let a visual result become readable before the camera reacts to it.
        /// This is output-time editorial grammar, independent of tool latency.
        public var responseSettleHold = 0.26
        public var cursorInset: CGFloat = 28
        public var panWeight = 1.0
        public var zoomWeight = 2.0
        public var moveWeight = 0.24
        public var reversalWeight = 3.8
        public var churnWeight = 3.8
        public var attentionCoverageWeight = 7.0
        public var centerWeight = 4.5
        public var editorialScaleWeight = 6.0
        public var timingDiscontinuityWeight = 2.0

        public init() {}
        public static let `default` = Policy()
    }

    public static func plan(
        graph: ProductionPlanGraph,
        composition: NativeComposition,
        base: CameraState,
        policy: Policy = .default
    ) -> GlobalProductionPlan {
        let posePool = buildPosePool(
            graph: graph, composition: composition, base: base,
            maximumCount: policy.maximumPosePool
        )
        let candidatesByAction = graph.actions.map { node in
            actionCandidates(
                node: node, poses: posePool, graph: graph,
                composition: composition,
                policy: policy
            )
        }
        let hypothesisCount = candidatesByAction.reduce(0) { $0 + $1.count }
        guard !candidatesByAction.contains(where: { $0.isEmpty }) else {
            return GlobalProductionPlan(
                camera: CameraPlan(moves: [], diagnostics: CameraPlanDiagnostics(
                    plannerVersion: graph.evaluationCondition.plannerVersion, feasible: false,
                    failure: "one or more actions have no factual-visibility-feasible hypothesis"
                )),
                decisions: [], hypothesisCount: hypothesisCount, beamWidth: policy.beamWidth,
                searchTrace: []
            )
        }

        let requiredObservations = Set(graph.observations.indices.filter {
            graph.observations[$0].kind == .contextTransition
        })
        var beam = [Path(
            cost: 0, previousPose: base, pose: base,
            previousActivation: -.infinity, lastMoveEnd: 0,
            explainedObservations: [], decisions: [], moves: []
        )]
        let diagonal = max(1, hypot(graph.size.width, graph.size.height))
        var searchTrace: [GlobalProductionPlan.SearchStep] = []
        for (actionIndex, candidates) in candidatesByAction.enumerated() {
            let currentBeam = beam
            var proposals: [PathProposal] = []
            for path in currentBeam {
                proposals += propose(
                    path: path, candidates: candidates,
                    actionIndex: actionIndex, graph: graph,
                    composition: composition, diagonal: diagonal,
                    policy: policy
                )
            }
            var unique: [PathProposal] = []
            var seen = Set<String>()
            for proposal in proposals where seen.insert(proposal.feasibilityKey).inserted {
                unique.append(proposal)
            }
            let uniqueProposals = unique
            let feasibility = IndexedFeasibility(count: uniqueProposals.count)
            DispatchQueue.concurrentPerform(iterations: uniqueProposals.count) { index in
                let proposal = uniqueProposals[index]
                feasibility.set(trajectoryPreservesFactualVisibility(
                    action: graph.actions[actionIndex].action,
                    activation: proposal.activation,
                    incoming: proposal.incoming,
                    localMoves: proposal.localMoves,
                    composition: composition,
                    inset: policy.cursorInset
                ), at: index)
            }
            let feasibilityByKey = Dictionary(uniqueKeysWithValues: zip(
                uniqueProposals.map(\.feasibilityKey), feasibility.values()
            ))
            var expanded = proposals.compactMap {
                feasibilityByKey[$0.feasibilityKey] == true ? $0.path : nil
            }
            expanded.sort(by: pathPrecedes)
            beam = diverseBeam(
                expanded,
                width: policy.beamWidth,
                requiredObservations: requiredObservations
            )
            searchTrace.append(.init(
                actionID: graph.actions[actionIndex].action.id,
                candidateCount: candidates.count,
                incomingPathCount: currentBeam.count,
                proposalCount: proposals.count,
                uniqueTrajectoryCount: uniqueProposals.count,
                feasibleTrajectoryCount: feasibility.values().filter { $0 }.count,
                outputPathCount: beam.count
            ))
            if beam.isEmpty { break }
        }

        let completePaths = beam.filter {
            requiredObservations.isSubset(of: $0.explainedObservations)
        }
        guard let winner = completePaths.min(by: {
            let left = terminalCost($0, graph: graph)
            let right = terminalCost($1, graph: graph)
            if abs(left - right) > 0.000_000_1 { return left < right }
            return pathPrecedes($0, $1)
        }) else {
            return GlobalProductionPlan(
                camera: CameraPlan(moves: [], diagnostics: CameraPlanDiagnostics(
                    plannerVersion: graph.evaluationCondition.plannerVersion, feasible: false,
                    failure: searchTrace.last?.outputPathCount == 0
                        ? "global production search exhausted at action \(searchTrace.last!.actionID)"
                        : "no globally feasible production path covers every required context transition"
                )),
                decisions: [], hypothesisCount: hypothesisCount, beamWidth: policy.beamWidth,
                searchTrace: searchTrace
            )
        }
        return GlobalProductionPlan(
            camera: CameraPlan(
                moves: winner.moves,
                diagnostics: CameraPlanDiagnostics(
                    plannerVersion: graph.evaluationCondition.plannerVersion,
                    feasible: true
                )
            ),
            decisions: winner.decisions,
            hypothesisCount: hypothesisCount,
            beamWidth: policy.beamWidth,
            searchTrace: searchTrace
        )
    }
}

private struct ActionCandidate: Sendable {
    let action: DirectedAction
    let timing: ProductionPlanGraph.TimingHypothesis
    let attention: ProductionPlanGraph.AttentionHypothesis
    let arrivalPose: CameraState
    let responsePose: CameraState
    let responseTime: Double
    let boundaryRole: String?
    let cost: Double
}

private struct Path: Sendable {
    let cost: Double
    let previousPose: CameraState
    let pose: CameraState
    let previousActivation: Double
    let lastMoveEnd: Double
    let explainedObservations: Set<Int>
    let decisions: [GlobalProductionPlan.Decision]
    let moves: [CameraMove]
}

private struct MoveSchedule: Sendable {
    let feasible: Bool
    let moves: [CameraMove]
    let poses: [CameraState]
}

private struct PathProposal: Sendable {
    let feasibilityKey: String
    let path: Path
    let actionID: Int
    let activation: Double
    let incoming: CameraState
    let localMoves: [CameraMove]
}

private final class IndexedFeasibility: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Bool?]

    init(count: Int) {
        storage = Array(repeating: nil, count: count)
    }

    func set(_ value: Bool, at index: Int) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    func values() -> [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return storage.map { $0! }
    }
}

private final class FeasibilityTrace: @unchecked Sendable {
    static let shared = FeasibilityTrace()
    private let lock = NSLock()
    private var reported = Set<String>()

    func record(
        actionID: Int, label: String, outputTime: Double, sourceTime: Double,
        state: CameraState, adjusted: CameraState
    ) {
        guard ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_TRACE_FEASIBILITY"] == "1" else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = "\(actionID):\(label)"
        guard reported.insert(key).inserted else { return }
        let output = String(format: "%.3f", outputTime)
        let source = String(format: "%.3f", sourceTime)
        let scale = String(format: "%.3f", exp(state.logScale))
        let requiredScale = String(format: "%.3f", exp(adjusted.logScale))
        print(
            "native normal infeasible action=\(actionID) move=\(label) output=\(output) source=\(source)"
            + " camera=(\(Int(state.x)),\(Int(state.y)),\(scale))"
            + " required=(\(Int(adjusted.x)),\(Int(adjusted.y)),\(requiredScale))"
        )
    }
}

private func propose(
    path: Path,
    candidates: [ActionCandidate],
    actionIndex: Int,
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    diagonal: CGFloat,
    policy: ProductionPlanner.Policy
) -> [PathProposal] {
    var proposals: [PathProposal] = []
    proposals.reserveCapacity(candidates.count)
    for candidate in candidates {
        guard candidate.timing.activation >= path.previousActivation - 0.001 else { continue }
        var transitionVariants: [(
            arrival: CameraState, response: CameraState,
            establishBeforePointer: Bool
        )] = [(candidate.arrivalPose, candidate.responsePose, false)]
        if let trip = composition.pointerTrip(forActionID: candidate.action.id) {
            let travelBounds = CGRect(
                x: min(trip.from.x, trip.to.x), y: min(trip.from.y, trip.to.y),
                width: abs(trip.to.x - trip.from.x),
                height: abs(trip.to.y - trip.from.y)
            ).insetBy(dx: -48, dy: -48)
            let routePose = composition.cameraPose(containing: travelBounds, maximumScale: 1.10)
            let routeResponse = candidate.attention.observationIDs.isEmpty
                ? routePose : candidate.responsePose
            if !transitionVariants.contains(where: {
                poseEqual($0.arrival, routePose) && poseEqual($0.response, routeResponse)
            }) {
                transitionVariants.append((
                    routePose,
                    routeResponse,
                    true
                ))
            }
        }
        for transitionVariant in transitionVariants {
        let arrivalPose = transitionVariant.arrival
        let responsePose = transitionVariant.response
        let establishBeforePointer = transitionVariant.establishBeforePointer
        let arrivalSchedule = moveSchedule(
            action: candidate.action,
            activation: candidate.timing.activation,
            from: path.pose,
            to: arrivalPose,
            composition: composition,
            previousMoveEnd: path.lastMoveEnd,
            boundaryRole: candidate.boundaryRole,
            establishBeforePointer: establishBeforePointer,
            policy: policy
        )
        guard arrivalSchedule.feasible else { continue }
        let responseSchedule = responseMoveSchedule(
            actionID: candidate.action.id,
            responseTime: candidate.responseTime,
            from: arrivalPose,
            to: responsePose,
            composition: composition,
            previousMoveEnd: arrivalSchedule.moves.last?.end ?? path.lastMoveEnd,
            boundaryRole: candidate.boundaryRole,
            policy: policy
        )
        guard responseSchedule.feasible else { continue }

        let previousAction = actionIndex > 0 ? graph.actions[actionIndex - 1].action : nil
        if candidate.attention.observationIDs.isEmpty,
           let episode = candidate.action.episodeID,
           previousAction?.episodeID == episode,
           let firstNextPose = (arrivalSchedule.poses + responseSchedule.poses).first {
            let priorZoom = path.pose.logScale - path.previousPose.logScale
            let nextZoom = firstNextPose.logScale - path.pose.logScale
            // Within one interaction surface, semantic-only beats do not
            // justify undoing the camera move that established the surface.
            // A later visual response may redirect the shot; coordinates alone
            // may not manufacture a zoom pulse.
            if priorZoom * nextZoom < -0.000_1 { continue }
        }
        if let previousMove = path.moves.last,
           let nextMove = (arrivalSchedule.moves + responseSchedule.moves).first,
           nextMove.start - previousMove.end < 0.75 {
            let previousZoom = previousMove.to.logScale - previousMove.from.logScale
            let nextZoom = nextMove.to.logScale - nextMove.from.logScale
            // Two individually justified moves can still compose into a
            // useless pulse. Require a readable beat between opposite zoom
            // directions so the clip never zooms in merely to undo it at the
            // next action boundary.
            if previousZoom * nextZoom < -0.000_1 { continue }
        }

        var transitionCost = 0.0
        var priorPriorPose = path.previousPose
        var priorPose = path.pose
        for nextPose in arrivalSchedule.poses + responseSchedule.poses {
            transitionCost += edgeCost(
                previousPrevious: priorPriorPose,
                previous: priorPose,
                current: nextPose,
                diagonal: diagonal,
                moved: !poseEqual(priorPose, nextPose),
                policy: policy
            )
            priorPriorPose = priorPose
            priorPose = nextPose
        }
        let attributionReuse = attributionReuseCost(
            previous: path.decisions.last?.observationIDs ?? [],
            current: candidate.attention.observationIDs,
            previousBehavior: path.decisions.last.flatMap { decision in
                graph.actions[max(0, actionIndex - 1)].attention.first(where: {
                    $0.id == decision.attentionID
                })?.behavior
            },
            currentBehavior: candidate.attention.behavior
        )
        let timingGapCost: Double
        if let previous = path.decisions.last {
            let rawGap = candidate.timing.activation - previous.activation
            timingGapCost = rawGap < -0.001
                ? .infinity
                : max(0, 0.04 - rawGap) * policy.timingDiscontinuityWeight
        } else {
            timingGapCost = 0
        }
        guard timingGapCost.isFinite else { continue }
        let newlyExplained = candidate.attention.observationIDs.subtracting(path.explainedObservations)
        let explanationReward = newlyExplained.reduce(0.0) {
            $0 + observationExplanationValue($1, graph: graph)
        }
        let activationAttention = activationHypothesis(from: candidate.attention, action: candidate.action)
        let responseAttention = responseHypothesis(from: candidate.attention, size: graph.size)
        let poseOverrideCost = max(
            0,
            attentionPoseCost(attention: activationAttention, pose: arrivalPose, size: graph.size, condition: graph.evaluationCondition, policy: policy)
                - attentionPoseCost(attention: activationAttention, pose: candidate.arrivalPose, size: graph.size, condition: graph.evaluationCondition, policy: policy)
        ) + max(
            0,
            attentionPoseCost(attention: responseAttention, pose: responsePose, size: graph.size, condition: graph.evaluationCondition, policy: policy)
                - attentionPoseCost(attention: responseAttention, pose: candidate.responsePose, size: graph.size, condition: graph.evaluationCondition, policy: policy)
        )
        let cost = path.cost + candidate.cost + poseOverrideCost + transitionCost
            + attributionReuse + timingGapCost - explanationReward
        let decision = GlobalProductionPlan.Decision(
            actionID: candidate.action.id,
            timingID: candidate.timing.id,
            attentionID: candidate.attention.id,
            activation: candidate.timing.activation,
            timingSource: candidate.timing.source,
            observationIDs: candidate.attention.observationIDs,
            evidenceSources: candidate.attention.evidence.map(\.source).reduce(into: []) {
                if !$0.contains($1) { $0.append($1) }
            }.sorted { $0.rawValue < $1.rawValue },
            observationClass: candidate.attention.observationClass,
            arrivalPose: arrivalPose,
            pose: responsePose,
            cumulativeCost: cost
        )
        let newMoves = path.moves + arrivalSchedule.moves + responseSchedule.moves
        let localMoves = arrivalSchedule.moves + responseSchedule.moves
        let feasibilityKey = trajectoryKey(
            actionID: candidate.action.id,
            timingID: candidate.timing.id,
            incoming: path.pose,
            arrival: arrivalPose,
            response: responsePose
        )
        let lastMove = responseSchedule.moves.last ?? arrivalSchedule.moves.last
        let newPreviousPose: CameraState
        if !responseSchedule.moves.isEmpty { newPreviousPose = arrivalPose }
        else if arrivalSchedule.poses.count >= 2 { newPreviousPose = arrivalSchedule.poses[arrivalSchedule.poses.count - 2] }
        else if !arrivalSchedule.moves.isEmpty { newPreviousPose = path.pose }
        else { newPreviousPose = path.previousPose }
        proposals.append(PathProposal(
            feasibilityKey: feasibilityKey,
            path: Path(
                cost: cost,
                previousPose: newPreviousPose,
                pose: responsePose,
                previousActivation: candidate.timing.activation,
                lastMoveEnd: lastMove?.end ?? path.lastMoveEnd,
                explainedObservations: path.explainedObservations.union(candidate.attention.observationIDs),
                decisions: path.decisions + [decision],
                moves: newMoves
            ),
            actionID: candidate.action.id,
            activation: candidate.timing.activation,
            incoming: path.pose,
            localMoves: localMoves
        ))
        }
    }
    return proposals
}

private func buildPosePool(
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    base: CameraState,
    maximumCount: Int
) -> [CameraState] {
    struct PoseCandidate {
        let pose: CameraState
        let isOracleSupport: Bool
    }
    var candidates = [PoseCandidate(pose: base, isOracleSupport: false)]
    for node in graph.actions {
        for hypothesis in node.attention {
            guard let bounds = hypothesis.bounds, let behavior = hypothesis.behavior else { continue }
            let maximumScale: CGFloat = switch behavior {
            case .overview: 1
            case .point: 1.62
            case .region: 1.58
            case .wideResponse: 1.48
            }
            candidates.append(PoseCandidate(
                pose: composition.cameraPose(containing: bounds, maximumScale: maximumScale),
                isOracleSupport: hypothesis.observationClass == .oracleForegroundSupport
            ))
        }
    }
    candidates.sort {
        // Oracle evaluation is meaningless if a correct foreground pose is
        // generated and then removed by the broadest-first pool cap. Reserve
        // those alternatives in C/D. With no oracle observations this sort is
        // identical to the production ordering.
        if $0.isOracleSupport != $1.isOracleSupport { return $0.isOracleSupport }
        if abs($0.pose.logScale - $1.pose.logScale) > 0.000_001 {
            return $0.pose.logScale < $1.pose.logScale
        }
        if abs($0.pose.y - $1.pose.y) > 0.001 { return $0.pose.y < $1.pose.y }
        return $0.pose.x < $1.pose.x
    }
    var unique: [CameraState] = []
    for candidate in candidates where !unique.contains(where: { poseEqual($0, candidate.pose) }) {
        unique.append(candidate.pose)
        if unique.count >= maximumCount { break }
    }
    return unique
}

private func actionCandidates(
    node: ProductionPlanGraph.ActionNode,
    poses: [CameraState],
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    policy: ProductionPlanner.Policy
) -> [ActionCandidate] {
    let size = graph.size
    let condition = graph.evaluationCondition
    var result: [ActionCandidate] = []
    let timingByID = Dictionary(uniqueKeysWithValues: node.timings.map { ($0.id, $0) })
    for attention in node.attention {
        guard let timing = timingByID[attention.timingID] else { continue }
        let activationAttention = activationHypothesis(from: attention, action: node.action)
        let responseAttention = responseHypothesis(from: attention, size: size)
        let foregroundOwnershipPose = foregroundOwnershipPose(
            attention: attention,
            action: node.action,
            activation: timing.activation,
            graph: graph,
            composition: composition,
            policy: policy
        )
        let foregroundReleases = attention.evidence.contains {
            [.released, .invalidated, .reset].contains($0.focusTransition)
        }
        let rankedArrivalPoses: [(CameraState, Double)]
        if let foregroundOwnershipPose {
            rankedArrivalPoses = [(
                foregroundOwnershipPose,
                attentionPoseCost(
                    attention: activationAttention, pose: foregroundOwnershipPose,
                    size: size, condition: condition, policy: policy
                )
            )]
        } else {
            rankedArrivalPoses = poses.compactMap { pose -> (CameraState, Double)? in
                guard factualVisibilityFeasible(action: node.action, pose: pose, size: size, inset: policy.cursorInset) else { return nil }
                return (pose, attentionPoseCost(attention: activationAttention, pose: pose, size: size, condition: condition, policy: policy))
            }.sorted { $0.1 < $1.1 }
        }
        var arrivalPoses = Array(rankedArrivalPoses.prefix(5))
        if let broadest = rankedArrivalPoses.min(by: { $0.0.logScale < $1.0.logScale }),
           !arrivalPoses.contains(where: { poseEqual($0.0, broadest.0) }) {
            // The path solver must be able to hold an already established
            // broad shot. A cost-only top-K pose prefix otherwise makes
            // continuity impossible before the global objective can score it.
            arrivalPoses.append(broadest)
        }
        // An overview is an orientation contract, not a centering preference.
        // Without this feasibility boundary the clip-wide travel objective can
        // compromise at an intermediate zoom simply because the next action
        // happens nearby, leaving a newly navigated page without an
        // establishing view.
        let hasVisualResponse = attention.evidence.contains {
            ![.pointer, .visualPointer, .accessibility, .dragPath].contains($0.source)
        }
        let eligibleResponsePoses = responseAttention.behavior == .overview
            ? poses.filter { abs($0.logScale) <= 0.001 }
            : poses
        let rankedResponsePoses = eligibleResponsePoses.map { pose in
            (pose, attentionPoseCost(attention: responseAttention, pose: pose, size: size, condition: condition, policy: policy))
        }.sorted { $0.1 < $1.1 }
        var responsePoses = Array(rankedResponsePoses.prefix(5))
        if let broadest = rankedResponsePoses.min(by: { $0.0.logScale < $1.0.logScale }),
           !responsePoses.contains(where: { poseEqual($0.0, broadest.0) }) {
            responsePoses.append(broadest)
        }
        let responseTime = attention.evidence
            .filter { ![.pointer, .visualPointer, .accessibility, .dragPath].contains($0.source) }
            .map {
                let duration = $0.timeRange.upperBound - $0.timeRange.lowerBound
                return duration > 1.0
                    ? $0.timeRange.lowerBound + min(0.55, duration)
                    : $0.timeRange.upperBound
            }
            .max()
            ?? timing.responseOnset
            ?? (timing.activation + 0.28)
        let boundaryRole: String?
        if attention.evidence.contains(where: { $0.source == .contextTransition }) {
            boundaryRole = "scene-transition"
        } else if attention.evidence.contains(where: {
            [.released, .invalidated, .reset].contains($0.focusTransition)
        }) {
            boundaryRole = "focus-release"
        } else {
            boundaryRole = nil
        }
        let sceneContextReward = persistentSceneContextValue(
            attention,
            graph: graph
        )
        for arrival in arrivalPoses {
            // A foreground lifecycle is one framing contract, not a separate
            // click shot followed by a response shot. Likewise, factual-only
            // evidence has no event capable of authoring a response move.
            // In both cases the action must hold its arrival pose.
            let actionResponsePoses: [(CameraState, Double)] =
                (foregroundOwnershipPose != nil && !foregroundReleases) || !hasVisualResponse
                ? [(arrival.0, attentionPoseCost(
                    attention: responseAttention, pose: arrival.0,
                    size: size, condition: condition, policy: policy
                ))]
                : responsePoses
            for response in actionResponsePoses {
                let internalTravel = hypot(response.0.x - arrival.0.x, response.0.y - arrival.0.y) / max(1, hypot(size.width, size.height))
                let internalZoom = abs(response.0.logScale - arrival.0.logScale)
                let internalCost = poseEqual(arrival.0, response.0) ? 0
                    : Double(internalTravel) * policy.panWeight
                        + Double(internalZoom) * policy.zoomWeight + policy.moveWeight
                result.append(ActionCandidate(
                    action: node.action, timing: timing, attention: attention,
                    arrivalPose: arrival.0, responsePose: response.0,
                    responseTime: max(timing.activation + 0.08, responseTime),
                    boundaryRole: boundaryRole,
                    cost: timing.cost + attention.cost + arrival.1 + response.1 + internalCost
                        - sceneContextReward
                ))
            }
        }
    }
    let ordered = result.sorted {
        if abs($0.cost - $1.cost) > 0.000_001 { return $0.cost < $1.cost }
        if $0.timing.id != $1.timing.id { return $0.timing.id < $1.timing.id }
        if $0.attention.id != $1.attention.id { return $0.attention.id < $1.attention.id }
        if abs($0.arrivalPose.logScale - $1.arrivalPose.logScale) > 0.000_001 {
            return $0.arrivalPose.logScale < $1.arrivalPose.logScale
        }
        return $0.responsePose.logScale < $1.responsePose.logScale
    }
    if ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_TRACE_ACTION"]
        == String(node.action.id) {
        for group in Dictionary(grouping: ordered, by: { $0.attention.id }).values {
            guard let best = group.first else { continue }
            let sources = best.attention.evidence.map(\.source.rawValue).joined(separator: "+")
            let observationClass = best.attention.observationClass?.rawValue ?? "none"
            let cost = String(format: "%.4f", best.cost)
            let arrivalScale = String(format: "%.2f", exp(best.arrivalPose.logScale))
            let responseScale = String(format: "%.2f", exp(best.responsePose.logScale))
            print(
                "native candidate action=\(node.action.id) attention=\(best.attention.id)"
                + " class=\(observationClass) obs=\(best.attention.observationIDs.sorted())"
                + " evidence=\(sources) cost=\(cost)"
                + " arrival=(\(Int(best.arrivalPose.x)),\(Int(best.arrivalPose.y)),\(arrivalScale))"
                + " response=(\(Int(best.responsePose.x)),\(Int(best.responsePose.y)),\(responseScale))"
            )
        }
    }
    // Preserve interpretation diversity before the clip-wide beam. A global
    // cost prefix lets dozens of cheap pose variants for factual-only evidence
    // erase a structurally important response hypothesis before global search
    // can compare them. Keep the best pose realizations of every attention
    // interpretation, then use cost only to order the retained lattice.
    var diverse: [ActionCandidate] = []
    for group in Dictionary(grouping: ordered, by: { $0.attention.id }).values {
        diverse += group.prefix(4)
        if let broadHold = group.min(by: {
            let left = $0.arrivalPose.logScale + $0.responsePose.logScale
            let right = $1.arrivalPose.logScale + $1.responsePose.logScale
            return left < right
        }), !diverse.contains(where: {
            $0.timing.id == broadHold.timing.id
                && $0.attention.id == broadHold.attention.id
                && poseEqual($0.arrivalPose, broadHold.arrivalPose)
                && poseEqual($0.responsePose, broadHold.responsePose)
        }) {
            diverse.append(broadHold)
        }
    }
    return Array(diverse.sorted {
        if abs($0.cost - $1.cost) > 0.000_001 { return $0.cost < $1.cost }
        if $0.timing.id != $1.timing.id { return $0.timing.id < $1.timing.id }
        return $0.attention.id < $1.attention.id
    }.prefix(112))
}

/// Condition D evaluates a foreground-support lifecycle as a camera subject
/// spanning time, not as one more action-local rectangle. Every non-release
/// action owned by that lifecycle receives the same canonical pose. Factual
/// pointer/AX evidence remains a hard visibility constraint; if the canonical
/// subject pose cannot show the action, widen once to their union rather than
/// creating a second response move.
private func foregroundOwnershipPose(
    attention: ProductionPlanGraph.AttentionHypothesis,
    action: DirectedAction,
    activation: Double,
    graph: ProductionPlanGraph,
    composition: NativeComposition,
    policy: ProductionPlanner.Policy
) -> CameraState? {
    guard graph.evaluationCondition == .dOracleGated,
          attention.observationClass == .oracleForegroundSupport else { return nil }
    let owned = graph.lifecycles
        .filter { graph.supportObservationIDs.contains($0.gainedObservationID) }
        .filter { lifecycle in
            lifecycle.contains(activation)
                || attention.evidence.contains { evidence in
                    evidence.source == .visualFocus
                        && evidence.timeRange.overlaps(
                            lifecycle.gainedAt...(lifecycle.releasedAt ?? graph.sourceDuration)
                        )
                        && rectangleOverlap(evidence.bounds, lifecycle.bounds) >= 0.15
                }
        }
        .max { left, right in
            rectangleOverlap(attention.bounds ?? .null, left.bounds)
                < rectangleOverlap(attention.bounds ?? .null, right.bounds)
        }
    guard let owned else { return nil }

    let canonical = composition.cameraPose(containing: owned.bounds, maximumScale: 1.48)
    if factualVisibilityFeasible(
        action: action, pose: canonical, size: graph.size, inset: policy.cursorInset
    ) {
        return canonical
    }
    let factualBounds = attention.evidence
        .filter { [.pointer, .visualPointer, .accessibility, .dragPath].contains($0.source) }
        .map(\.bounds)
        .reduce(owned.bounds) { $0.union($1) }
    let widened = composition.cameraPose(containing: factualBounds, maximumScale: 1.48)
    return factualVisibilityFeasible(
        action: action, pose: widened, size: graph.size, inset: policy.cursorInset
    ) ? widened : nil
}

private func rectangleOverlap(_ left: CGRect, _ right: CGRect) -> Double {
    guard !left.isNull, !right.isNull else { return 0 }
    let intersection = left.intersection(right)
    guard !intersection.isNull else { return 0 }
    let intersectionArea = intersection.width * intersection.height
    return Double(intersectionArea / max(1, min(
        left.width * left.height,
        right.width * right.height
    )))
}

private func persistentSceneContextValue(
    _ attention: ProductionPlanGraph.AttentionHypothesis,
    graph: ProductionPlanGraph
) -> Double {
    let raw = attention.evidence.compactMap { evidence -> Double? in
        guard [.visualResponse, .visualFocus].contains(evidence.source) else { return nil }
        let duration = evidence.timeRange.upperBound - evidence.timeRange.lowerBound
        guard duration >= 0.75 else { return nil }
        // Persistent scene evidence is valuable even when it predates the
        // current action and therefore cannot claim causal credit. Confidence,
        // framing weight, and persistence keep tiny periodic deltas from
        // overpowering factual pointer evidence, while a viewport-sized live
        // response can justify holding a broad shot.
        let durationValue = 0.8 + min(2.0, duration * 0.35)
        return min(4.5, durationValue * evidence.framingWeight * (0.5 + evidence.persistence) * 1.1)
    }.max() ?? 0
    let evidenceRange = attention.evidence.map(\.timeRange).reduce(nil as ClosedRange<Double>?) { range, next in
        guard let range else { return next }
        return min(range.lowerBound, next.lowerBound)...max(range.upperBound, next.upperBound)
    }
    guard let evidenceRange, graph.editorialEvidenceIsOptional(timeRange: evidenceRange) else {
        return raw
    }
    switch attention.observationClass {
    case .oracleForegroundSupport:
        return min(graph.evaluationCondition == .dOracleGated ? 3.0 : 1.3, raw)
    case .foregroundEditorial:
        return min(graph.evaluationCondition == .dOracleGated ? 0.85 : 1.3, raw)
    case .motionEditorial:
        return min(graph.evaluationCondition == .dOracleGated ? 0.30 : 0.55, raw)
    case .requiredContext, nil:
        return min(0.55, raw)
    }
}

private func activationHypothesis(
    from hypothesis: ProductionPlanGraph.AttentionHypothesis,
    action: DirectedAction
) -> ProductionPlanGraph.AttentionHypothesis {
    let factual = hypothesis.evidence.filter {
        [.pointer, .visualPointer, .accessibility, .dragPath].contains($0.source)
    }
    let bounds = factual.isEmpty ? action.semanticBounds : factual.map(\.bounds).dropFirst().reduce(factual.first?.bounds ?? .null) { $0.union($1) }
    return .init(
        id: hypothesis.id,
        actionID: hypothesis.actionID,
        timingID: hypothesis.timingID,
        bounds: bounds?.isNull == false ? bounds : nil,
        behavior: factual.isEmpty ? nil : factualBehavior(for: action),
        evidence: factual,
        observationIDs: [],
        observationClass: nil,
        cost: 0
    )
}

private func responseHypothesis(
    from hypothesis: ProductionPlanGraph.AttentionHypothesis,
    size: CGSize
) -> ProductionPlanGraph.AttentionHypothesis {
    let visual = hypothesis.evidence.filter {
        ![.pointer, .visualPointer, .accessibility, .dragPath].contains($0.source)
    }
    let release = visual.contains {
        $0.source == .contextTransition
            || [.released, .invalidated, .reset].contains($0.focusTransition)
    }
    if release {
        return .init(
            id: hypothesis.id, actionID: hypothesis.actionID, timingID: hypothesis.timingID,
            bounds: CGRect(origin: .zero, size: size), behavior: .overview,
            evidence: visual, observationIDs: hypothesis.observationIDs,
            observationClass: hypothesis.observationClass, cost: 0
        )
    }
    guard !visual.isEmpty else { return hypothesis }
    let bounds = visual.map(\.bounds).dropFirst().reduce(visual[0].bounds) { $0.union($1) }
    return .init(
        id: hypothesis.id, actionID: hypothesis.actionID, timingID: hypothesis.timingID,
        bounds: bounds, behavior: hypothesis.behavior, evidence: visual,
        observationIDs: hypothesis.observationIDs,
        observationClass: hypothesis.observationClass, cost: 0
    )
}

private func factualBehavior(for action: DirectedAction) -> CameraBehavior {
    action.semanticBounds != nil || action.kind == "drag" ? .region : .point
}

private func attentionPoseCost(
    attention: ProductionPlanGraph.AttentionHypothesis,
    pose: CameraState,
    size: CGSize,
    condition: ProductionEvaluationCondition,
    policy: ProductionPlanner.Policy
) -> Double {
    guard let bounds = attention.bounds, let behavior = attention.behavior else {
        return exp(pose.logScale) > 1.01 ? 1.2 : 0
    }
    if behavior == .overview {
        return abs(Double(pose.logScale)) * 12
    }
    let projected = projectedRect(bounds, through: pose, size: size)
    let safe = CGRect(x: 36, y: 36, width: size.width - 72, height: size.height - 72)
    let intersection = projected.intersection(safe)
    let coverage = intersection.isNull ? 0 : Double(intersection.width * intersection.height / max(1, projected.width * projected.height))
    let projectedCenter = CGPoint(x: projected.midX, y: projected.midY)
    let center = CGPoint(x: size.width / 2, y: size.height * 0.54)
    let centerDistance = hypot(projectedCenter.x - center.x, projectedCenter.y - center.y) / max(1, hypot(size.width, size.height))
    let desiredScale: Double = switch behavior {
    case .point: 1.48
    case .region: 1.42
    case .wideResponse: 1.34
    case .overview: 1
    }
    let scaleDeviation = abs(Double(exp(pose.logScale)) - desiredScale)
    let framingPriority = condition == .dOracleGated
            && attention.observationClass == .oracleForegroundSupport ? 3.0 : 1.0
    return framingPriority * ((1 - coverage) * policy.attentionCoverageWeight
        + Double(centerDistance) * policy.centerWeight
        + scaleDeviation * policy.editorialScaleWeight)
}

private func factualVisibilityFeasible(
    action: DirectedAction,
    pose: CameraState,
    size: CGSize,
    inset: CGFloat
) -> Bool {
    let safe = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
    if action.rendersCursor {
        if let point = action.point, !safe.contains(projectPointThroughCamera(point, camera: pose, outputSize: size)) { return false }
        if let from = action.from, !safe.contains(projectPointThroughCamera(from, camera: pose, outputSize: size)) { return false }
        if let to = action.to, !safe.contains(projectPointThroughCamera(to, camera: pose, outputSize: size)) { return false }
    }
    if ["type_text", "set_value", "select_text", "press_key"].contains(action.kind),
       let bounds = action.semanticBounds {
        let projected = projectedRect(bounds, through: pose, size: size)
        if !safe.contains(projected) { return false }
    }
    return true
}

private func moveSchedule(
    action: DirectedAction,
    activation: Double,
    from: CameraState,
    to: CameraState,
    composition: NativeComposition,
    previousMoveEnd: Double,
    boundaryRole: String?,
    establishBeforePointer: Bool = false,
    policy: ProductionPlanner.Policy
) -> MoveSchedule {
    guard !poseEqual(from, to) else { return MoveSchedule(feasible: true, moves: [], poses: []) }
    let actionID = action.id
    let actionOut = composition.outputTime(atSourceTime: activation)
    let trip = composition.pointerTrip(forActionID: actionID)
    let transitionFrom = from
    let transitionFloor = previousMoveEnd
    let desiredStart: Double
    let desiredEnd: Double
    if let trip {
        let tripStart = composition.outputTime(atSourceTime: trip.start)
        let tripEnd = composition.outputTime(atSourceTime: trip.end)
        if establishBeforePointer {
            desiredEnd = tripStart
            desiredStart = max(0, desiredEnd - transitionDuration(
                from: from, to: to, size: composition.size, policy: policy
            ))
        } else {
            desiredStart = tripStart + max(0, tripEnd - tripStart) * 0.10
            desiredEnd = max(desiredStart + policy.minimumMoveDuration, min(actionOut + 0.10, tripEnd + 0.12))
        }
    } else if let semanticStart = NativeComposition.semanticVisibilityStart(for: action) {
        // A locationless input has no pointer trip to lead the camera. Finish
        // before the renderer-owned semantic visibility interval begins;
        // settling at activation would already violate the factual contract.
        desiredEnd = composition.outputTime(atSourceTime: semanticStart)
        desiredStart = max(0, desiredEnd - 0.72)
    } else {
        desiredStart = max(0, actionOut - 0.72)
        desiredEnd = max(desiredStart + policy.minimumMoveDuration, actionOut + 0.08)
    }
    if poseEqual(transitionFrom, to) {
        return MoveSchedule(feasible: true, moves: [], poses: [])
    }
    let tastefulDuration = transitionDuration(
        from: transitionFrom, to: to, size: composition.size, policy: policy
    )
    let start = max(transitionFloor, desiredStart, desiredEnd - tastefulDuration)
    // A nearby prior beat may consume a small part of the ideal window. Keep
    // a velocity ceiling rather than demanding the exact preferred duration;
    // this preserves global feasibility without admitting the 200-300 ms
    // long-distance snaps the ceiling is meant to prevent.
    let minimumTastefulDuration = max(policy.minimumMoveDuration, tastefulDuration * 0.80)
    guard desiredEnd - start >= minimumTastefulDuration - 0.000_001 else {
        return MoveSchedule(feasible: false, moves: [], poses: [])
    }
    let move = CameraMove(
        label: boundaryRole.map { "normal-\($0)-\(actionID)" } ?? "normal-action-\(actionID)",
        start: start, end: desiredEnd,
        from: transitionFrom, to: to
    )
    return MoveSchedule(feasible: true, moves: [move], poses: [to])
}

private func responseMoveSchedule(
    actionID: Int,
    responseTime: Double,
    from: CameraState,
    to: CameraState,
    composition: NativeComposition,
    previousMoveEnd: Double,
    boundaryRole: String?,
    policy: ProductionPlanner.Policy
) -> MoveSchedule {
    guard !poseEqual(from, to) else { return MoveSchedule(feasible: true, moves: [], poses: []) }
    let responseOut = composition.outputTime(atSourceTime: responseTime)
    let start = max(previousMoveEnd, responseOut + policy.responseSettleHold)
    let spatial = hypot(to.x - from.x, to.y - from.y) / max(1, hypot(composition.size.width, composition.size.height))
    let zoom = abs(to.logScale - from.logScale)
    let duration = min(0.72, max(policy.minimumMoveDuration, 0.26 + Double(spatial) * 0.45 + Double(zoom) * 0.35))
    let move = CameraMove(
        label: boundaryRole.map { "normal-\($0)-\(actionID)-response" }
            ?? "normal-action-\(actionID)-response",
        start: start, end: start + duration, from: from, to: to
    )
    return MoveSchedule(feasible: true, moves: [move], poses: [to])
}

private func pointIsSafelyVisible(
    _ point: CGPoint, through camera: CameraState, size: CGSize, inset: CGFloat
) -> Bool {
    let safe = CGRect(
        x: inset, y: inset,
        width: size.width - inset * 2, height: size.height - inset * 2
    )
    return safe.contains(projectPointThroughCamera(point, camera: camera, outputSize: size))
}

private func transitionDuration(
    from: CameraState, to: CameraState, size: CGSize,
    policy: ProductionPlanner.Policy
) -> Double {
    let spatial = hypot(to.x - from.x, to.y - from.y) / max(1, hypot(size.width, size.height))
    let zoom = abs(to.logScale - from.logScale)
    return min(0.72, max(
        policy.minimumMoveDuration,
        0.26 + Double(spatial) * 0.45 + Double(zoom) * 0.35
    ))
}

private func trajectoryPreservesFactualVisibility(
    action: DirectedAction,
    activation: Double,
    incoming: CameraState,
    localMoves: [CameraMove],
    composition: NativeComposition,
    inset: CGFloat
) -> Bool {
    let actionID = action.id
    let activationOut = composition.outputTime(atSourceTime: activation)
    let trip = composition.pointerTrip(forActionID: actionID)
    let factualStart = trip.map { composition.outputTime(atSourceTime: $0.start) }
        ?? NativeComposition.semanticVisibilityStart(for: action).map {
            composition.outputTime(atSourceTime: $0)
        }
        ?? max(0, activationOut - 0.32)
    // A camera edge can begin before the current pointer trip. It still has
    // to respect any earlier factual action that remains active during that
    // portion of the edge, so audit the entire proposed edge, not only the
    // current action's choreography window.
    let start = min(factualStart, localMoves.first?.start ?? factualStart)
    let end = max(activationOut + 0.34, localMoves.last?.end ?? activationOut)
    // The production renderer defaults to 60 fps with eight shutter samples.
    // Feasibility must use that 480 Hz temporal density; a 90 Hz probe can
    // step completely over a one-sample edge violation and leave the renderer
    // to repair a path the planner called feasible.
    let count = max(2, Int(ceil((end - start) * 480)) + 1)
    for index in 0..<count {
        let fraction = Double(index) / Double(max(1, count - 1))
        let outputTime = start + (end - start) * fraction
        let sourceTime = composition.sourceTime(atOutputTime: outputTime)
        let state = cameraState(at: outputTime, moves: localMoves, base: incoming)
        let adjusted = composition.enforcingFactualActionVisibility(
            state, at: sourceTime, inset: inset
        )
        // Match the renderer's correction threshold. The looser pose equality
        // used for editorial no-op decisions can hide a subpixel edge graze;
        // at render sample rate that still becomes a factual correction.
        if abs(state.x - adjusted.x) > 0.0001
            || abs(state.y - adjusted.y) > 0.0001
            || abs(state.logScale - adjusted.logScale) > 0.0001 {
            FeasibilityTrace.shared.record(
                actionID: action.id,
                label: localMoves.map {
                    "\($0.label)[\(Int($0.from.x)),\(Int($0.from.y)),\(String(format: "%.2f", exp($0.from.logScale)))->\(Int($0.to.x)),\(Int($0.to.y)),\(String(format: "%.2f", exp($0.to.logScale)))]"
                }.joined(separator: "+"),
                outputTime: outputTime,
                sourceTime: sourceTime, state: state, adjusted: adjusted
            )
            return false
        }
    }
    return true
}

private func trajectoryKey(
    actionID: Int,
    timingID: Int,
    incoming: CameraState,
    arrival: CameraState,
    response: CameraState
) -> String {
    func pose(_ value: CameraState) -> String {
        "\(Int(value.x.rounded())):\(Int(value.y.rounded())):\(Int((value.logScale * 1_000).rounded()))"
    }
    return "\(actionID):\(timingID):\(pose(incoming)):\(pose(arrival)):\(pose(response))"
}

private func edgeCost(
    previousPrevious: CameraState,
    previous: CameraState,
    current: CameraState,
    diagonal: CGFloat,
    moved: Bool,
    policy: ProductionPlanner.Policy
) -> Double {
    guard moved else { return 0 }
    let pan = hypot(current.x - previous.x, current.y - previous.y) / diagonal
    let zoom = abs(current.logScale - previous.logScale)
    var result = Double(pan) * policy.panWeight
        + Double(zoom) * policy.zoomWeight
        + policy.moveWeight
    let first = CGVector(dx: previous.x - previousPrevious.x, dy: previous.y - previousPrevious.y)
    let second = CGVector(dx: current.x - previous.x, dy: current.y - previous.y)
    let firstLength = hypot(first.dx, first.dy)
    let secondLength = hypot(second.dx, second.dy)
    if firstLength > 1, secondLength > 1 {
        let cosine = (first.dx * second.dx + first.dy * second.dy) / (firstLength * secondLength)
        result += Double(max(0, -cosine)) * policy.reversalWeight
    }
    let firstZoom = previous.logScale - previousPrevious.logScale
    let secondZoom = current.logScale - previous.logScale
    if firstZoom * secondZoom < -0.000_1 {
        result += Double(min(abs(firstZoom), abs(secondZoom))) * policy.churnWeight
    }
    return result
}

private func attributionReuseCost(
    previous: Set<Int>,
    current: Set<Int>,
    previousBehavior: CameraBehavior?,
    currentBehavior: CameraBehavior?
) -> Double {
    guard !previous.isDisjoint(with: current) else { return 0 }
    // Reusing a persistent foreground surface is continuity. Reusing an
    // ordinary response for two adjacent actions is double attribution.
    if previousBehavior == .wideResponse, currentBehavior == .wideResponse { return -0.22 }
    return 0.75
}

private func baseObservationExplanationValue(_ observation: VisualMotionObservation) -> Double {
    let area = Double(observation.normalizedBounds.width * observation.normalizedBounds.height)
    let duration = max(0, observation.time - observation.startTime)
    let persistenceGain = min(4.5, duration * 0.28)
    let structuralGain = min(
        2.6,
        observation.changedFraction * 10
            + area * 3
            + observation.magnitude * 0.25
    )
    switch observation.kind {
    case .contextTransition: return 3.2
    case .focus: return 2.2 + min(0.9, structuralGain * 0.35)
    case .appearance:
        return SpatialMotion.isFramingEligible(observation) ? 0.7 + structuralGain + persistenceGain : 0.15
    case .transformation:
        return SpatialMotion.isFramingEligible(observation) ? 0.55 + structuralGain + persistenceGain : 0.15
    case .translation: return 0.08
    }
}

private func observationExplanationValue(
    _ observationID: Int,
    graph: ProductionPlanGraph
) -> Double {
    let raw = baseObservationExplanationValue(graph.observations[observationID])
    guard graph.editorialEvidenceIsOptional(observationID: observationID) else { return raw }
    switch graph.observationClass(for: observationID) {
    case .requiredContext:
        return raw
    case .oracleForegroundSupport:
        return min(graph.evaluationCondition == .dOracleGated ? 3.1 : 1.4, raw)
    case .foregroundEditorial:
        return min(graph.evaluationCondition == .dOracleGated ? 0.85 : 1.4, raw)
    case .motionEditorial:
        return min(graph.evaluationCondition == .dOracleGated ? 0.30 : 0.55, raw)
    }
}

private func terminalCost(_ path: Path, graph: ProductionPlanGraph) -> Double {
    let unexplained = graph.observations.indices.filter { !path.explainedObservations.contains($0) }
    return path.cost + unexplained.reduce(0.0) {
        let observationClass = graph.observationClass(for: $1)
        guard !graph.editorialEvidenceIsOptional(observationID: $1)
                || observationClass == .requiredContext else {
            return $0
        }
        return $0 + observationExplanationValue($1, graph: graph)
    }
}

private func projectedRect(_ rect: CGRect, through pose: CameraState, size: CGSize) -> CGRect {
    let minimum = projectPointThroughCamera(CGPoint(x: rect.minX, y: rect.minY), camera: pose, outputSize: size)
    let maximum = projectPointThroughCamera(CGPoint(x: rect.maxX, y: rect.maxY), camera: pose, outputSize: size)
    return CGRect(
        x: min(minimum.x, maximum.x), y: min(minimum.y, maximum.y),
        width: abs(maximum.x - minimum.x), height: abs(maximum.y - minimum.y)
    )
}

enum RequiredObservationBeamPolicy {
    /// Returns one best-path index for every distinct hard-obligation
    /// coverage state. `paths` must already be in objective order.
    ///
    /// Required observations are terminal feasibility constraints, so a
    /// cost-only beam cannot be allowed to erase every path that has made
    /// progress on them. Reserving coverage states keeps the search global;
    /// it does not reward or reinterpret any visual observation.
    static func reservationIndices(
        coverages: [Set<Int>],
        required: Set<Int>,
        width: Int
    ) -> [Int] {
        guard width > 0, !coverages.isEmpty, !required.isEmpty else { return [] }
        var firstByCoverage: [Set<Int>: Int] = [:]
        for (index, coverage) in coverages.enumerated() {
            let requiredCoverage = coverage.intersection(required)
            firstByCoverage[requiredCoverage] = firstByCoverage[requiredCoverage] ?? index
        }
        return firstByCoverage.map { (coverage: $0.key, index: $0.value) }
            .sorted {
                if $0.coverage.count != $1.coverage.count {
                    return $0.coverage.count > $1.coverage.count
                }
                return $0.index < $1.index
            }
            .prefix(width)
            .map(\.index)
    }
}

private func diverseBeam(
    _ paths: [Path],
    width: Int,
    requiredObservations: Set<Int>
) -> [Path] {
    var retained: [Path] = []
    let reservationIndices = RequiredObservationBeamPolicy.reservationIndices(
        coverages: paths.map(\.explainedObservations),
        required: requiredObservations,
        width: width
    )
    let reserved = Set(reservationIndices)
    retained.append(contentsOf: reservationIndices.map { paths[$0] })
    var signatures = Set<String>()
    for path in retained {
        let coverage = path.explainedObservations.sorted().map(String.init).joined(separator: ",")
        signatures.insert("\(Int(path.pose.x / 24)):\(Int(path.pose.y / 24)):\(Int(path.pose.logScale * 20)):\(path.decisions.last?.timingID ?? -1):\(path.decisions.last?.attentionID ?? -1):\(coverage)")
    }
    for (index, path) in paths.enumerated() where !reserved.contains(index) {
        let coverage = path.explainedObservations.sorted().map(String.init).joined(separator: ",")
        let signature = "\(Int(path.pose.x / 24)):\(Int(path.pose.y / 24)):\(Int(path.pose.logScale * 20)):\(path.decisions.last?.timingID ?? -1):\(path.decisions.last?.attentionID ?? -1):\(coverage)"
        if signatures.insert(signature).inserted {
            retained.append(path)
            if retained.count >= width { break }
        }
    }
    retained.sort(by: pathPrecedes)
    return Array(retained.prefix(width))
}

private func pathPrecedes(_ left: Path, _ right: Path) -> Bool {
    if abs(left.cost - right.cost) > 0.000_000_1 { return left.cost < right.cost }
    if left.moves.count != right.moves.count { return left.moves.count < right.moves.count }
    let leftIDs = left.decisions.map(\.attentionID)
    let rightIDs = right.decisions.map(\.attentionID)
    return leftIDs.lexicographicallyPrecedes(rightIDs)
}

private func poseEqual(_ left: CameraState, _ right: CameraState) -> Bool {
    abs(left.x - right.x) <= 0.5
        && abs(left.y - right.y) <= 0.5
        && abs(left.logScale - right.logScale) <= 0.001
}
