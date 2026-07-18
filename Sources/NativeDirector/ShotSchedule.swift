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
    /// Clip-wide readability reward minus the costs of the trajectory edges
    /// that were actually emitted. This is a plan score, not a confidence.
    public let objectiveValue: Double

    public init(shots: [Shot], moves: [CameraMove], objectiveValue: Double = 0) {
        self.shots = shots
        self.moves = moves
        self.objectiveValue = objectiveValue
    }

    /// Semantic shot intervals may overlap. The latest-starting active shot is
    /// the current owner; ties resolve by stable shot ID. Render diagnostics,
    /// audits, and future editors must share this rule rather than independently
    /// guessing which subject owns the camera at a given time.
    public func selectedShot(at outputTime: Double) -> Shot? {
        shots.filter { $0.interval.contains(outputTime) }.max { left, right in
            if left.interval.lowerBound != right.interval.lowerBound {
                return left.interval.lowerBound < right.interval.lowerBound
            }
            return left.id < right.id
        }
    }
}

public enum ShotSchedulePlanner {
    public struct Policy: Sendable {
        public var surfaceMaximumScale: CGFloat = 1.60
        public var targetMaximumScale: CGFloat = 1.90
        public var responseMaximumScale: CGFloat = 1.45
        public var minimumReadableScale: CGFloat = 1.15
        public var readabilityGainPerSecond = 1.60
        /// A held shot that presents several factual interactions has more
        /// editorial value than an equally long decoration around one click.
        /// Waiting reduction can remove the pauses between those interactions,
        /// but it must not erase that ordered evidence. Credit a small bounded
        /// reading beat for each additional action while leaving the actual
        /// shot interval and camera speed unchanged.
        public var additionalActionReadabilitySeconds = 0.60
        public var maximumActionReadabilityCredit = 1.40
        public var moveCost = 1.0
        public var scaleCost = 2.0
        public var translationCost = 3.0
        public var orientationHold = 0.95
        public var responseReadingHold = 2.40
        public var responsePushDelay = 0.60
        public var responseMinimumVisibleFraction = 0.98
        public var minimumMoveDuration = 0.34
        public var maximumMoveDuration = 0.90
        /// The search deliberately retains locally unprofitable entries so a
        /// later hold or direct handoff can repay them at clip scope.
        public var searchBeamWidth = 160

        public init() {}
        public static let `default` = Policy()
    }

    private enum Event {
        case subject(SubjectGraph.Subject)
        case release(SubjectGraph.Subject)
        case transition(SubjectGraph.SceneTransition)

        var sourceTime: Double {
            switch self {
            case let .subject(subject): subject.sourceRange.lowerBound
            case let .release(subject):
                subject.verifiedReleaseTime ?? subject.sourceRange.upperBound
            case let .transition(transition): transition.sourceTime
            }
        }
    }

    fileprivate struct SearchState {
        var score = 0.0
        var shots: [ShotSchedule.Shot] = []
        var moves: [CameraMove] = []
        var currentPose: CameraState
        var currentSubjectID: Int?
        var previousMoveEnd = 0.0
        var nextShotID = 0

        @discardableResult
        mutating func move(
            label: String,
            arriveBy: Double,
            to pose: CameraState,
            size: CGSize,
            policy: Policy
        ) -> Double? {
            guard !poseApproximatelyEqual(currentPose, pose) else { return nil }
            let duration = moveDuration(
                from: currentPose, to: pose, size: size, policy: policy
            )
            let end = max(previousMoveEnd + duration, arriveBy)
            let start = max(previousMoveEnd, end - duration)
            let cost = trajectoryEdgeCost(
                from: currentPose, to: pose, size: size, policy: policy
            )
            moves.append(CameraMove(
                label: label, start: start, end: end, from: currentPose, to: pose
            ))
            currentPose = pose
            previousMoveEnd = end
            score -= cost
            return end
        }

        @discardableResult
        mutating func moveAfter(
            label: String,
            startAt: Double,
            to pose: CameraState,
            size: CGSize,
            policy: Policy
        ) -> Double? {
            guard !poseApproximatelyEqual(currentPose, pose) else { return nil }
            let duration = moveDuration(
                from: currentPose, to: pose, size: size, policy: policy
            )
            let start = max(previousMoveEnd, startAt)
            let end = start + duration
            let cost = trajectoryEdgeCost(
                from: currentPose, to: pose, size: size, policy: policy
            )
            moves.append(CameraMove(
                label: label, start: start, end: end, from: currentPose, to: pose
            ))
            currentPose = pose
            previousMoveEnd = end
            score -= cost
            return end
        }
    }

