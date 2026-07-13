import CoreGraphics
import Foundation

public struct Timeline: Codable, Sendable {
    public struct OcclusionSpan: Codable, Sendable {
        public let startTime: Double
        public let endTime: Double
    }
    public struct Event: Codable, Sendable {
        public struct PointValue: Codable, Sendable {
            public let xNorm: Double?
            public let yNorm: Double?
        }
        public struct Coordinates: Codable, Sendable {
            public let xNorm: Double?
            public let yNorm: Double?
            public let from: PointValue?
            public let to: PointValue?
        }
        public struct Timing: Codable, Sendable {
            public let toolCallDurationMs: Double?
            public let toolCallStartedAt: String?
            public let toolCallEndedAt: String?
            public let actionIsFinalSkyCall: Bool?
        }
        public struct SemanticTarget: Codable, Sendable {
            public struct Bounds: Codable, Sendable {
                public let xNorm: Double?
                public let yNorm: Double?
                public let widthNorm: Double?
                public let heightNorm: Double?
            }
            public let bounds: Bounds?
            public let role: String?
        }
        public struct TargetResolution: Codable, Sendable {
            public let provenance: String?
            public let confidence: Double?
        }
        public struct EditingIntent: Codable, Sendable {
            public let emphasis: String?
            public let holdMs: Double?
        }
        public struct Arguments: Codable, Sendable {
            public let element_index: Int?
        }
        public let actionId: String?
        public let time: Double?
        public let action: String?
        public let method: String?
        public let coordinates: Coordinates?
        public let timing: Timing?
        public let args: Arguments?
        public let semanticTarget: SemanticTarget?
        public let targetResolution: TargetResolution?
        public let editingIntent: EditingIntent?
    }
    public struct CompositionOptions: Codable, Sendable {
        public struct Recipe: Codable, Sendable {
            public let deadTimeRate: Double?
            public let cursorCompression: Double?
            public let zoomStrength: Double?
            public let cursorPath: String?
            public let cursorTiltStrength: Double?
            public let allowInferredTargets: Bool?
        }
        public let cursorScale: Double?
        public let director: Recipe?
    }
    public struct Capture: Codable, Sendable { public let startedAt: String? }
    public let events: [Event]
    public let composition: CompositionOptions?
    public let capture: Capture?
    public let occlusionSpans: [OcclusionSpan]?
}

public struct DirectedAction: Sendable {
    public let id: Int
    public let actionId: String
    public let kind: String
    public let time: Double
    public let point: CGPoint?
    public let from: CGPoint?
    public let to: CGPoint?
    public let duration: Double
    public let semanticBounds: CGRect?
    public let pointProvenance: String?
    public let pointConfidence: Double
    public let cursorAllowed: Bool
    public let emphasis: String?
    public let holdExtension: Double
    public let requiresExactTarget: Bool
    public let attention: AttentionDecision?
    public let episodeID: Int?

    public var rendersCursor: Bool {
        guard point != nil || to != nil else { return false }
        if cursorAllowed { return true }
        switch pointProvenance {
        case "direct", "ax-identity", "ax-focus": return true
        case "ax-structural": return pointConfidence >= 0.75
        default: return false
        }
    }
}

public enum EvidenceSource: String, Sendable, Equatable {
    case pointer
    case visualPointer
    case dragPath
    case accessibility
    case visualResponse
}

public struct AttentionEvidence: Sendable {
    public let source: EvidenceSource
    public let timeRange: ClosedRange<Double>
    public let bounds: CGRect
    public let confidence: Double
    public let framingWeight: Double
    public let persistence: Double
    public let causalActionID: Int
}

public enum CameraBehavior: String, Sendable, Equatable {
    case point
    case region
    case wideResponse
}

public enum VisualMotionKind: String, Sendable, Equatable, Codable {
    case appearance
    case translation
    case transformation
}

public struct AttentionDecision: Sendable {
    public let bounds: CGRect
    public let confidence: Double
    public let behavior: CameraBehavior
    public let evidence: [AttentionEvidence]
}

public struct VisualMotionObservation: Sendable {
    public let time: Double
    public let normalizedBounds: CGRect
    public let changedFraction: Double
    public let magnitude: Double
    public let kind: VisualMotionKind

    public init(time: Double, normalizedBounds: CGRect, changedFraction: Double, magnitude: Double, kind: VisualMotionKind = .transformation) {
        self.time = time
        self.normalizedBounds = normalizedBounds
        self.changedFraction = changedFraction
        self.magnitude = magnitude
        self.kind = kind
    }
}

public struct Shot: Sendable {
    public let id: Int
    public var start: Double
    public var focusStart: Double
    public var focusEnd: Double
    public var end: Double
    public var scale: CGFloat
    public var actions: [DirectedAction]
}

public struct RetimeSegment: Sendable {
    public let sourceStart: Double
    public let sourceEnd: Double
    public let rate: Double
    public let outputStart: Double
    public var outputDuration: Double { (sourceEnd - sourceStart) / rate }
}

public struct PointerAnchor: Sendable {
    public let actionID: Int
    public let time: Double
    public let point: CGPoint
    public let kind: String
}

public struct PointerTrip: Sendable {
    public let actionID: Int
    public let start: Double
    public let end: Double
    public let from: CGPoint
    public let to: CGPoint
}

private struct PointerTravelInterval: Sendable {
    let actionID: Int
    let start: Double
    let end: Double
    let from: CGPoint
    let to: CGPoint
    let curve: CGFloat
}

public struct CameraState: Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var logScale: CGFloat
    public init(x: CGFloat, y: CGFloat, logScale: CGFloat) {
        self.x = x
        self.y = y
        self.logScale = logScale
    }
}

public struct CursorState: Sendable {
    public let point: CGPoint
    public let scale: CGFloat
    public let rotation: CGFloat
}

public func coreImageCursorHotspot(logicalSize: CGSize, hotspotFromTopLeft: CGPoint, scale: CGFloat) -> CGPoint {
    CGPoint(
        x: hotspotFromTopLeft.x * scale,
        y: (logicalSize.height - hotspotFromTopLeft.y) * scale
    )
}

public func projectPointThroughCamera(_ point: CGPoint, camera: CameraState, outputSize: CGSize) -> CGPoint {
    let scale = exp(camera.logScale)
    return CGPoint(
        x: outputSize.width / 2 + (point.x - camera.x) * scale,
        y: outputSize.height / 2 + (point.y - camera.y) * scale
    )
}

public func aspectFittedContentRect(canvas: CGSize, sourceAspect: CGFloat, scale: CGFloat) -> CGRect {
    let maximum = CGSize(width: canvas.width * scale, height: canvas.height * scale)
    let width = min(maximum.width, maximum.height * sourceAspect)
    let height = width / sourceAspect
    return CGRect(
        x: (canvas.width - width) / 2,
        y: (canvas.height - height) / 2,
        width: width,
        height: height
    )
}

