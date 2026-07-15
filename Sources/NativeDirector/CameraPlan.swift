import CoreGraphics
import Foundation

/// One straight camera segment in output time. Both planners emit this IR and
/// the renderer and audit consume the exact same instance.
public struct CameraMove: Sendable, Equatable {
    public let label: String
    public let start: Double
    public let end: Double
    public let from: CameraState
    public let to: CameraState

    public init(label: String, start: Double, end: Double, from: CameraState, to: CameraState) {
        self.label = label
        self.start = start
        self.end = end
        self.from = from
        self.to = to
    }
}

/// One sampled continuous camera trajectory. Tracks are emitted only when a
/// static shot cannot preserve a factual interaction while remaining framed.
/// They override the editorial move curve inside their interval, then rejoin
/// it at the final keyframe. This keeps tracking a first-class primitive rather
/// than disguising it as hundreds of independent camera decisions.
public struct CameraTrack: Sendable, Equatable {
    public struct Keyframe: Sendable, Equatable {
        public let time: Double
        public let state: CameraState

        public init(time: Double, state: CameraState) {
            self.time = time
            self.state = state
        }
    }

    public let label: String
    public let keyframes: [Keyframe]

    public init(label: String, keyframes: [Keyframe]) {
        self.label = label
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public var start: Double { keyframes.first?.time ?? 0 }
    public var end: Double { keyframes.last?.time ?? 0 }

    public func state(at time: Double) -> CameraState? {
        guard let first = keyframes.first, let last = keyframes.last else { return nil }
        if time <= first.time { return first.state }
        if time >= last.time { return last.state }
        var lower = 0
        var upper = keyframes.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if keyframes[middle].time <= time { lower = middle } else { upper = middle }
        }
        let left = keyframes[lower]
        let right = keyframes[upper]
        let progress = CGFloat((time - left.time) / max(0.000_001, right.time - left.time))
        return CameraState(
            x: left.state.x + (right.state.x - left.state.x) * progress,
            y: left.state.y + (right.state.y - left.state.y) * progress,
            logScale: left.state.logScale + (right.state.logScale - left.state.logScale) * progress
        )
    }
}

/// The single trajectory evaluator used by planning, rendering, and auditing.
public func cameraState(at time: Double, moves: [CameraMove], base: CameraState) -> CameraState {
    var state = base
    for move in moves {
        if time < move.start { break }
        if time >= move.end {
            state = move.to
            continue
        }
        let raw = (time - move.start) / max(0.001, move.end - move.start)
        let progress = CGFloat(cinematicCameraProgress(raw))
        return CameraState(
            x: move.from.x + (move.to.x - move.from.x) * progress,
            y: move.from.y + (move.to.y - move.from.y) * progress,
            logScale: move.from.logScale + (move.to.logScale - move.from.logScale) * progress
        )
    }
    return state
}

/// Shared trajectory evaluator for rendering and auditing. An active tracking
/// interval owns the camera at that instant; outside it, the authored shot
/// moves remain the source of truth.
public func cameraState(at time: Double, plan: CameraPlan, base: CameraState) -> CameraState {
    if let track = plan.tracks.last(where: { time >= $0.start && time <= $0.end }),
       let tracked = track.state(at: time) {
        return tracked
    }
    return cameraState(at: time, moves: plan.moves, base: base)
}

public struct CameraPlan: Sendable {
    public let moves: [CameraMove]
    public let tracks: [CameraTrack]
    public let diagnostics: CameraPlanDiagnostics

    public init(
        moves: [CameraMove],
        tracks: [CameraTrack] = [],
        diagnostics: CameraPlanDiagnostics
    ) {
        self.moves = moves
        self.tracks = tracks.sorted { $0.start < $1.start }
        self.diagnostics = diagnostics
    }
}

public struct CameraPlanDiagnostics: Sendable {
    public let plannerVersion: String
    public let feasible: Bool
    public let rejectedNodes: Int
    public let rejectedEdges: Int
    public let failure: String?

    public init(
        plannerVersion: String,
        feasible: Bool,
        rejectedNodes: Int = 0,
        rejectedEdges: Int = 0,
        failure: String? = nil
    ) {
        self.plannerVersion = plannerVersion
        self.feasible = feasible
        self.rejectedNodes = rejectedNodes
        self.rejectedEdges = rejectedEdges
        self.failure = failure
    }
}
