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
        public let id: Int
        public let kind: Kind
        public let bounds: CGRect
        public let sourceRange: ClosedRange<Double>
        public let actionIDs: [Int]
        public let observationIDs: Set<Int>
        public let confidence: Double

        public init(
            id: Int,
            kind: Kind,
            bounds: CGRect,
            sourceRange: ClosedRange<Double>,
            actionIDs: [Int],
            observationIDs: Set<Int> = [],
            confidence: Double
        ) {
            self.id = id
            self.kind = kind
            self.bounds = bounds
            self.sourceRange = sourceRange
            self.actionIDs = actionIDs
            self.observationIDs = observationIDs
            self.confidence = confidence
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
        let transitionTimes = transitionEntries.map(\.element.time)
        var nextSubjectID = 0
        var subjects: [Subject] = []
        var assigned = Set<Int>()

        // A measured focus lifecycle is the strongest persistent-surface fact.
        // Assign only spatially related actions; lifecycle timing alone must not
        // pull unrelated controls into the foreground surface.
        for lifecycle in graph.lifecycles {
            let lifecycleArea = lifecycle.bounds.width * lifecycle.bounds.height
                / max(1, graph.size.width * graph.size.height)
            guard lifecycleArea >= 0.008, lifecycleArea <= 0.75 else { continue }
            let actions = orderedActions.filter { action in
                guard !assigned.contains(action.id), lifecycle.contains(action.time) else { return false }
                return spatiallyRelated(actionBounds(action, canvas: canvas), lifecycle.bounds)
            }
            guard !actions.isEmpty else { continue }
            let mappedActionBounds = actions.compactMap { actionBounds($0, canvas: canvas) }
            let bounds = mappedActionBounds.reduce(lifecycle.bounds) { $0.union($1) }
                .insetBy(dx: -18, dy: -18).intersection(canvas)
            let end = lifecycle.releasedAt ?? actions.map { NativeComposition.holdEnd(for: $0) }.max()!
            subjects.append(Subject(
                id: nextSubjectID,
                kind: .surface,
                bounds: bounds,
                sourceRange: min(lifecycle.gainedAt, actions[0].time)...max(end, actions.last!.time),
                actionIDs: actions.map(\.id),
                observationIDs: Set([lifecycle.gainedObservationID, lifecycle.releasedObservationID].compactMap { $0 }),
                confidence: 0.96
            ))
            nextSubjectID += 1
            assigned.formUnion(actions.map(\.id))
        }

        // Remaining actions are grouped by a bounded union over time. This is
        // a subject proposal, not a shot boundary: the scheduler may still
        // decide the span is not worth emphasizing.
        var run: [DirectedAction] = []
        var runBounds = CGRect.null
        func flushRun() {
            guard !run.isEmpty else { return }
            let kind: Kind = run.count >= 2 ? .surface : .target
            let padded = runBounds.insetBy(dx: kind == .surface ? -18 : -24,
                                           dy: kind == .surface ? -18 : -24)
                .intersection(canvas)
            subjects.append(Subject(
                id: nextSubjectID,
                kind: kind,
                bounds: padded,
                sourceRange: run[0].time...NativeComposition.holdEnd(for: run.last!),
                actionIDs: run.map(\.id),
                confidence: kind == .surface ? 0.78 : 0.92
            ))
            nextSubjectID += 1
            run.removeAll(keepingCapacity: true)
            runBounds = .null
        }

        for action in orderedActions {
            if assigned.contains(action.id) {
                flushRun()
                continue
            }
            let bounds = actionBounds(action, canvas: canvas) ?? canvas
            if let previous = run.last {
                let crossesTransition = transitionTimes.contains {
                    $0 > previous.time && $0 <= action.time
                }
                let candidate = runBounds.union(bounds)
                let area = candidate.width * candidate.height
                    / max(1, graph.size.width * graph.size.height)
                if !crossesTransition, action.time - previous.time < 9, area < 0.45 {
                    run.append(action)
                    runBounds = candidate
                    continue
                }
                flushRun()
            }
            run = [action]
            runBounds = bounds
        }
        flushRun()


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

private func actionBounds(_ action: DirectedAction, canvas: CGRect) -> CGRect? {
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
    return action.attention?.bounds.intersection(canvas)
}

private func spatiallyRelated(_ left: CGRect?, _ right: CGRect) -> Bool {
    guard let left, !left.isNull, !right.isNull else { return false }
    if right.contains(CGPoint(x: left.midX, y: left.midY)) { return true }
    let intersection = left.intersection(right)
    guard !intersection.isNull else { return false }
    return intersection.width * intersection.height
        / max(1, min(left.width * left.height, right.width * right.height)) >= 0.08
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