public struct DirectorRecipe: Sendable {
    public let deadTimeRate: Double
    public let cursorCompression: Double
    public let zoomStrength: Double
    public let cursorPath: CursorPathStyle
    public let cursorTiltStrength: Double
    public let allowInferredTargets: Bool
}

public enum CursorPathStyle: String, Sendable {
    case natural
    case straight
}

public struct NativeComposition: Sendable {
    public let size: CGSize
    public let actions: [DirectedAction]
    public let shots: [Shot]
    public let anchors: [PointerAnchor]
    public let retime: [RetimeSegment]
    public let outputDuration: Double
    public let cursorScale: CGFloat
    public let recipe: DirectorRecipe
    public let reducesWaiting: Bool
    public let interactionPhases: [Int: InteractionPhases]
    private let pointerTravel: [PointerTravelInterval]

    public init(
        timeline: Timeline,
        size: CGSize,
        contentRect: CGRect,
        sourceDuration: Double,
        reduceWaiting: Bool = false,
        waitingTime: Double = 0.1,
        motionRanges: [ClosedRange<Double>] = [],
        motionObservations: [VisualMotionObservation] = [],
        interactionPhases: [Int: InteractionPhases] = [:],
        cursorPathOverride: CursorPathStyle? = nil,
        cursorTiltStrengthOverride: Double? = nil
    ) {
        self.size = size
        self.reducesWaiting = reduceWaiting
        recipe = DirectorRecipe(
            deadTimeRate: timeline.composition?.director?.deadTimeRate ?? 6,
            cursorCompression: timeline.composition?.director?.cursorCompression ?? 0.1,
            zoomStrength: timeline.composition?.director?.zoomStrength ?? 1,
            cursorPath: cursorPathOverride
                ?? CursorPathStyle(rawValue: timeline.composition?.director?.cursorPath ?? "natural")
                ?? .natural,
            cursorTiltStrength: clamp(
                cursorTiltStrengthOverride
                    ?? timeline.composition?.director?.cursorTiltStrength
                    ?? 1,
                0, 1.5
            ),
            allowInferredTargets: timeline.composition?.director?.allowInferredTargets ?? false
        )
        cursorScale = CGFloat(timeline.composition?.cursorScale ?? 3)
        self.interactionPhases = interactionPhases
        let allowInferredTargets = recipe.allowInferredTargets
        let occlusionRanges = (timeline.occlusionSpans ?? []).compactMap { span -> ClosedRange<Double>? in
            guard span.startTime.isFinite, span.endTime.isFinite, span.endTime >= span.startTime else { return nil }
            return span.startTime...span.endTime
        }
        let occludedActionIDs = Set(timeline.events.enumerated().compactMap { entry -> Int? in
            guard let time = entry.element.time,
                  occlusionRanges.contains(where: { $0.contains(time) }) else { return nil }
            return entry.offset
        })
        let normalizedActions = timeline.events.enumerated().compactMap { entry in
            Self.normalize(
                entry.element, id: entry.offset, size: size, contentRect: contentRect,
                allowInferredTargets: allowInferredTargets,
                activationTime: interactionPhases[entry.offset]?.activation,
                evidenceOccluded: occlusionRanges.contains { range in
                    range.contains(entry.element.time ?? -.infinity)
                }
            )
        }.sorted { $0.time < $1.time }
        let attentionActions = Self.inferAttention(
            actions: normalizedActions,
            observations: motionObservations.filter { observation in
                !occlusionRanges.contains { $0.contains(observation.time) }
            },
            size: size,
            contentRect: contentRect,
            allowInferredTargets: allowInferredTargets,
            occludedActionIDs: occludedActionIDs
        )
        // Pointer coordinates are action facts. Never synthesize them from a
        // previous or subsequent action; unresolved element references remain
        // unresolved until their own AX identity can be joined.
        let directedActions = attentionActions
        let builtAnchors = Self.buildAnchors(directedActions, phases: interactionPhases)
        let builtPointerTravel = Self.buildPointerTravel(
            anchors: builtAnchors, size: size, style: recipe.cursorPath
        )
        let interactionStarts = Dictionary(
            builtPointerTravel.map { ($0.actionID, $0.start) },
            uniquingKeysWith: min
        )
        let builtRetime = Self.buildRetime(
            directedActions,
            duration: sourceDuration,
            rate: recipe.deadTimeRate,
            reduceWaiting: reduceWaiting,
            waitingTime: max(0, waitingTime),
            motionRanges: motionRanges,
            interactionStarts: interactionStarts
        )
        let episodeActions = Self.inferAttentionEpisodes(actions: directedActions, retime: builtRetime, size: size)
        actions = episodeActions
        retime = builtRetime
        shots = Self.groupShots(
            episodeActions.filter { actionFocus($0) != nil },
            size: size,
            recipe: recipe,
            retime: builtRetime,
            interactionStarts: interactionStarts
        )
        anchors = builtAnchors
        pointerTravel = builtPointerTravel
        outputDuration = retime.reduce(0) { $0 + $1.outputDuration }
    }

    public func sourceTime(atOutputTime outputTime: Double) -> Double {
        let radius = 0.16
        if outputTime <= radius || outputTime >= outputDuration - radius {
            return rawSourceTime(atOutputTime: outputTime)
        }
        if reducesWaiting && crossesEditorialCut(from: outputTime - radius, to: outputTime + radius) {
            return rawSourceTime(atOutputTime: outputTime)
        }
        // Convolving the piecewise-linear time map removes the instantaneous
        // 1x/6x velocity changes without moving segment endpoints or actions.
        let weights: [Double] = [1, 2, 3, 4, 5, 4, 3, 2, 1]
        let total = weights.reduce(0, +)
        return zip(weights.indices, weights).reduce(0) { sum, pair in
            let phase = Double(pair.0) / Double(weights.count - 1) * 2 - 1
            return sum + rawSourceTime(atOutputTime: outputTime + phase * radius) * pair.1 / total
        }
    }

    public func outputTime(atSourceTime sourceTime: Double) -> Double {
        Self.outputTime(for: sourceTime, retime: retime)
    }

    private func rawSourceTime(atOutputTime outputTime: Double) -> Double {
        guard let segment = retime.last(where: { outputTime >= $0.outputStart }) else { return 0 }
        return min(segment.sourceEnd, segment.sourceStart + (outputTime - segment.outputStart) * segment.rate)
    }

