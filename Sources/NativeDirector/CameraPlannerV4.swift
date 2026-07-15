import CoreGraphics
import Foundation

public struct V4ProductionPlan: Sendable {
    public let camera: CameraPlan
    public let subjects: SubjectGraph
    public let schedule: ShotSchedule
    public let factualSamples: Int
    public let trackingSamples: Int

    public init(
        camera: CameraPlan,
        subjects: SubjectGraph,
        schedule: ShotSchedule,
        factualSamples: Int,
        trackingSamples: Int
    ) {
        self.camera = camera
        self.subjects = subjects
        self.schedule = schedule
        self.factualSamples = factualSamples
        self.trackingSamples = trackingSamples
    }
}

/// Subject-first production planner.
///
/// V4 chooses editorial shots over persistent subjects, compiles them into a
/// continuous trajectory, then enforces factual visibility against the whole
/// trajectory. It never turns a cursor trip into a static-pose eligibility
/// gate and never inserts a reveal/return pulse as a local repair.
public enum CameraPlannerV4 {
    public struct Policy: Sendable {
        public var factualInset: CGFloat = 28
        public var validationRate = 480.0
        public var trackingShoulder = 0.35
        public var shotPolicy = ShotSchedulePlanner.Policy.default

        public init() {}
        public static let `default` = Policy()
    }

    public static func plan(
        graph: ProductionPlanGraph,
        composition: NativeComposition,
        base: CameraState,
        policy: Policy = .default
    ) -> V4ProductionPlan {
        let subjects = SubjectGraph.make(graph: graph, composition: composition)
        let schedule = ShotSchedulePlanner.plan(
            subjects: subjects,
            composition: composition,
            base: base,
            policy: policy.shotPolicy
        )
        let compiled = compileTrajectory(
            moves: schedule.moves,
            composition: composition,
            base: base,
            policy: policy
        )
        let diagnostics = CameraPlanDiagnostics(
            plannerVersion: "v4-subject-schedule",
            feasible: compiled.violations == 0,
            failure: compiled.violations == 0
                ? nil
                : "compiled trajectory has \(compiled.violations) factual visibility violations"
        )
        return V4ProductionPlan(
            camera: CameraPlan(
                moves: schedule.moves,
                tracks: compiled.tracks,
                diagnostics: diagnostics
            ),
            subjects: subjects,
            schedule: schedule,
            factualSamples: compiled.factualSamples,
            trackingSamples: compiled.trackingSamples
        )
    }
}

private struct CompiledTracking {
    let tracks: [CameraTrack]
    let factualSamples: Int
    let trackingSamples: Int
    let violations: Int
}

private func compileTrajectory(
    moves: [CameraMove],
    composition: NativeComposition,
    base: CameraState,
    policy: CameraPlannerV4.Policy
) -> CompiledTracking {
    let rate = max(60, policy.validationRate)
    let count = max(1, Int(ceil(composition.outputDuration * rate)))
    var times: [Double] = []
    var unconstrained: [CameraState] = []
    var initiallyAdjusted: [CameraState] = []
    times.reserveCapacity(count)
    unconstrained.reserveCapacity(count)
    initiallyAdjusted.reserveCapacity(count)

    for index in 0..<count {
        let outputTime = min(
            composition.outputDuration,
            (Double(index) + 0.5) / rate
        )
        let sourceTime = composition.sourceTime(atOutputTime: outputTime)
        let state = cameraState(at: outputTime, moves: moves, base: base)
        times.append(outputTime)
        unconstrained.append(state)
        initiallyAdjusted.append(composition.enforcingFactualActionVisibility(
            state, at: sourceTime, inset: policy.factualInset
        ))
    }

    // A shoulder introduced for one fact can cross another active target and
    // create a new violation. Solve to a fixed point over the whole trajectory
    // instead of treating each correction range as an independent local pass.
    var recoveredStates = unconstrained
    var changedRanges: [ClosedRange<Int>] = []
    let maximumPasses = max(8, min(32, Int(ceil(
        composition.outputDuration / max(0.05, policy.trackingShoulder)
    ))))
    for _ in 0..<maximumPasses {
        var required: [CameraState] = []
        required.reserveCapacity(count)
        for index in 0..<count {
            required.append(composition.enforcingFactualActionVisibility(
                recoveredStates[index],
                at: composition.sourceTime(atOutputTime: times[index]),
                inset: policy.factualInset
            ))
        }
        let pass = smoothedVisibilityCorrections(
            unconstrained: recoveredStates,
            adjusted: required,
            samplesPerSecond: rate,
            shoulderSeconds: policy.trackingShoulder
        )
        guard !pass.ranges.isEmpty else { break }
        recoveredStates = pass.states
        changedRanges = mergeIndexRanges(changedRanges + pass.ranges)
    }
    let shoulder = max(1, Int(rate * policy.trackingShoulder))
    var expanded: [ClosedRange<Int>] = []
    for range in changedRanges {
        let candidate = max(0, range.lowerBound - shoulder)...min(count - 1, range.upperBound + shoulder)
        if let previous = expanded.last, candidate.lowerBound <= previous.upperBound + 1 {
            expanded[expanded.count - 1] = previous.lowerBound...max(previous.upperBound, candidate.upperBound)
        } else {
            expanded.append(candidate)
        }
    }

    let tracks = expanded.enumerated().map { trackIndex, range in
        CameraTrack(
            label: "v4-track-\(trackIndex)",
            keyframes: range.map { index in
                CameraTrack.Keyframe(time: times[index], state: recoveredStates[index])
            }
        )
    }
    let plan = CameraPlan(
        moves: moves,
        tracks: tracks,
        diagnostics: CameraPlanDiagnostics(plannerVersion: "v4-validation", feasible: true)
    )
    var violations = 0
    var factualSamples = 0
    for index in 0..<count {
        let state = cameraState(at: times[index], plan: plan, base: base)
        let sourceTime = composition.sourceTime(atOutputTime: times[index])
        let corrected = composition.enforcingFactualActionVisibility(
            state, at: sourceTime, inset: policy.factualInset
        )
        let differs = abs(state.x - corrected.x) > 0.0001
            || abs(state.y - corrected.y) > 0.0001
            || abs(state.logScale - corrected.logScale) > 0.0001
        if differs {
            violations += 1
            factualSamples += 1
        } else if abs(initiallyAdjusted[index].x - unconstrained[index].x) > 0.0001
                    || abs(initiallyAdjusted[index].y - unconstrained[index].y) > 0.0001
                    || abs(initiallyAdjusted[index].logScale - unconstrained[index].logScale) > 0.0001 {
            factualSamples += 1
        }
    }
    return CompiledTracking(
        tracks: tracks,
        factualSamples: factualSamples,
        trackingSamples: expanded.reduce(0) { $0 + $1.count },
        violations: violations
    )
}

private func mergeIndexRanges(_ ranges: [ClosedRange<Int>]) -> [ClosedRange<Int>] {
    var result: [ClosedRange<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        if let previous = result.last, range.lowerBound <= previous.upperBound + 1 {
            result[result.count - 1] = previous.lowerBound...max(previous.upperBound, range.upperBound)
        } else {
            result.append(range)
        }
    }
    return result
}
