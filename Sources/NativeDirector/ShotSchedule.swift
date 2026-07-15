import CoreGraphics
import Foundation

/// Editorial intent over time. A shot owns a persistent subject for a span;
/// camera moves are a compiled consequence rather than the planning unit.
public struct ShotSchedule: Sendable {
    public enum Intent: String, Sendable {
        case overview
        case frame
        case orient
        case pushIn
    }

    public struct Shot: Sendable {
        public let id: Int
        public let subjectID: Int?
        public let intent: Intent
        public let interval: ClosedRange<Double>
        public let pose: CameraState
        public let actionIDs: [Int]
        public let readabilityValue: Double

        public init(
            id: Int,
            subjectID: Int?,
            intent: Intent,
            interval: ClosedRange<Double>,
            pose: CameraState,
            actionIDs: [Int],
            readabilityValue: Double
        ) {
            self.id = id
            self.subjectID = subjectID
            self.intent = intent
            self.interval = interval
            self.pose = pose
            self.actionIDs = actionIDs
            self.readabilityValue = readabilityValue
        }
    }

    public let shots: [Shot]
    public let moves: [CameraMove]

    public init(shots: [Shot], moves: [CameraMove]) {
        self.shots = shots
        self.moves = moves
    }
}

public enum ShotSchedulePlanner {
    public struct Policy: Sendable {
        public var surfaceMaximumScale: CGFloat = 1.60
        public var targetMaximumScale: CGFloat = 1.90
        public var responseMaximumScale: CGFloat = 1.45
        public var minimumReadableScale: CGFloat = 1.15
        public var readabilityGainPerSecond = 1.60
        public var moveCost = 1.0
        public var scaleCost = 0.30
        public var orientationHold = 0.95
        public var responseReadingHold = 2.40
        public var responsePushDelay = 0.60
        public var minimumMoveDuration = 0.34
        public var maximumMoveDuration = 0.90

        public init() {}
        public static let `default` = Policy()
    }

    private enum Event {
        case subject(SubjectGraph.Subject)
        case transition(SubjectGraph.SceneTransition)

        var sourceTime: Double {
            switch self {
            case let .subject(subject): subject.sourceRange.lowerBound
            case let .transition(transition): transition.sourceTime
            }
        }
    }