    private func crossesEditorialCut(from start: Double, to end: Double) -> Bool {
        guard retime.count > 1 else { return false }
        for index in 1..<retime.count {
            let boundary = retime[index].outputStart
            if boundary >= start, boundary <= end,
               abs(retime[index - 1].sourceEnd - retime[index].sourceStart) > 0.001 {
                return true
            }
        }
        return false
    }

    public func settledCamera(forActionID actionID: Int) -> CameraState? {
        guard let action = actions.first(where: { $0.id == actionID }),
              let focus = actionFocus(action) else { return nil }
        let desiredScale = Self.actionScale(action, size: size, recipe: recipe)
        let framingBounds = action.attention?.bounds ?? CGRect(x: focus.x, y: focus.y, width: 1, height: 1)
        let fitX = framingBounds.width > 0 ? size.width * 0.85 / framingBounds.width : .greatestFiniteMagnitude
        let fitY = framingBounds.height > 0 ? size.height * 0.78 / framingBounds.height : .greatestFiniteMagnitude
        let scale = max(1, min(desiredScale, min(fitX, fitY)))
        let limitX = size.width / (2 * scale)
        let limitY = size.height / (2 * scale)
        return CameraState(
            x: clamp(focus.x, limitX, size.width - limitX),
            y: clamp(focus.y, limitY, size.height - limitY),
            logScale: log(scale)
        )
    }

    public func pointerTrip(forActionID actionID: Int) -> PointerTrip? {
        pointerTravel.first(where: { $0.actionID == actionID }).map {
            PointerTrip(
                actionID: $0.actionID, start: $0.start, end: $0.end,
                from: $0.from, to: $0.to
            )
        }
    }

    public func cameraPose(containing bounds: CGRect, maximumScale: CGFloat) -> CameraState {
        let safeSize = CGSize(width: size.width * 0.85, height: size.height * 0.78)
        let fitX = bounds.width > 0 ? safeSize.width / bounds.width : .greatestFiniteMagnitude
        let fitY = bounds.height > 0 ? safeSize.height / bounds.height : .greatestFiniteMagnitude
        let scale = max(1, min(maximumScale, min(fitX, fitY)))
        let limitX = size.width / (2 * scale)
        let limitY = size.height / (2 * scale)
        return CameraState(
            x: clamp(bounds.midX, limitX, size.width - limitX),
            y: clamp(bounds.midY, limitY, size.height - limitY),
            logScale: log(scale)
        )
    }

    /// Applies the non-negotiable framing contract for model-authored input.
    ///
    /// The director may otherwise let the camera and idle cursor diverge. While
    /// a pointer action is in flight, however, its reconstructed hotspot is
    /// factual evidence and must remain visible. Semantic input targets receive
    /// the same protection while the input action is active. This is a camera
    /// correction rather than a cursor clamp, so the pointer still lands on the
    /// actual Computer Use coordinate.
    public func enforcingFactualActionVisibility(
        _ camera: CameraState,
        at sourceTime: Double
    ) -> CameraState {
        factualVisibilityAdjusted(
            camera, required: factualActiveBounds(at: sourceTime)
        )
    }

    private func factualVisibilityAdjusted(
        _ camera: CameraState,
        required: CGRect
    ) -> CameraState {
        guard !required.isNull, !required.isEmpty else { return camera }

        let preferredSafeFrame = CGRect(x: 50, y: 50, width: size.width - 100, height: size.height - 100)
        var scale = exp(camera.logScale)
        let fittingScaleX = required.width > 0
            ? preferredSafeFrame.width / required.width
            : .greatestFiniteMagnitude
        let fittingScaleY = required.height > 0
            ? preferredSafeFrame.height / required.height
            : .greatestFiniteMagnitude
        scale = max(1, min(scale, min(fittingScaleX, fittingScaleY)))

        var corrected = CameraState(
            x: camera.x,
            y: camera.y,
            logScale: log(scale)
        )
        let projected = CGRect(
            x: size.width / 2 + (required.minX - corrected.x) * scale,
            y: size.height / 2 + (required.minY - corrected.y) * scale,
            width: required.width * scale,
            height: required.height * scale
        )
        if projected.minX < preferredSafeFrame.minX {
            corrected.x += (projected.minX - preferredSafeFrame.minX) / scale
        } else if projected.maxX > preferredSafeFrame.maxX {
            corrected.x += (projected.maxX - preferredSafeFrame.maxX) / scale
        }
        if projected.minY < preferredSafeFrame.minY {
            corrected.y += (projected.minY - preferredSafeFrame.minY) / scale
        } else if projected.maxY > preferredSafeFrame.maxY {
            corrected.y += (projected.maxY - preferredSafeFrame.maxY) / scale
        }

        // Prefer the safe frame, but never reveal space outside the composed
        // canvas merely to create an artificial margin around an edge target.
        let limitX = size.width / (2 * scale)
        let limitY = size.height / (2 * scale)
        corrected.x = clamp(corrected.x, limitX, size.width - limitX)
        corrected.y = clamp(corrected.y, limitY, size.height - limitY)
        return corrected
    }

    public func cursor(at sourceTime: Double) -> CursorState {
        let point = cursorPoint(at: sourceTime)
        return CursorState(
            point: point,
            scale: clickScale(at: sourceTime),
            rotation: pointerAttitude(at: sourceTime)
        )
    }

    private func pointerAttitude(at time: Double) -> CGFloat {
        guard recipe.cursorTiltStrength > 0 else { return 0 }
        // Treat attitude as an asymmetric envelope: motion applies force
        // immediately, but stored visual momentum releases more slowly after
        // the hotspot has arrived. Sampling recent kinematics keeps this
        // deterministic for arbitrary offline frame times without introducing
        // renderer-owned mutable state.
        let releaseTime = 0.22
        let historyDuration = 0.66
        let historyStep = 1.0 / 30.0
        var retainedEngagement: CGFloat = 0
        var age = 0.0
        while age <= historyDuration {
            let engagement = instantaneousPointerTiltEngagement(at: max(0, time - age))
            let released = engagement * CGFloat(exp(-age / releaseTime))
            retainedEngagement = max(retainedEngagement, released)
            age += historyStep
        }
        let maximumClockwiseTilt = CGFloat.pi / 4
        return -min(
            maximumClockwiseTilt,
            maximumClockwiseTilt * retainedEngagement * CGFloat(recipe.cursorTiltStrength)
        )
    }