    public static func plan(
        subjects: SubjectGraph,
        composition: NativeComposition,
        base: CameraState,
        responseCoverageConstraints: [ActionResponseCoverageAudit.Constraint] = [],
        contentRect: CGRect? = nil,
        policy: Policy = .default
    ) -> ShotSchedule {
        let actionsByID = Dictionary(uniqueKeysWithValues: composition.actions.map { ($0.id, $0) })
        let subjectsByID = Dictionary(uniqueKeysWithValues: subjects.subjects.map { ($0.id, $0) })
        var events = subjects.subjects
            .filter { $0.kind != .response && !$0.actionIDs.isEmpty }
            .map(Event.subject)
        events += subjects.subjects
            .filter { $0.verifiedReleaseTime != nil && !$0.actionIDs.isEmpty }
            .map(Event.release)
        events += subjects.transitions.map(Event.transition)
        events.sort {
            if $0.sourceTime != $1.sourceTime { return $0.sourceTime < $1.sourceTime }
            switch ($0, $1) {
            case (.release, .subject): return true
            case (.subject, .release): return false
            case (.transition, .subject): return true
            case (.subject, .transition): return false
            default: return false
            }
        }

        var states = [SearchState(currentPose: base)]

        for (eventIndex, event) in events.enumerated() {
            let nextEventTime = events.indices.contains(eventIndex + 1)
                ? composition.outputTime(atSourceTime: events[eventIndex + 1].sourceTime)
                : composition.outputDuration
            switch event {
            case let .subject(subject):
                let actions = subject.actionIDs.compactMap { actionsByID[$0] }
                    .sorted { $0.time < $1.time }
                guard let first = actions.first, let last = actions.last else { continue }
                // The subject graph owns temporal extent. Reducing a measured
                // foreground lifecycle to the first/last action hold turns a
                // 10-second readable surface into a 550 ms click decoration
                // and makes the scheduler rationally reject the shot.
                let framingSourceStart = max(
                    subject.sourceRange.lowerBound,
                    subject.framingEligibleAt ?? min(subject.sourceRange.lowerBound, first.time)
                )
                let start = composition.outputTime(atSourceTime: framingSourceStart)
                let end = max(start, composition.outputTime(
                    atSourceTime: max(
                        subject.sourceRange.upperBound,
                        NativeComposition.holdEnd(for: last)
                    )
                ))
                let maximumScale: CGFloat = subject.kind == .target
                    ? policy.targetMaximumScale : policy.surfaceMaximumScale
                let responseBounds = responseCoverageBounds(
                    for: subject.actionIDs,
                    constraints: responseCoverageConstraints,
                    contentRect: contentRect
                )
                let unconstrainedTightCandidate = composition.cameraPose(
                    containing: subject.bounds, maximumScale: maximumScale
                )
                let tightCandidate = !responseBounds.isEmpty ?
                    zoomedOutPosePreservingCenter(
                        unconstrainedTightCandidate,
                        containing: responseBounds,
                        size: subjects.size,
                        minimumVisibleFraction: policy.responseMinimumVisibleFraction
                    ) : unconstrainedTightCandidate
                let duration = max(0.8, end - start)
                let actionReadabilityCredit = min(
                    policy.maximumActionReadabilityCredit,
                    Double(max(0, actions.count - 1))
                        * policy.additionalActionReadabilitySeconds
                )
                let editorialDuration = duration + actionReadabilityCredit
                let semanticDeadline = NativeComposition.semanticVisibilityStart(for: first)
                    .map { composition.outputTime(atSourceTime: $0) }
                let anticipatesMeasuredBirth = subject.isForegroundSupport
                    && subject.framingEligibleAt.map {
                        abs($0 - subject.sourceRange.lowerBound) < 0.001
                    } == true
                var expanded: [SearchState] = []
                for state in states {
                    let underlying = activeUnderlyingShot(
                        in: state.shots,
                        excluding: subject.id,
                        at: start,
                        base: base,
                        subjectsByID: subjectsByID,
                        composition: composition
                    )
                    let unconstrainedFallback = underlying?.pose ?? base
                    let fallback = !responseBounds.isEmpty ?
                        zoomedOutPosePreservingCenter(
                            unconstrainedFallback,
                            containing: responseBounds,
                            size: subjects.size,
                            minimumVisibleFraction: policy.responseMinimumVisibleFraction
                        ) : unconstrainedFallback
                    var options: [(pose: CameraState, emphasize: Bool)] = [(fallback, false)]

                    // Keep several feasible scales alive. A locally negative
                    // entry can become the best clip-wide path when later
                    // subjects share the pose or require only a direct handoff.
                    if !subject.requiresOverview,
                       exp(tightCandidate.logScale) >= policy.minimumReadableScale {
                        let parentAlreadyFrames = underlying.map {
                            comfortablyFrames(
                                subject.bounds,
                                through: $0.pose,
                                comparedTo: tightCandidate,
                                size: subjects.size,
                                minimumReadableScale: policy.minimumReadableScale
                            )
                        } == true
                        if !parentAlreadyFrames {
                            for proposedPose in readablePoseCandidates(
                                containing: subject.bounds,
                                tightScale: exp(tightCandidate.logScale),
                                preferred: state.currentPose,
                                size: subjects.size,
                                minimumReadableScale: policy.minimumReadableScale
                            ) {
                                let pose = !responseBounds.isEmpty ?
                                    zoomedOutPosePreservingCenter(
                                        proposedPose,
                                        containing: responseBounds,
                                        size: subjects.size,
                                        minimumVisibleFraction: policy.responseMinimumVisibleFraction
                                    ) : proposedPose
                                guard exp(pose.logScale) >= policy.minimumReadableScale,
                                      !options.contains(where: {
                                $0.emphasize && poseApproximatelyEqual($0.pose, pose)
                                      }) else { continue }
                                options.append((pose, true))
                            }
                        }
                    }

                    for option in options {
                        var candidateState = state
                        let overviewDeadline = poseApproximatelyEqual(option.pose, base)
                            ? composition.pointerTrip(forActionID: first.id).map {
                                composition.outputTime(atSourceTime: $0.start)
                            }
                            : nil
                        let arrivalDeadline = semanticDeadline
                            ?? overviewDeadline
                            ?? (start + 0.08)
                        let arrival: Double
                        if subject.framingEligibleAt != nil,
                           !anticipatesMeasuredBirth,
                           !poseApproximatelyEqual(option.pose, base) {
                            arrival = candidateState.moveAfter(
                                label: "experimental-shot-\(subject.id)",
                                startAt: start,
                                to: option.pose,
                                size: subjects.size,
                                policy: policy
                            ) ?? start
                        } else {
                            arrival = candidateState.move(
                                label: "experimental-shot-\(subject.id)",
                                arriveBy: arrivalDeadline,
                                to: option.pose,
                                size: subjects.size,
                                policy: policy
                            ) ?? start
                        }

                        let baselineScale = readableScale(
                            for: subject.bounds,
                            through: fallback,
                            size: subjects.size,
                            minimumReadableScale: policy.minimumReadableScale
                        )
                        let presentedScale = readableScale(
                            for: subject.bounds,
                            through: option.pose,
                            size: subjects.size,
                            minimumReadableScale: policy.minimumReadableScale
                        )
                        let readableDuration = max(
                            0,
                            editorialDuration - max(0, arrival - start)
                        )
                        let readability = option.emphasize
                            ? Double(max(0, presentedScale - baselineScale))
                                * policy.readabilityGainPerSecond
                                * readableDuration
                            : 0
                        candidateState.score += readability
                        candidateState.currentSubjectID = option.emphasize
                            ? subject.id : underlying?.subjectID
                        candidateState.shots.append(.init(
                            id: candidateState.nextShotID,
                            subjectID: subject.id,
                            intent: option.emphasize || underlying != nil ? .frame : .overview,
                            interval: start...min(composition.outputDuration, max(start, end)),
                            pose: option.pose,
                            actionIDs: subject.actionIDs,
                            readabilityValue: readability
                        ))
                        candidateState.nextShotID += 1
                        expanded.append(candidateState)
                    }
                }
                states = prunedSearchStates(expanded, limit: policy.searchBeamWidth)

            case let .release(subject):
                // A nearly immediate replacement subject should receive one
                // direct handoff, not an overview bounce between two surfaces.
                if eventIndex + 1 < events.count,
                   case .subject = events[eventIndex + 1],
                   events[eventIndex + 1].sourceTime - event.sourceTime <= 0.75 {
                    continue
                }
                let releaseTime = composition.outputTime(
                    atSourceTime: event.sourceTime
                )
                states = states.map { state in
                    guard state.currentSubjectID == subject.id else { return state }
                    var candidateState = state
                    let underlying = activeUnderlyingShot(
                        in: candidateState.shots,
                        excluding: subject.id,
                        at: releaseTime,
                        base: base,
                        subjectsByID: subjectsByID,
                        composition: composition
                    )
                    candidateState.moveAfter(
                        label: "experimental-release-\(subject.id)",
                        startAt: releaseTime,
                        to: underlying?.pose ?? base,
                        size: subjects.size,
                        policy: policy
                    )
                    candidateState.currentSubjectID = underlying?.subjectID
                    return candidateState
                }
                states = prunedSearchStates(states, limit: policy.searchBeamWidth)

            case let .transition(transition):
                let transitionTime = composition.outputTime(atSourceTime: transition.sourceTime)
                states = states.map { state in
                    var candidateState = state
                    candidateState.move(
                        label: "experimental-orient-\(transition.observationID)",
                        arriveBy: transitionTime,
                        to: base,
                        size: subjects.size,
                        policy: policy
                    )
                    candidateState.currentSubjectID = nil
                    let orientStart = max(transitionTime, candidateState.previousMoveEnd)
                    let orientEnd = min(
                        composition.outputDuration,
                        max(orientStart, orientStart + policy.orientationHold)
                    )
                    candidateState.shots.append(.init(
                        id: candidateState.nextShotID,
                        subjectID: nil,
                        intent: .orient,
                        interval: orientStart...orientEnd,
                        pose: base,
                        actionIDs: transition.causalActionID.map { [$0] } ?? [],
                        readabilityValue: 0
                    ))
                    candidateState.nextShotID += 1

                    if let responseID = transition.responseSubjectID,
                       let response = subjectsByID[responseID] {
                        let pose = composition.cameraPose(
                            containing: response.bounds,
                            maximumScale: policy.responseMaximumScale
                        )
                        let pushArrival = orientEnd + policy.responsePushDelay
                        if exp(pose.logScale) >= policy.minimumReadableScale,
                           (pushArrival + 0.20 < nextEventTime
                            || eventIndex == events.count - 1) {
                            candidateState.move(
                                label: "experimental-response-\(response.id)",
                                arriveBy: pushArrival,
                                to: pose,
                                size: subjects.size,
                                policy: policy
                            )
                            let responseStart = candidateState.previousMoveEnd
                            let responseEnd = min(
                                composition.outputDuration,
                                max(responseStart, responseStart + policy.responseReadingHold)
                            )
                            let readability = Double(exp(pose.logScale) - 1)
                                * policy.readabilityGainPerSecond
                                * max(0, responseEnd - responseStart)
                            candidateState.score += readability
                            candidateState.shots.append(.init(
                                id: candidateState.nextShotID,
                                subjectID: response.id,
                                intent: .pushIn,
                                interval: responseStart...responseEnd,
                                pose: pose,
                                actionIDs: [],
                                readabilityValue: readability
                            ))
                            candidateState.nextShotID += 1
                        }
                    }
                    return candidateState
                }
                states = prunedSearchStates(states, limit: policy.searchBeamWidth)
            }
        }

        let selected = prunedSearchStates(states, limit: 1).first
            ?? SearchState(currentPose: base)
        return ShotSchedule(
            shots: selected.shots,
            moves: selected.moves,
            objectiveValue: selected.score
        )
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

private func trajectoryEdgeCost(
    from: CameraState,
    to: CameraState,
    size: CGSize,
    policy: ShotSchedulePlanner.Policy
) -> Double {
    policy.moveCost
        + pow(Double(to.logScale - from.logScale), 2) * policy.scaleCost
        + normalizedTranslation(from: from, to: to, size: size)
            * policy.translationCost
}

private func prunedSearchStates(
    _ states: [ShotSchedulePlanner.SearchState],
    limit: Int
) -> [ShotSchedulePlanner.SearchState] {
    Array(states.sorted { left, right in
        if abs(left.score - right.score) > 0.000_001 {
            return left.score > right.score
        }
        if left.moves.count != right.moves.count {
            return left.moves.count < right.moves.count
        }
        if abs(left.previousMoveEnd - right.previousMoveEnd) > 0.000_001 {
            return left.previousMoveEnd < right.previousMoveEnd
        }
        if abs(left.currentPose.logScale - right.currentPose.logScale) > 0.000_001 {
            return left.currentPose.logScale < right.currentPose.logScale
        }
        if abs(left.currentPose.x - right.currentPose.x) > 0.000_001 {
            return left.currentPose.x < right.currentPose.x
        }
        return left.currentPose.y < right.currentPose.y
    }.prefix(max(1, limit)))
}

private func activeUnderlyingShot(
    in shots: [ShotSchedule.Shot],
    excluding subjectID: Int,
    at outputTime: Double,
    base: CameraState,
    subjectsByID: [Int: SubjectGraph.Subject],
    composition: NativeComposition
) -> ShotSchedule.Shot? {
    shots.filter {
        $0.subjectID != subjectID
            && $0.interval.contains(outputTime)
            && !poseApproximatelyEqual($0.pose, base)
            && $0.subjectID.flatMap { subjectsByID[$0]?.verifiedReleaseTime }
                .map {
                    composition.outputTime(atSourceTime: $0)
                        > outputTime + 0.000_001
                } != false
    }.max { left, right in
        if left.interval.lowerBound != right.interval.lowerBound {
            return left.interval.lowerBound < right.interval.lowerBound
        }
        return left.id < right.id
    }
}

private func readableScale(
    for bounds: CGRect,
    through pose: CameraState,
    size: CGSize,
    minimumReadableScale: CGFloat
) -> CGFloat {
    let scale = exp(pose.logScale)
    guard scale >= minimumReadableScale else { return 1 }
    let projected = CGRect(
        x: size.width / 2 + (bounds.minX - pose.x) * scale,
        y: size.height / 2 + (bounds.minY - pose.y) * scale,
        width: bounds.width * scale,
        height: bounds.height * scale
    )
    // Candidate construction already aims for the editorial safe frame, but
    // a subject near a source edge cannot acquire padding outside the captured
    // raster. Treat it as readable when it remains fully presented inside the
    // actual frame; otherwise the global objective would assign zero value to
    // every legitimate edge-aligned candidate.
    let presentedFrame = CGRect(origin: .zero, size: size).insetBy(
        dx: size.width * 0.02,
        dy: size.height * 0.02
    )
    return presentedFrame.contains(projected) ? scale : 1
}

private func readablePoseCandidates(
    containing bounds: CGRect,
    tightScale: CGFloat,
    preferred: CameraState,
    size: CGSize,
    minimumReadableScale: CGFloat
) -> [CameraState] {
    guard tightScale >= minimumReadableScale else { return [] }
    let span = max(0, tightScale - minimumReadableScale)
    let scales = [
        minimumReadableScale,
        minimumReadableScale + span / 3,
        minimumReadableScale + span * 2 / 3,
        tightScale
    ]
    var result: [CameraState] = []
    for scale in scales {
        let pose = leastTravelPose(
            containing: bounds, scale: scale,
            preferred: preferred, size: size
        )
        if !result.contains(where: { poseApproximatelyEqual($0, pose) }) {
            result.append(pose)
        }
    }
    return result
}

private func responseCoverageBounds(
    for actionIDs: [Int],
    constraints: [ActionResponseCoverageAudit.Constraint],
    contentRect: CGRect?
) -> [CGRect] {
    guard let contentRect else { return [] }
    let owned = constraints.filter { actionIDs.contains($0.actionID) }
    return owned.map { constraint in
        let normalized = constraint.normalizedBounds
        return CGRect(
            x: contentRect.minX + normalized.minX * contentRect.width,
            y: contentRect.maxY - normalized.maxY * contentRect.height,
            width: normalized.width * contentRect.width,
            height: normalized.height * contentRect.height
        )
    }
}

/// Response evidence is allowed to veto an unsafe crop, but not to steer the
/// camera toward itself. Preserve the selected center and reduce only scale;
/// if even a 1x pose at that center cannot contain the response, abstain to
/// the neutral overview rather than inventing a response-centered shot.
private func zoomedOutPosePreservingCenter(
    _ pose: CameraState,
    containing bounds: [CGRect],
    size: CGSize,
    minimumVisibleFraction: Double
) -> CameraState {
    let currentScale = exp(pose.logScale)
    func candidate(scale: CGFloat) -> CameraState {
        CameraState(x: pose.x, y: pose.y, logScale: log(scale))
    }
    func visibleFraction(of bounds: CGRect, scale: CGFloat) -> Double {
        let camera = candidate(scale: scale)
        let minimum = projectPointThroughCamera(
            bounds.origin, camera: camera, outputSize: size
        )
        let maximum = projectPointThroughCamera(
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            camera: camera, outputSize: size
        )
        let projected = CGRect(
            x: min(minimum.x, maximum.x),
            y: min(minimum.y, maximum.y),
            width: abs(maximum.x - minimum.x),
            height: abs(maximum.y - minimum.y)
        )
        guard !projected.isEmpty else { return 0 }
        let visible = projected.intersection(CGRect(origin: .zero, size: size))
        guard !visible.isNull, !visible.isEmpty else { return 0 }
        return Double(visible.width * visible.height)
            / Double(projected.width * projected.height)
    }
    func coversEveryResponse(scale: CGFloat) -> Bool {
        bounds.allSatisfy {
            visibleFraction(of: $0, scale: scale) >= minimumVisibleFraction
        }
    }
    if coversEveryResponse(scale: currentScale) {
        return pose
    }
    guard coversEveryResponse(scale: 1) else {
        return CameraState(
            x: size.width / 2,
            y: size.height / 2,
            logScale: 0
        )
    }
    var lower: CGFloat = 1
    var upper = currentScale
    for _ in 0..<32 {
        let midpoint = (lower + upper) / 2
        if coversEveryResponse(scale: midpoint) {
            lower = midpoint
        } else {
            upper = midpoint
        }
    }
    return candidate(scale: lower)
}

/// The subject must fit the same safe frame as `cameraPose(containing:)`, but
/// it need not be centered. Clamping the preferred camera center into the
/// feasible interval yields the unique minimum-translation pose at a fixed
/// scale and prevents a small peripheral subject from yanking the camera.
private func leastTravelPose(
    containing bounds: CGRect,
    scale: CGFloat,
    preferred: CameraState,
    size: CGSize
) -> CameraState {
    let safeHalfWidth = size.width * 0.85 / 2
    let safeHalfHeight = size.height * 0.78 / 2
    let viewportHalfWidth = size.width / (2 * scale)
    let viewportHalfHeight = size.height / (2 * scale)
    let lowerX = max(
        viewportHalfWidth,
        bounds.maxX - safeHalfWidth / scale
    )
    let upperX = min(
        size.width - viewportHalfWidth,
        bounds.minX + safeHalfWidth / scale
    )
    let lowerY = max(
        viewportHalfHeight,
        bounds.maxY - safeHalfHeight / scale
    )
    let upperY = min(
        size.height - viewportHalfHeight,
        bounds.minY + safeHalfHeight / scale
    )
    let fallbackX = min(size.width - viewportHalfWidth, max(viewportHalfWidth, bounds.midX))
    let fallbackY = min(size.height - viewportHalfHeight, max(viewportHalfHeight, bounds.midY))
    return CameraState(
        x: lowerX <= upperX ? min(upperX, max(lowerX, preferred.x)) : fallbackX,
        y: lowerY <= upperY ? min(upperY, max(lowerY, preferred.y)) : fallbackY,
        logScale: log(scale)
    )
}

private func normalizedTranslation(
    from: CameraState,
    to: CameraState,
    size: CGSize
) -> Double {
    Double(hypot(to.x - from.x, to.y - from.y) / max(1, hypot(size.width, size.height)))
}

private func poseApproximatelyEqual(_ left: CameraState, _ right: CameraState) -> Bool {
    abs(left.x - right.x) < 0.5
        && abs(left.y - right.y) < 0.5
        && abs(left.logScale - right.logScale) < 0.001
}

private func comfortablyFrames(
    _ bounds: CGRect,
    through pose: CameraState,
    comparedTo tight: CameraState,
    size: CGSize,
    minimumReadableScale: CGFloat
) -> Bool {
    let scale = exp(pose.logScale)
    let tightScale = exp(tight.logScale)
    guard scale >= minimumReadableScale,
          scale >= tightScale * 0.82 else { return false }
    let projected = CGRect(
        x: size.width / 2 + (bounds.minX - pose.x) * scale,
        y: size.height / 2 + (bounds.minY - pose.y) * scale,
        width: bounds.width * scale,
        height: bounds.height * scale
    )
    let safe = CGRect(
        x: size.width * 0.075,
        y: size.height * 0.10,
        width: size.width * 0.85,
        height: size.height * 0.80
    )
    return safe.contains(projected)
}