    public static func plan(
        subjects: SubjectGraph,
        composition: NativeComposition,
        base: CameraState,
        policy: Policy = .default
    ) -> ShotSchedule {
        let actionsByID = Dictionary(uniqueKeysWithValues: composition.actions.map { ($0.id, $0) })
        let subjectsByID = Dictionary(uniqueKeysWithValues: subjects.subjects.map { ($0.id, $0) })
        var events = subjects.subjects
            .filter { $0.kind != .response && !$0.actionIDs.isEmpty }
            .map(Event.subject)
        events += subjects.transitions.map(Event.transition)
        events.sort {
            if $0.sourceTime != $1.sourceTime { return $0.sourceTime < $1.sourceTime }
            switch ($0, $1) {
            case (.transition, .subject): return true
            case (.subject, .transition): return false
            default: return false
            }
        }

        var shots: [ShotSchedule.Shot] = []
        var moves: [CameraMove] = []
        var currentPose = base
        var previousMoveEnd = 0.0
        var nextShotID = 0

        func appendMove(label: String, arriveBy: Double, to pose: CameraState) {
            guard !poseApproximatelyEqual(currentPose, pose) else { return }
            let duration = moveDuration(
                from: currentPose, to: pose, size: subjects.size, policy: policy
            )
            let end = max(previousMoveEnd + duration, arriveBy)
            let start = max(previousMoveEnd, end - duration)
            moves.append(CameraMove(
                label: label, start: start, end: end, from: currentPose, to: pose
            ))
            currentPose = pose
            previousMoveEnd = end
        }

        for (eventIndex, event) in events.enumerated() {
            let nextEventTime = events.indices.contains(eventIndex + 1)
                ? composition.outputTime(atSourceTime: events[eventIndex + 1].sourceTime)
                : composition.outputDuration
            switch event {
            case let .subject(subject):
                let actions = subject.actionIDs.compactMap { actionsByID[$0] }
                    .sorted { $0.time < $1.time }
                guard let first = actions.first, let last = actions.last else { continue }
                let start = composition.outputTime(atSourceTime: first.time)
                let end = max(start, composition.outputTime(
                    atSourceTime: NativeComposition.holdEnd(for: last)
                ))
                let maximumScale: CGFloat = subject.kind == .target
                    ? policy.targetMaximumScale : policy.surfaceMaximumScale
                let candidate = composition.cameraPose(
                    containing: subject.bounds, maximumScale: maximumScale
                )
                let scale = exp(candidate.logScale)
                let duration = max(0.8, end - start)
                let value = Double(scale - 1) * policy.readabilityGainPerSecond * duration
                let cost = policy.moveCost * 2 + Double(scale - 1) * policy.scaleCost
                let emphasize = scale >= policy.minimumReadableScale && value > cost
                let pose = emphasize ? candidate : base
                let intent: ShotSchedule.Intent = emphasize ? .frame : .overview
                let semanticDeadline = NativeComposition.semanticVisibilityStart(for: first)
                    .map { composition.outputTime(atSourceTime: $0) }
                // Returning to overview is an establishing action, not a
                // tracking correction. Complete it before a factual pointer
                // trip leaves the held subject so the trajectory has one
                // straight owner instead of a cursor track fighting a
                // simultaneous zoom-out.
                let overviewDeadline = poseApproximatelyEqual(pose, base)
                    ? composition.pointerTrip(forActionID: first.id).map {
                        composition.outputTime(atSourceTime: $0.start)
                    }
                    : nil
                let arrivalDeadline = semanticDeadline ?? overviewDeadline ?? (start + 0.08)
                appendMove(
                    label: "experimental-shot-\(subject.id)",
                    arriveBy: arrivalDeadline,
                    to: pose
                )
                shots.append(.init(
                    id: nextShotID,
                    subjectID: subject.id,
                    intent: intent,
                    interval: start...min(composition.outputDuration, max(start, end)),
                    pose: pose,
                    actionIDs: subject.actionIDs,
                    readabilityValue: value - cost
                ))
                nextShotID += 1

            case let .transition(transition):
                let transitionTime = composition.outputTime(atSourceTime: transition.sourceTime)
                appendMove(
                    label: "experimental-orient-\(transition.observationID)",
                    arriveBy: transitionTime,
                    to: base
                )
                let orientStart = max(transitionTime, previousMoveEnd)
                let orientEnd = min(
                    composition.outputDuration,
                    max(orientStart, orientStart + policy.orientationHold)
                )
                shots.append(.init(
                    id: nextShotID,
                    subjectID: nil,
                    intent: .orient,
                    interval: orientStart...orientEnd,
                    pose: base,
                    actionIDs: transition.causalActionID.map { [$0] } ?? [],
                    readabilityValue: 0
                ))
                nextShotID += 1

                guard let responseID = transition.responseSubjectID,
                      let response = subjectsByID[responseID]
                else { continue }
                let pose = composition.cameraPose(
                    containing: response.bounds,
                    maximumScale: policy.responseMaximumScale
                )
                guard exp(pose.logScale) >= policy.minimumReadableScale else { continue }
                let pushArrival = orientEnd + policy.responsePushDelay
                // A new factual subject owns the next beat. Do not schedule a
                // response close-up that would immediately collide with it.
                guard pushArrival + 0.20 < nextEventTime || eventIndex == events.count - 1 else { continue }
                appendMove(
                    label: "experimental-response-\(response.id)",
                    arriveBy: pushArrival,
                    to: pose
                )
                let responseStart = previousMoveEnd
                let responseEnd = min(
                    composition.outputDuration,
                    max(responseStart, responseStart + policy.responseReadingHold)
                )
                shots.append(.init(
                    id: nextShotID,
                    subjectID: response.id,
                    intent: .pushIn,
                    interval: responseStart...responseEnd,
                    pose: pose,
                    actionIDs: [],
                    readabilityValue: Double(exp(pose.logScale) - 1)
                        * policy.readabilityGainPerSecond * max(0, responseEnd - responseStart)
                ))
                nextShotID += 1
            }
        }

        return ShotSchedule(shots: shots, moves: moves)
    }
}

private func moveDuration(
    from: CameraState,
    to: CameraState,
    size: CGSize,
    policy: ShotSchedulePlanner.Policy
) -> Double {
    let spatial = hypot(to.x - from.x, to.y - from.y) / max(1, hypot(size.width, size.height))
    let zoom = abs(to.logScale - from.logScale)
    return min(policy.maximumMoveDuration, max(
        policy.minimumMoveDuration,
        0.26 + Double(spatial) * 0.50 + Double(zoom) * 0.45
    ))
}

private func poseApproximatelyEqual(_ left: CameraState, _ right: CameraState) -> Bool {
    abs(left.x - right.x) < 0.5
        && abs(left.y - right.y) < 0.5
        && abs(left.logScale - right.logScale) < 0.001
}