    private func instantaneousPointerTiltEngagement(at time: Double) -> CGFloat {
        let dt = 1.0 / 120.0
        let previous = cursorPoint(at: max(0, time - dt))
        let current = cursorPoint(at: time)
        let next = cursorPoint(at: time + dt)
        let velocity = CGPoint(
            x: (next.x - previous.x) / CGFloat(2 * dt),
            y: (next.y - previous.y) / CGFloat(2 * dt)
        )
        let acceleration = CGPoint(
            x: (next.x - 2 * current.x + previous.x) / CGFloat(dt * dt),
            y: (next.y - 2 * current.y + previous.y) / CGFloat(dt * dt)
        )
        let speed = hypot(velocity.x, velocity.y)
        guard speed > 6 else { return 0 }

        // Screen Studio's attitude is a constrained deformation, not a
        // weather vane: the standard macOS arrow remains the resting pose and
        // its tail may trail clockwise only. Ordinary travel barely moves it;
        // exceptional speed can straighten its visual axis to vertical, but
        // never rotate beyond that pose.
        let accelerationMagnitude = hypot(acceleration.x, acceleration.y)
        let accelerationWeight = CGFloat(smootherstep(20, 240, Double(speed)))
        let accelerationContribution = min(180, accelerationMagnitude * 0.004) * accelerationWeight
        let kineticIntensity = speed + accelerationContribution
        return CGFloat(smootherstep(260, 2_800, Double(kineticIntensity)))
    }

    private func cursorPoint(at time: Double) -> CGPoint {
        let initial = CGPoint(x: size.width * 0.16, y: size.height * 0.16)
        guard !anchors.isEmpty else { return initial }
        guard let upcoming = pointerTravel.first(where: { time <= $0.end }) else { return anchors.last!.point }
        return travel(
            upcoming.from, upcoming.to, time,
            upcoming.start, upcoming.end, upcoming.curve
        )
    }

    private func factualActiveBounds(at time: Double) -> CGRect {
        var required = CGRect.null
        for interval in pointerTravel {
            guard let action = actions.first(where: { $0.id == interval.actionID }),
                  action.rendersCursor else { continue }
            let confirmationEnd = action.kind == "drag"
                ? action.time + action.duration / 2 + 0.25
                : action.time + 0.32
            guard time >= interval.start, time <= confirmationEnd else { continue }
            let point = cursorPoint(at: time)
            required = required.union(CGRect(x: point.x, y: point.y, width: 1, height: 1))
            if time >= interval.end - 0.12, let target = action.point {
                required = required.union(CGRect(x: target.x, y: target.y, width: 1, height: 1))
            }
        }
        for action in actions where typingActions.contains(action.kind) {
            guard let bounds = action.semanticBounds else { continue }
            guard time >= action.time - 0.45, time <= Self.actionHoldEnd(action) else { continue }
            required = required.union(bounds)
        }
        return required
    }

    private func clickScale(at time: Double) -> CGFloat {
        var scale: CGFloat = 1
        for action in actions where action.kind == "click" && action.rendersCursor {
            let relative = time - action.time
            if relative < -0.1 || relative > 0.75 { continue }
            if relative < 0 {
                scale *= lerp(1, CGFloat(1 - recipe.cursorCompression), CGFloat(smootherstep(-0.1, 0, relative)))
            } else {
                scale *= CGFloat(1 - recipe.cursorCompression * exp(-9 * relative) * cos(19 * relative))
            }
        }
        return scale
    }

    private static func normalize(
        _ event: Timeline.Event, id: Int, size: CGSize, contentRect: CGRect,
        allowInferredTargets: Bool,
        activationTime: Double? = nil,
        evidenceOccluded: Bool = false
    ) -> DirectedAction? {
        guard let kind = event.action ?? event.method,
              let rawTime = event.time, rawTime.isFinite else { return nil }
        let time = activationTime ?? rawTime
        func point(_ value: Timeline.Event.PointValue?) -> CGPoint? {
            guard let x = value?.xNorm, let y = value?.yNorm, x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: contentRect.minX + CGFloat(x) * contentRect.width, y: size.height - (contentRect.minY + CGFloat(y) * contentRect.height))
        }
        var bounds: CGRect?
        if let value = event.semanticTarget?.bounds,
           let x = value.xNorm, let y = value.yNorm, let width = value.widthNorm, let height = value.heightNorm,
           [x, y, width, height].allSatisfy(\.isFinite) {
            bounds = CGRect(
                x: contentRect.minX + CGFloat(x) * contentRect.width,
                y: size.height - (contentRect.minY + CGFloat(y + height) * contentRect.height),
                width: CGFloat(width) * contentRect.width,
                height: CGFloat(height) * contentRect.height
            )
            let areaFraction = bounds!.area / max(1, contentRect.area)
            let role = event.semanticTarget?.role?.lowercased() ?? ""
            if areaFraction > 0.65 || ["axwebarea", "axwindow", "axapplication"].contains(role) {
                bounds = nil
            }
        }
        let from = point(event.coordinates?.from)
        let to = point(event.coordinates?.to)
        let semanticPoint = bounds.map { CGPoint(x: $0.midX, y: $0.midY) }
        let direct = event.coordinates.map { Timeline.Event.PointValue(xNorm: $0.xNorm, yNorm: $0.yNorm) }
        let actionPoint = evidenceOccluded ? nil : point(direct) ?? semanticPoint
        let pointProvenance = evidenceOccluded ? "unresolved" : event.targetResolution?.provenance
            ?? (point(direct) != nil || (from != nil && to != nil) ? "direct" : semanticPoint != nil ? "ax-identity" : nil)
        let measured = (event.timing?.toolCallDurationMs ?? 0) / 1000
        let duration: Double
        if kind == "drag" { duration = clamp(measured == 0 ? 0.75 : measured, 0.45, 1.6) }
        else if kind == "scroll" { duration = clamp(measured == 0 ? 0.8 : measured, 0.5, 1.8) }
        else if typingActions.contains(kind) { duration = clamp(measured == 0 ? 0.8 : measured, 0.4, 2.2) }
        else { duration = clamp(measured == 0 ? 0.28 : measured, 0.16, 1.2) }
        return DirectedAction(
            id: id, actionId: event.actionId ?? "act_\(id)", kind: kind, time: time, point: actionPoint,
            from: evidenceOccluded ? nil : from, to: evidenceOccluded ? nil : to,
            duration: duration, semanticBounds: evidenceOccluded ? nil : bounds, pointProvenance: pointProvenance,
            pointConfidence: evidenceOccluded ? 0 : event.targetResolution?.confidence ?? 0,
            cursorAllowed: !evidenceOccluded && allowInferredTargets && (actionPoint != nil || to != nil),
            emphasis: event.editingIntent?.emphasis,
            holdExtension: max(0, (event.editingIntent?.holdMs ?? 0) / 1000),
            requiresExactTarget: event.args?.element_index != nil,
            attention: nil, episodeID: nil
        )
    }

    private static func inferAttention(
        actions: [DirectedAction],
        observations: [VisualMotionObservation],
        size: CGSize,
        contentRect: CGRect,
        allowInferredTargets: Bool,
        occludedActionIDs: Set<Int>
    ) -> [DirectedAction] {
        // A visual response belongs to the most recent action that could have
        // caused it. This prevents one animation from widening several shots.
        var observationsByAction: [Int: [VisualMotionObservation]] = [:]
        for observation in observations {
            guard let action = actions.last(where: {
                !occludedActionIDs.contains($0.id) &&
                // Computer-use telemetry may be written when the tool result
                // returns, after the first changed frame is already captured.
                observation.time >= $0.time - 0.6 && observation.time <= $0.time + 1.3
            }) else { continue }
            observationsByAction[action.id, default: []].append(observation)
        }

        return actions.map { originalAction in
            guard !occludedActionIDs.contains(originalAction.id) else { return originalAction }
            var action = originalAction
            if pointerActions.contains(action.kind), action.kind != "drag", action.point == nil,
               !action.requiresExactTarget,
               let inferredPoint = visualPointerFallback(
                   observations: observationsByAction[action.id, default: []],
                   actionTime: action.time, size: size, contentRect: contentRect
               ) {
                action = DirectedAction(
                    id: action.id, actionId: action.actionId, kind: action.kind, time: action.time,
                    point: inferredPoint, from: action.from, to: action.to,
                    duration: action.duration, semanticBounds: action.semanticBounds,
                    pointProvenance: "visual-inferred",
                    pointConfidence: 0.52,
                    cursorAllowed: allowInferredTargets,
                    emphasis: action.emphasis, holdExtension: action.holdExtension,
                    requiresExactTarget: action.requiresExactTarget, attention: action.attention,
                    episodeID: action.episodeID
                )
            }
            var evidence: [AttentionEvidence] = []
            let actionRange = action.time...(action.time + max(0.15, action.duration))
            if action.kind == "drag", let from = action.from, let to = action.to {
                let path = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -36, dy: -36)
                evidence.append(AttentionEvidence(source: .dragPath, timeRange: actionRange, bounds: path, confidence: 0.99, framingWeight: 1, persistence: 0.8, causalActionID: action.id))
            } else if let point = action.point, pointerActions.contains(action.kind) {
                let inferred = action.pointProvenance == "visual-inferred"
                evidence.append(AttentionEvidence(
                    source: inferred ? .visualPointer : .pointer,
                    timeRange: actionRange,
                    bounds: CGRect(x: point.x - 26, y: point.y - 26, width: 52, height: 52),
                    confidence: inferred ? 0.52 : 0.99,
                    framingWeight: inferred ? 0.22 : 0.9,
                    persistence: inferred ? 0.2 : 0.45,
                    causalActionID: action.id
                ))
            }
            if let bounds = action.semanticBounds {
                evidence.append(AttentionEvidence(source: .accessibility, timeRange: actionRange, bounds: bounds.insetBy(dx: -12, dy: -12), confidence: 0.99, framingWeight: 1.15, persistence: 0.95, causalActionID: action.id))
            }

            if action.kind != "scroll" {
                for observation in observationsByAction[action.id, default: []] {
                    let mapped = CGRect(
                        x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
                        y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
                        width: observation.normalizedBounds.width * contentRect.width,
                        height: observation.normalizedBounds.height * contentRect.height
                    ).intersection(CGRect(origin: .zero, size: size))
                    let areaFraction = mapped.area / (size.width * size.height)
                    // Timing remains sensitive to tiny changes, but only a
                    // substantial response is allowed to direct the camera.
                    guard !mapped.isNull, observation.changedFraction >= 0.0015,
                          areaFraction >= 0.008 else { continue }
                    // Existing content that merely changed position explains
                    // the transition but is not the subject of the reveal.
                    guard observation.kind != .translation else { continue }
                    let confidence = clamp(0.58 + observation.changedFraction * 18 + observation.magnitude * 0.8, 0.58, 0.96)
                    evidence.append(AttentionEvidence(
                        source: .visualResponse,
                        timeRange: observation.time...observation.time,
                        bounds: mapped.insetBy(dx: -16, dy: -16),
                        confidence: confidence,
                        framingWeight: clamp(areaFraction * 5 + observation.changedFraction * 16, 0.3, 1.1),
                        persistence: clamp(areaFraction * 3, 0.25, 1),
                        causalActionID: action.id
                    ))
                }
            }

            guard let first = evidence.first else { return action }
            let framing = evidence.filter { $0.framingWeight >= 0.25 }
            let bounds = (framing.isEmpty ? evidence : framing).dropFirst().reduce(first.bounds) { $0.union($1.bounds) }
                .insetBy(dx: -20, dy: -20).intersection(CGRect(origin: .zero, size: size))
            let visualArea = evidence.filter { $0.source == .visualResponse }.reduce(CGRect.null) { $0.union($1.bounds) }.area
            let behavior: CameraBehavior
            if visualArea / (size.width * size.height) >= 0.06 { behavior = .wideResponse }
            else if evidence.contains(where: { $0.source == .accessibility || $0.source == .dragPath }) { behavior = .region }
            else { behavior = .point }
            let confidence = evidence.map(\.confidence).max() ?? 0
            return DirectedAction(
                id: action.id, actionId: action.actionId, kind: action.kind, time: action.time, point: action.point,
                from: action.from, to: action.to, duration: action.duration,
                semanticBounds: action.semanticBounds, pointProvenance: action.pointProvenance,
                pointConfidence: action.pointConfidence,
                cursorAllowed: action.cursorAllowed,
                emphasis: action.emphasis, holdExtension: action.holdExtension,
                requiresExactTarget: action.requiresExactTarget,
                attention: AttentionDecision(
                    bounds: bounds, confidence: confidence, behavior: behavior, evidence: evidence
                ),
                episodeID: nil
            )
        }
    }

    private static func visualPointerFallback(
        observations: [VisualMotionObservation],
        actionTime: Double,
        size: CGSize,
        contentRect: CGRect
    ) -> CGPoint? {
        let candidates = observations.compactMap { observation -> (point: CGPoint, score: Double)? in
            guard observation.kind != .translation,
                  observation.changedFraction >= 0.0015 else { return nil }
            let mapped = CGRect(
                x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
                y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
                width: observation.normalizedBounds.width * contentRect.width,
                height: observation.normalizedBounds.height * contentRect.height
            ).intersection(CGRect(origin: .zero, size: size))
            guard !mapped.isNull else { return nil }
            let areaFraction = mapped.area / max(1, size.width * size.height)
            guard areaFraction >= 0.001, areaFraction <= 0.45 else { return nil }
            let score = abs(observation.time - actionTime) * 2.5
                + Double(areaFraction) * 2
                - observation.magnitude * 0.15
            return (CGPoint(x: mapped.midX, y: mapped.midY), score)
        }
        return candidates.min { $0.score < $1.score }?.point
    }

    private static func inferAttentionEpisodes(actions: [DirectedAction], retime: [RetimeSegment], size: CGSize) -> [DirectedAction] {
        var result = actions
        var nextEpisodeID = 0
        for openerIndex in result.indices {
            guard result[openerIndex].episodeID == nil,
                  result[openerIndex].attention?.behavior == .wideResponse,
                  let reveal = result[openerIndex].attention?.bounds else { continue }
            let openerOutput = outputTime(for: result[openerIndex].time, retime: retime)
            var contained: [Int] = []
            var locationless: [Int] = []
            for index in result.indices where index > openerIndex {
                let action = result[index]
                let editedGap = outputTime(for: action.time, retime: retime) - openerOutput
                if editedGap > 14 || action.kind == "scroll" { break }
                if let point = rawActionFocus(action) {
                    if reveal.insetBy(dx: -24, dy: -24).contains(point) { contained.append(index) }
                    else if !contained.isEmpty { break }
                } else if typingActions.contains(action.kind) {
                    locationless.append(index)
                }
            }
            // One coincidental point is insufficient. Episodes require a
            // sequence of work demonstrably contained by the revealed region.
            guard contained.count >= 2 else { continue }
            let lastContained = contained.last!
            let inherited = locationless.filter { $0 < lastContained }
            let members = [openerIndex] + inherited + contained
            let workingBounds = reveal.insetBy(dx: reveal.width * 0.07, dy: reveal.height * 0.08)
            let episodeID = nextEpisodeID; nextEpisodeID += 1
            for index in members {
                let action = result[index]
                let decision: AttentionDecision?
                if index == openerIndex { decision = action.attention }
                else if action.semanticBounds != nil || rawActionFocus(action) != nil {
                    // Episode membership supplies continuity and context; it
                    // must not erase an exact model target. Camera focus and
                    // scale continue to be derived from the action's own AX or
                    // pointer evidence while the shot remains grouped.
                    decision = action.attention
                } else {
                    decision = AttentionDecision(
                        bounds: workingBounds,
                        confidence: max(0.82, action.attention?.confidence ?? 0),
                        behavior: .region,
                        evidence: action.attention?.evidence ?? []
                    )
                }
                result[index] = DirectedAction(
                    id: action.id, actionId: action.actionId, kind: action.kind, time: action.time, point: action.point,
                    from: action.from, to: action.to, duration: action.duration,
                    semanticBounds: action.semanticBounds, pointProvenance: action.pointProvenance,
                    pointConfidence: action.pointConfidence,
                    cursorAllowed: action.cursorAllowed,
                    emphasis: action.emphasis, holdExtension: action.holdExtension,
                    requiresExactTarget: action.requiresExactTarget,
                    attention: decision, episodeID: episodeID
                )
            }
        }
        return result
    }

    private static func groupShots(
        _ actions: [DirectedAction],
        size: CGSize,
        recipe: DirectorRecipe,
        retime: [RetimeSegment],
        interactionStarts: [Int: Double]
    ) -> [Shot] {
        var shots: [Shot] = []
        let diagonal = hypot(size.width, size.height)
        for action in actions {
            let previousAction = shots.last?.actions.last
            let gap = previousAction.map {
                outputTime(for: action.time, retime: retime) - outputTime(for: $0.time, retime: retime)
            } ?? .infinity
            let distance: CGFloat
            if let a = previousAction.flatMap(actionFocus), let b = actionFocus(action) { distance = hypot(b.x - a.x, b.y - a.y) / diagonal }
            else { distance = 0 }
            let candidateScale = actionScale(action, size: size, recipe: recipe)
            let previousScale = previousAction.map { actionScale($0, size: size, recipe: recipe) } ?? candidateScale
            let viewportOverlap = previousAction.flatMap(actionFocus).flatMap { previousPoint in
                actionFocus(action).map { nextPoint in
                    cameraViewport(center: previousPoint, scale: previousScale, size: size)
                        .overlapRatio(with: cameraViewport(center: nextPoint, scale: candidateScale, size: size))
                }
            } ?? 0
            let clusterPoints = (shots.last?.actions.compactMap(actionFocus) ?? []) + [actionFocus(action)].compactMap { $0 }
            // A grouped shot must preserve its broadest attention decision.
            // A later point click cannot crop a large response out of view.
            let clusterScale = min(shots.last?.scale ?? candidateScale, candidateScale)
            let clusterFits = pointsFitOneViewport(clusterPoints, scale: clusterScale, size: size)
            let semantic = typingActions.contains(action.kind) || action.kind == "scroll"
            let samePlace = clusterFits && (viewportOverlap >= 0.4 || distance <= 0.24)
            let sameEpisode = previousAction?.episodeID != nil && previousAction?.episodeID == action.episodeID
            let joinsInEditedTime = sameEpisode || gap <= 1.6 || (samePlace && gap <= 3.8)
            if !shots.isEmpty && joinsInEditedTime && (samePlace || gap <= 0.75 || semantic) {
                shots[shots.count - 1].actions.append(action)
                shots[shots.count - 1].focusEnd = actionHoldEnd(action)
                shots[shots.count - 1].end = shots[shots.count - 1].focusEnd + 0.58
                shots[shots.count - 1].scale = min(shots[shots.count - 1].scale, actionScale(action, size: size, recipe: recipe))
            } else {
                let focusEnd = actionHoldEnd(action)
                // Cursor departure and camera movement are one choreography.
                // Let the pointer lead by a beat, while activation continues
                // to control the click spring and the camera's settle point.
                let activationLead = action.time - 0.42
                let cameraStart = interactionStarts[action.id].map { $0 + 0.10 }
                shots.append(Shot(id: shots.count, start: max(0, min(activationLead, cameraStart ?? activationLead)), focusStart: action.time + 0.12, focusEnd: focusEnd, end: focusEnd + 0.58, scale: actionScale(action, size: size, recipe: recipe), actions: [action]))
            }
        }
        return shots
    }

    private static func outputTime(for sourceTime: Double, retime: [RetimeSegment]) -> Double {
        if let segment = retime.first(where: { sourceTime >= $0.sourceStart && sourceTime <= $0.sourceEnd }) {
            return segment.outputStart + (sourceTime - segment.sourceStart) / segment.rate
        }
        if let next = retime.first(where: { $0.sourceStart > sourceTime }) { return next.outputStart }
        return retime.last.map { $0.outputStart + $0.outputDuration } ?? 0
    }

    private static func actionHoldEnd(_ action: DirectedAction) -> Double {
        if typingActions.contains(action.kind) { return action.time + action.duration / 2 + 0.55 + action.holdExtension }
        if action.kind == "drag" { return action.time + action.duration / 2 + 0.35 + action.holdExtension }
        if action.kind == "click" { return action.time + 0.55 + action.holdExtension }
        return action.time + 0.35 + action.holdExtension
    }

    fileprivate static func actionScale(_ action: DirectedAction, size: CGSize, recipe: DirectorRecipe) -> CGFloat {
        var scale: CGFloat?
        if let attention = action.attention {
            switch attention.behavior {
            case .point:
                scale = action.kind == "click" ? 1.44 : 1.34
            case .region:
                if action.episodeID != nil {
                    scale = clamp(min(size.width * 0.90 / max(1, attention.bounds.width), size.height * 0.82 / max(1, attention.bounds.height)), 1.30, 1.58)
                } else {
                    scale = clamp(min(size.width * 0.68 / max(1, attention.bounds.width), size.height * 0.62 / max(1, attention.bounds.height)), 1.16, 1.62)
                }
            case .wideResponse:
                // A response region should fill the shot, not merely fit into
                // a conservative safe area. The attention bounds already
                // include context and padding.
                let coverage = attention.bounds.area / (size.width * size.height)
                scale = coverage >= 0.72 ? 1 : clamp(min(size.width * 0.94 / max(1, attention.bounds.width), size.height * 0.86 / max(1, attention.bounds.height)), 1.12, 1.48)
            }
        }
        if scale == nil, typingActions.contains(action.kind) {
            if let bounds = action.semanticBounds { scale = clamp((size.width * 0.62) / bounds.width, 1.25, 1.62) }
            else { scale = action.point == nil ? 1 : 1.5 }
        } else if action.kind == "scroll" { scale = 1 }
        if scale == nil, action.kind == "drag", let from = action.from, let to = action.to {
            let span = hypot(to.x - from.x, to.y - from.y) / hypot(size.width, size.height)
            scale = lerp(1.48, 1.24, clamp(span / 0.55, 0, 1))
        }
        let value = scale ?? (action.kind == "click" ? 1.44 : 1.34)
        let emphasis = action.emphasis == "reduced" ? 0.6 : action.emphasis == "strong" ? 1.25 : 1
        return 1 + (value - 1) * CGFloat(recipe.zoomStrength) * emphasis
    }

    private static func buildAnchors(
        _ actions: [DirectedAction],
        phases: [Int: InteractionPhases]
    ) -> [PointerAnchor] {
        var result: [PointerAnchor] = []
        for action in actions where pointerActions.contains(action.kind) && action.rendersCursor {
            if action.kind == "drag", let from = action.from, let to = action.to {
                result.append(PointerAnchor(actionID: action.id, time: action.time - action.duration / 2, point: from, kind: "drag-start"))
                result.append(PointerAnchor(actionID: action.id, time: action.time + action.duration / 2, point: to, kind: "drag-end"))
            } else if let point = action.point {
                result.append(PointerAnchor(
                    actionID: action.id,
                    time: phases[action.id]?.pointerArrival ?? action.time,
                    point: point,
                    kind: action.kind
                ))
            }
        }
        return result.sorted { $0.time < $1.time }
    }

    private static func buildPointerTravel(
        anchors: [PointerAnchor],
        size: CGSize,
        style: CursorPathStyle
    ) -> [PointerTravelInterval] {
        let initial = CGPoint(x: size.width * 0.16, y: size.height * 0.16)
        return anchors.enumerated().map { index, next in
            if index == 0 {
                return PointerTravelInterval(
                    actionID: next.actionID,
                    start: max(0, next.time - 1.15),
                    end: next.time,
                    from: initial,
                    to: next.point,
                    curve: pointerCurve(
                        from: initial, to: next.point, actionID: next.actionID,
                        index: index, size: size, style: style
                    )
                )
            }
            let previous = anchors[index - 1]
            if previous.kind == "drag-start" && next.kind == "drag-end" {
                return PointerTravelInterval(
                    actionID: next.actionID,
                    start: previous.time,
                    end: next.time,
                    from: previous.point,
                    to: next.point,
                    curve: 0
                )
            }
            let distance = hypot(next.point.x - previous.point.x, next.point.y - previous.point.y)
            let duration = clamp(0.36 + distance / 1_050, 0.42, 1.05)
            let end = next.time - 0.08
            return PointerTravelInterval(
                actionID: next.actionID,
                start: max(previous.time + 0.1, end - duration),
                end: end,
                from: previous.point,
                to: next.point,
                curve: pointerCurve(
                    from: previous.point, to: next.point, actionID: next.actionID,
                    index: index, size: size, style: style
                )
            )
        }
    }

    private static func buildRetime(
        _ actions: [DirectedAction],
        duration: Double,
        rate: Double,
        reduceWaiting: Bool,
        waitingTime: Double,
        motionRanges: [ClosedRange<Double>],
        interactionStarts: [Int: Double]
    ) -> [RetimeSegment] {
        guard duration > 0 else { return [] }
        var ranges = actions.map {
            let approachStart = interactionStarts[$0.id].map { $0 - 0.05 } ?? ($0.time - 0.78)
            return (
                max(0, min($0.time - 0.78, approachStart)),
                min(duration, actionHoldEnd($0))
            )
        }
        ranges += [(0, min(1.4, duration)), (max(0, duration - 1.1), duration)]
        ranges.sort { $0.0 < $1.0 }
        var merged: [(Double, Double)] = []
        for range in ranges {
            if let last = merged.last, range.0 <= last.1 + 0.2 { merged[merged.count - 1].1 = max(last.1, range.1) }
            else { merged.append(range) }
        }
        var raw: [(Double, Double, Double)] = []
        func appendStaticGap(_ start: Double, _ end: Double) {
            guard end > start else { return }
            let retained = min(end - start, waitingTime)
            guard retained > 0 else { return }
            let leading = retained / 2
            let trailing = retained - leading
            if leading > 0 { raw.append((start, start + leading, 1)) }
            if trailing > 0 { raw.append((end - trailing, end, 1)) }
        }
        func appendWaitingGap(_ start: Double, _ end: Double) {
            guard end > start else { return }
            guard reduceWaiting else {
                raw.append((start, end, rate))
                return
            }
            var cursor = start
            for motion in motionRanges where motion.upperBound > start && motion.lowerBound < end {
                let motionStart = max(start, motion.lowerBound)
                let motionEnd = min(end, motion.upperBound)
                appendStaticGap(cursor, motionStart)
                if motionEnd > motionStart { raw.append((motionStart, motionEnd, rate)) }
                cursor = max(cursor, motionEnd)
            }
            appendStaticGap(cursor, end)
        }
        var cursor = 0.0
        for range in merged {
            appendWaitingGap(cursor, range.0)
            raw.append((range.0, range.1, 1))
            cursor = range.1
        }
        appendWaitingGap(cursor, duration)
        var outputStart = 0.0
        return raw.filter { $0.1 - $0.0 > 0.001 }.map {
            let segment = RetimeSegment(sourceStart: $0.0, sourceEnd: $0.1, rate: $0.2, outputStart: outputStart)
            outputStart += segment.outputDuration
            return segment
        }
    }
}

private let typingActions: Set<String> = ["type_text", "set_value", "select_text", "press_key"]
private let pointerActions: Set<String> = ["click", "drag"]

private func cameraViewport(center: CGPoint, scale: CGFloat, size: CGSize) -> CGRect {
    let width = size.width / scale
    let height = size.height / scale
    let clampedCenter = CGPoint(
        x: clamp(center.x, width / 2, size.width - width / 2),
        y: clamp(center.y, height / 2, size.height - height / 2)
    )
    return CGRect(x: clampedCenter.x - width / 2, y: clampedCenter.y - height / 2, width: width, height: height)
}

private func pointsFitOneViewport(_ points: [CGPoint], scale: CGFloat, size: CGSize) -> Bool {
    guard let first = points.first else { return true }
    let bounds = points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
        partial.union(CGRect(origin: point, size: .zero))
    }
    return bounds.width <= size.width / scale * 0.62 && bounds.height <= size.height / scale * 0.62
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func overlapRatio(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull else { return 0 }
        let smallerArea = min(width * height, other.width * other.height)
        guard smallerArea > 0 else { return 0 }
        return intersection.width * intersection.height / smallerArea
    }
}

private func actionFocus(_ action: DirectedAction) -> CGPoint? {
    if action.emphasis == "none" { return nil }
    if let bounds = action.attention?.bounds { return CGPoint(x: bounds.midX, y: bounds.midY) }
    if action.kind == "drag", let from = action.from, let to = action.to { return CGPoint(x: midpoint(from.x, to.x), y: midpoint(from.y, to.y)) }
    if action.pointProvenance == "context-inferred" { return nil }
    return action.point ?? action.to ?? action.from
}

private func rawActionFocus(_ action: DirectedAction) -> CGPoint? {
    if action.kind == "drag", let from = action.from, let to = action.to { return CGPoint(x: midpoint(from.x, to.x), y: midpoint(from.y, to.y)) }
    if action.pointProvenance == "context-inferred" { return nil }
    return action.point ?? action.to ?? action.from
}

private func pointerCurve(
    from: CGPoint,
    to: CGPoint,
    actionID: Int,
    index: Int,
    size: CGSize,
    style: CursorPathStyle
) -> CGFloat {
    guard style == .natural else { return 0 }
    let dx = to.x - from.x, dy = to.y - from.y
    let length = hypot(dx, dy)
    guard length >= 24 else { return 0 }
    let amplitude = min(32, length * 0.045)
    let normal = CGPoint(x: -dy / length, y: dx / length)
    let preferredSign: CGFloat = (actionID + index).isMultiple(of: 2) ? 1 : -1
    func clearance(_ sign: CGFloat) -> CGFloat {
        let midpoint = CGPoint(
            x: (from.x + to.x) / 2 + normal.x * amplitude * sign,
            y: (from.y + to.y) / 2 + normal.y * amplitude * sign
        )
        return min(midpoint.x, size.width - midpoint.x, midpoint.y, size.height - midpoint.y)
    }
    let sign = clearance(preferredSign) >= clearance(-preferredSign) ? preferredSign : -preferredSign
    return amplitude * sign
}

private func travel(
    _ from: CGPoint,
    _ to: CGPoint,
    _ time: Double,
    _ start: Double,
    _ end: Double,
    _ curve: CGFloat
) -> CGPoint {
    let duration = max(0.001, end - start)
    let progress = CGFloat(cinematicMotionProgress((time - start) / duration))
    guard curve != 0 else {
        return CGPoint(x: lerp(from.x, to.x, progress), y: lerp(from.y, to.y, progress))
    }
    let dx = to.x - from.x, dy = to.y - from.y
    let length = max(1, hypot(dx, dy))
    let normal = CGPoint(x: -dy / length, y: dx / length)
    let control1 = CGPoint(
        x: from.x + dx * 0.20 + normal.x * curve,
        y: from.y + dy * 0.20 + normal.y * curve
    )
    let control2 = CGPoint(
        x: from.x + dx * 0.72 + normal.x * curve * 0.55,
        y: from.y + dy * 0.72 + normal.y * curve * 0.55
    )
    let inverse = 1 - progress
    return CGPoint(
        x: inverse * inverse * inverse * from.x
            + 3 * inverse * inverse * progress * control1.x
            + 3 * inverse * progress * progress * control2.x
            + progress * progress * progress * to.x,
        y: inverse * inverse * inverse * from.y
            + 3 * inverse * inverse * progress * control1.y
            + 3 * inverse * progress * progress * control2.y
            + progress * progress * progress * to.y
    )
}

private func midpoint(_ a: Double, _ b: Double) -> Double { (a + b) / 2 }
private func midpoint(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + b) / 2 }

/// A minimum-jerk timing curve shared by cursor and camera travel. It has zero
/// velocity and acceleration at both endpoints, so delayed camera follow reads
/// as one coordinated movement instead of two unrelated linear animations.
public func cinematicMotionProgress(_ raw: Double) -> Double {
    let x = clamp(raw, 0, 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
}

/// An emphasized camera curve with a brief eased departure and a deliberately
/// longer visual settle. Fast zooms cover their distance early enough to frame
/// the action, then decelerate across enough output frames to avoid a hard stop.
public func cinematicCameraProgress(_ raw: Double) -> Double {
    let x = clamp(raw, 0, 1)
    guard x > 0, x < 1 else { return x }

    // Cubic Bezier (0.40, 0.00, 0.15, 1.00). Solve the parametric x axis so
    // callers provide ordinary timeline progress rather than Bezier parameter t.
    var lower = 0.0
    var upper = 1.0
    var parameter = x
    for _ in 0..<18 {
        parameter = (lower + upper) / 2
        let inverse = 1 - parameter
        let bezierX = 3 * inverse * inverse * parameter * 0.40
            + 3 * inverse * parameter * parameter * 0.15
            + parameter * parameter * parameter
        if bezierX < x {
            lower = parameter
        } else {
            upper = parameter
        }
    }
    let inverse = 1 - parameter
    return 3 * inverse * parameter * parameter + parameter * parameter * parameter
}

private func smootherstep(_ start: Double, _ end: Double, _ value: Double) -> Double {
    guard end > start else { return value >= end ? 1 : 0 }
    return cinematicMotionProgress((value - start) / (end - start))
}
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func clamp<T: Comparable>(_ value: T, _ minimum: T, _ maximum: T) -> T { min(maximum, max(minimum, value)) }
