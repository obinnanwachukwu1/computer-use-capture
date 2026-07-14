import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import Foundation
import ImageIO
import Metal
import NativeDirector

struct Options {
    let source: URL
    let timeline: URL
    let output: URL
    let wallpaper: URL
    let cursor: URL
    let fps: Int32
    let samples: Int
    let shutter: CGFloat
    let reduceWaiting: Bool
    let waitingTime: Double
    let planOnly: Bool
    let directorDebug: Bool
    let cursorPath: CursorPathStyle?
    let cursorTiltStrength: Double?

    static func parse() throws -> Options {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            throw Failure("usage: native-compose <source.mov> <timeline.json> <output.mp4> [--output-scale 1|2] [--fps 60] [--samples 8] [--shutter 0.55] [--cursor-path natural|straight] [--cursor-tilt-strength 0...1.5] [--keep-waiting] [--waiting-time milliseconds] [--plan-only] [--director-debug]")
        }
        func value(_ flag: String, _ fallback: String) -> String {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        func optionalValue(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        let cursorPath: CursorPathStyle?
        if let rawPath = optionalValue("--cursor-path") {
            guard let parsed = CursorPathStyle(rawValue: rawPath) else {
                throw Failure("--cursor-path must be natural or straight")
            }
            cursorPath = parsed
        } else {
            cursorPath = nil
        }
        let cursorTiltStrength = optionalValue("--cursor-tilt-strength").flatMap(Double.init)
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return Options(
            source: URL(fileURLWithPath: args[0], relativeTo: cwd).standardizedFileURL,
            timeline: URL(fileURLWithPath: args[1], relativeTo: cwd).standardizedFileURL,
            output: URL(fileURLWithPath: args[2], relativeTo: cwd).standardizedFileURL,
            wallpaper: URL(fileURLWithPath: value("--wallpaper", "artifacts/tahoe-light.jpg"), relativeTo: cwd).standardizedFileURL,
            cursor: URL(fileURLWithPath: value("--cursor", "artifacts/macos-arrow.png"), relativeTo: cwd).standardizedFileURL,
            fps: max(30, Int32(value("--fps", "60")) ?? 60),
            samples: max(1, Int(value("--samples", "8")) ?? 8),
            shutter: min(1, max(0, CGFloat(Double(value("--shutter", "0.55")) ?? 0.55))),
            // Editorial waiting cuts are the product default. Keep the old
            // affirmative flag compatible while providing an explicit opt-out.
            reduceWaiting: !args.contains("--keep-waiting"),
            waitingTime: max(0, (Double(value("--waiting-time", "100")) ?? 100) / 1000),
            planOnly: args.contains("--plan-only"),
            directorDebug: args.contains("--director-debug"),
            cursorPath: cursorPath,
            cursorTiltStrength: cursorTiltStrength
        )
    }
}

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct DecodedFrame {
    let time: Double
    let buffer: CVPixelBuffer
}

struct CursorMetadata: Decodable {
    let logicalWidth: CGFloat
    let logicalHeight: CGFloat
    let hotspotX: CGFloat
    let hotspotY: CGFloat
}

let logicalOutputSize = CGSize(width: 1440, height: 1050)
let renderScale: CGFloat = {
    let arguments = CommandLine.arguments
    let cliValue = arguments.firstIndex(of: "--output-scale").flatMap { index in
        index + 1 < arguments.count ? Double(arguments[index + 1]) : nil
    }
    let environmentValue = ProcessInfo.processInfo.environment["AGENTRECORDER_OUTPUT_SCALE"].flatMap(Double.init)
    return CGFloat(min(2, max(1, cliValue ?? environmentValue ?? 1)))
}()
let width = Int(logicalOutputSize.width * renderScale)
let height = Int(logicalOutputSize.height * renderScale)
let outputSize = CGSize(width: width, height: height)
// Keep enough real canvas around the captured window for edge actions to be
// reframed into the viewer's lower-middle attention area. At 0.92, controls
// near a window edge could not move inward without exposing space beyond the
// composition. This ratio also matches the default Screen Studio-like balance
// of window, shadow, and wallpaper more closely.
let contentScale: CGFloat = 0.84

do {
    let options = try Options.parse()
    try await render(options)
    print("NATIVE_COMPOSITION_COMPLETE output=\(options.output.path)")
} catch {
    FileHandle.standardError.write(Data("native-compose: \(error)\n".utf8))
    exit(1)
}

func render(_ options: Options) async throws {
    let device = try require(MTLCreateSystemDefaultDevice(), "Metal is unavailable")
    let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let timeline = try JSONDecoder().decode(Timeline.self, from: Data(contentsOf: options.timeline))
    let asset = AVURLAsset(url: options.source)
    let sourceDuration = try await asset.load(.duration).seconds
    let track = try require(try await asset.loadTracks(withMediaType: .video).first, "source has no video track")
    let naturalSize = try await track.load(.naturalSize)
    guard naturalSize.width > 0, naturalSize.height > 0 else { throw Failure("source has invalid dimensions") }
    let contentRect = aspectFittedContentRect(
        canvas: logicalOutputSize,
        sourceAspect: naturalSize.width / naturalSize.height,
        scale: contentScale
    )
    let timingProbes = interactionTimingProbes(timeline: timeline)
    let relocationActionIDs = Set(timeline.events.enumerated().compactMap { id, event in
        event.semanticTarget?.viewportRelocation?.kind == "target-entered-viewport" ? id : nil
    })
    emitProgress(phase: "analyzing", percent: 0)
    // The same decoded-frame prepass serves two independent consumers:
    // waiting reduction and the default attention director.
    let motionAnalysis = try MotionAnalyzer.analyze(
        asset: asset,
        track: track,
        context: context,
        sourceDuration: sourceDuration,
        actionTimes: timeline.events.compactMap(\.time),
        timingProbes: timingProbes,
        relocationActionIDs: relocationActionIDs
    )
    if options.reduceWaiting {
        print("motion analysis samples=\(motionAnalysis.sampledFrames) moving=\(motionAnalysis.motionFrames) ranges=\(motionAnalysis.ranges.count)")
        let rangeSummary = motionAnalysis.ranges.map {
            "\(String(format: "%.2f", $0.lowerBound))-\(String(format: "%.2f", $0.upperBound))"
        }.joined(separator: ",")
        print("motion ranges=\(rangeSummary)")
    }
    let composition = NativeComposition(
        timeline: timeline,
        size: logicalOutputSize,
        contentRect: contentRect,
        sourceDuration: sourceDuration,
        reduceWaiting: options.reduceWaiting,
        waitingTime: options.waitingTime,
        motionRanges: motionAnalysis.ranges,
        motionObservations: motionAnalysis.observations,
        interactionPhases: motionAnalysis.interactionPhases,
        cursorPathOverride: options.cursorPath,
        cursorTiltStrengthOverride: options.cursorTiltStrength
    )
    if options.directorDebug {
        try writeDirectorDebugReport(composition: composition, motionAnalysis: motionAnalysis, output: options.output)
    }
    guard composition.outputDuration > 0 else { throw Failure("director produced an empty composition") }
    print("native director actions=\(composition.actions.count) shots=\(composition.shots.count) source=\(String(format: "%.2f", sourceDuration))s output=\(String(format: "%.2f", composition.outputDuration))s waiting=\(options.reduceWaiting ? "cut" : "compressed")")
    let pointerActions = composition.actions.filter { ["click", "drag"].contains($0.kind) }
    let factualPointers = pointerActions.filter { $0.rendersCursor && isFactualCursorTarget($0) }
    let inferredRenderedPointers = pointerActions.filter { $0.rendersCursor && !isFactualCursorTarget($0) }
    let inferredPointers = pointerActions.filter { ($0.point != nil || $0.to != nil) && !$0.rendersCursor }
    let missingPointers = pointerActions.filter { $0.point == nil && $0.to == nil }
    print("native pointer coverage=\(factualPointers.count + inferredRenderedPointers.count)/\(pointerActions.count) factual=\(factualPointers.count) inferredRendered=\(inferredRenderedPointers.count) inferredOmitted=\(inferredPointers.count) unresolved=\(missingPointers.map(\.actionId))")
    try writeCompositionReport(composition: composition, output: options.output, state: "planned")
    let attentionSummary = composition.actions.compactMap { action in
        action.attention.map { "\(action.kind)@\(String(format: "%.1f", action.time)):\($0.behavior.rawValue)[\($0.evidence.map(\.source.rawValue).joined(separator: "+"))]" }
    }.joined(separator: " | ")
    print("native attention=\(attentionSummary)")
    let timingSummary = composition.actions.compactMap { action in
        composition.interactionPhases[action.id].map { phase in
            let orderedAfter = phase.preActivationActivityEnd.map { " orderedAfter=\(String(format: "%.3f", $0 + 0.05))" } ?? ""
            return "\(action.kind)#\(action.id) raw=\(String(format: "%.3f", phase.rawEstimate)) arrival=\(String(format: "%.3f", phase.pointerArrival)) activation=\(String(format: "%.3f", phase.activation))\(orderedAfter) source=\(phase.source)"
        }
    }.joined(separator: " | ")
    if !timingSummary.isEmpty { print("native timing=\(timingSummary)") }
    if options.planOnly {
        for action in composition.actions where action.attention != nil {
            let evidence = action.attention!.evidence.map {
                let b = $0.bounds
                return "\($0.source.rawValue){x:\(Int(b.minX)),y:\(Int(b.minY)),w:\(Int(b.width)),h:\(Int(b.height)),weight:\(String(format: "%.2f", $0.framingWeight))}"
            }.joined(separator: " ")
            let b = action.attention!.bounds
            print("attention detail id=\(action.id) \(action.kind)@\(String(format: "%.2f", action.time)) behavior=\(action.attention!.behavior.rawValue) decision={x:\(Int(b.minX)),y:\(Int(b.minY)),w:\(Int(b.width)),h:\(Int(b.height))} \(evidence)")
        }
    }
    let shotSummary = composition.shots.map { shot in
        "scale\(String(format: "%.2f", shot.scale)):" + shot.actions.map {
            "\($0.kind)@\(String(format: "%.1f", $0.time))/out\(String(format: "%.1f", composition.outputTime(atSourceTime: $0.time)))"
        }.joined(separator: "+")
    }.joined(separator: " | ")
    print("native shots=\(shotSummary)")
    if options.planOnly {
        let totalFrames = Int(ceil(composition.outputDuration * Double(options.fps)))
        let cameraSamples = try precomputeCameraSamples(
            composition: composition, frameCount: totalFrames, fps: options.fps, samples: options.samples
        )
        try writeCameraTrajectoryAudit(
            composition: composition, cameras: cameraSamples, frameCount: totalFrames,
            fps: options.fps, samples: options.samples, output: options.output
        )
        return
    }

    let reader = try AVAssetReader(asset: asset)
    let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferMetalCompatibilityKey as String: true
    ])
    readerOutput.alwaysCopiesSampleData = false
    guard reader.canAdd(readerOutput) else { throw Failure("cannot add video reader output") }
    reader.add(readerOutput)

    let temporaryOutput = options.output.deletingLastPathComponent()
        .appendingPathComponent(".\(options.output.lastPathComponent).partial-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: temporaryOutput) }
    let writer = try AVAssetWriter(outputURL: temporaryOutput, fileType: .mp4)
    let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: width,
        AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: Int(18_000_000 * renderScale * renderScale),
            AVVideoExpectedSourceFrameRateKey: options.fps,
            AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
    ])
    writerInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: writerInput, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: width,
        kCVPixelBufferHeightKey as String: height,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]
    ])
    guard writer.canAdd(writerInput) else { throw Failure("cannot add video writer input") }
    writer.add(writerInput)
    guard reader.startReading(), writer.startWriting() else {
        throw Failure(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "could not start media pipeline")
    }
    writer.startSession(atSourceTime: .zero)

    let wallpaper = try loadImage(options.wallpaper)
    let cursor = try loadImage(options.cursor)
    let cursorMetadata = try loadCursorMetadata(options.cursor)
    let totalFrames = Int(ceil(composition.outputDuration * Double(options.fps)))
    emitProgress(phase: "rendering", percent: 0)
    let cameraSamples = try precomputeCameraSamples(composition: composition, frameCount: totalFrames, fps: options.fps, samples: options.samples)
    try writeCameraTrajectoryAudit(
        composition: composition,
        cameras: cameraSamples,
        frameCount: totalFrames,
        fps: options.fps,
        samples: options.samples,
        output: options.output
    )
    var nextSample = readerOutput.copyNextSampleBuffer()
    var decodedFrames: [DecodedFrame] = []
    var motionBlurredFrames = 0

    for frame in 0..<totalFrames {
        let outputTime = Double(frame) / Double(options.fps)
        let sampleSlots = temporalSampleSlots(
            composition: composition, frame: frame, fps: options.fps,
            samples: options.samples, cameras: cameraSamples
        )
        if sampleSlots.count > 1 { motionBlurredFrames += 1 }
        let sampleSourceTimes = sampleSlots.map { sample -> Double in
            let index = frame * options.samples + sample
            let sampleOutputTime = (Double(index) + 0.5) / (Double(options.fps) * Double(options.samples))
            return composition.sourceTime(atOutputTime: sampleOutputTime)
        }
        let minimumSourceTime = sampleSourceTimes.min() ?? composition.sourceTime(atOutputTime: outputTime)
        let maximumSourceTime = sampleSourceTimes.max() ?? minimumSourceTime
        while let sample = nextSample, CMSampleBufferGetPresentationTimeStamp(sample).seconds <= maximumSourceTime + 1 / 30 {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                decodedFrames.append(DecodedFrame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer: buffer))
            }
            nextSample = readerOutput.copyNextSampleBuffer()
        }
        if decodedFrames.isEmpty, let sample = nextSample, let buffer = CMSampleBufferGetImageBuffer(sample) {
            decodedFrames.append(DecodedFrame(time: CMSampleBufferGetPresentationTimeStamp(sample).seconds, buffer: buffer))
        }
        guard !decodedFrames.isEmpty else {
            throw Failure("source frame unavailable at \(minimumSourceTime)s")
        }
        while !writerInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
        guard let pool = adaptor.pixelBufferPool else { throw Failure("writer pixel buffer pool unavailable") }
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess, let outputBuffer else {
            throw Failure("could not allocate output frame")
        }

        let image = composeMotionBlurredFrame(
            sourceFrames: decodedFrames,
            wallpaper: wallpaper,
            cursor: cursor,
            cursorMetadata: cursorMetadata,
            contentRect: contentRect,
            composition: composition,
            frame: frame,
            fps: options.fps,
            samples: options.samples,
            sampleSlots: sampleSlots,
            shutter: options.shutter,
            cameras: cameraSamples,
            debug: options.directorDebug,
            motionObservations: motionAnalysis.observations
        )
        context.render(image, to: outputBuffer, bounds: CGRect(origin: .zero, size: outputSize), colorSpace: colorSpace)
        guard adaptor.append(outputBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: options.fps)) else {
            throw Failure(writer.error?.localizedDescription ?? "writer rejected frame \(frame)")
        }
        if frame % Int(options.fps) == 0 {
            print("native frame \(frame)/\(totalFrames)")
            emitProgress(phase: "rendering", percent: Double(frame) / Double(max(1, totalFrames)) * 100)
        }
        if let lastBefore = decodedFrames.lastIndex(where: { $0.time <= minimumSourceTime }), lastBefore > 1 {
            decodedFrames.removeFirst(lastBefore - 1)
        }
    }

    writerInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure(writer.error?.localizedDescription ?? "writer failed") }
    reader.cancelReading()
    try? FileManager.default.removeItem(at: options.output)
    try FileManager.default.moveItem(at: temporaryOutput, to: options.output)
    try writeCompositionReport(composition: composition, output: options.output, state: "completed")
    emitProgress(phase: "completed", percent: 100)
    print("temporal blur frames=\(motionBlurredFrames)/\(totalFrames)")
}

func emitProgress(phase: String, percent: Double) {
    let payload: [String: Any] = ["phase": phase, "percent": min(100, max(0, percent))]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else { return }
    print("AGENTRECORDER_PROGRESS \(String(decoding: data, as: UTF8.self))")
}

func writeCompositionReport(composition: NativeComposition, output: URL, state: String) throws {
    let pointerActions = composition.actions.filter { ["click", "drag"].contains($0.kind) }
    let report: [String: Any] = [
        "version": 1,
        "state": state,
        "output": output.path,
        "durationSeconds": composition.outputDuration,
        "pointerRendering": [
            "factual": pointerActions.filter { $0.rendersCursor && isFactualCursorTarget($0) }.count,
            "inferredRendered": pointerActions.filter { $0.rendersCursor && !isFactualCursorTarget($0) }.count,
            "inferredOmitted": pointerActions.filter {
                !$0.rendersCursor && $0.pointProvenance == "visual-inferred"
            }.count,
            "omittedUnresolved": pointerActions.filter {
                !$0.rendersCursor && $0.pointProvenance != "visual-inferred"
            }.count
        ],
        "actions": composition.actions.map { action in
            [
                "actionId": action.actionId,
                "kind": action.kind,
                "provenance": action.pointProvenance ?? "unresolved",
                "confidence": action.pointConfidence,
                "renderedCursor": action.rendersCursor
            ] as [String: Any]
        }
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("composition.json")
    try data.write(to: url, options: .atomic)
}

func isFactualCursorTarget(_ action: DirectedAction) -> Bool {
    switch action.pointProvenance {
    case "direct", "ax-identity", "ax-focus": true
    case "ax-structural": action.pointConfidence >= 0.75
    default: false
    }
}

func interactionTimingProbes(timeline: Timeline) -> [InteractionTimingProbe] {
    guard let captureStartText = timeline.capture?.startedAt,
          let captureStart = parseISO8601(captureStartText) else { return [] }
    return timeline.events.enumerated().compactMap { id, event in
        guard (event.action ?? event.method) == "click",
              let rawEstimate = event.time,
              let startText = event.timing?.toolCallStartedAt,
              let endText = event.timing?.toolCallEndedAt,
              let start = parseISO8601(startText),
              let end = parseISO8601(endText),
              let target = normalizedTimingTarget(event)
        else { return nil }
        return InteractionTimingProbe(
            actionID: id,
            rawEstimate: rawEstimate,
            toolStart: start.timeIntervalSince(captureStart),
            toolEnd: end.timeIntervalSince(captureStart),
            finalActionInToolCall: event.timing?.actionIsFinalSkyCall ?? false,
            normalizedTarget: target
        )
    }
}

func normalizedTimingTarget(_ event: Timeline.Event) -> CGRect? {
    if let bounds = event.semanticTarget?.bounds,
       let x = bounds.xNorm, let y = bounds.yNorm,
       let width = bounds.widthNorm, let height = bounds.heightNorm,
       [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 {
        return CGRect(x: x, y: y, width: width, height: height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    if let x = event.coordinates?.xNorm, let y = event.coordinates?.yNorm,
       x.isFinite, y.isFinite {
        return CGRect(x: x - 0.04, y: y - 0.04, width: 0.08, height: 0.08)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    return nil
}

func parseISO8601(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

func temporalSampleSlots(
    composition: NativeComposition,
    frame: Int,
    fps: Int32,
    samples: Int,
    cameras: [CameraState]
) -> [Int] {
    guard samples > 1 else { return [0] }
    let firstIndex = min(cameras.count - 1, frame * samples)
    let lastIndex = min(cameras.count - 1, frame * samples + samples - 1)
    let firstCamera = cameras[firstIndex], lastCamera = cameras[lastIndex]
    let firstTime = (Double(firstIndex) + 0.5) / (Double(fps) * Double(samples))
    let lastTime = (Double(lastIndex) + 0.5) / (Double(fps) * Double(samples))
    let firstCursor = composition.cursor(at: composition.sourceTime(atOutputTime: firstTime))
    let lastCursor = composition.cursor(at: composition.sourceTime(atOutputTime: lastTime))
    let cameraMoves = hypot(lastCamera.x - firstCamera.x, lastCamera.y - firstCamera.y) > 0.02
        || abs(lastCamera.logScale - firstCamera.logScale) > 0.00002
    let cursorMoves = hypot(lastCursor.point.x - firstCursor.point.x, lastCursor.point.y - firstCursor.point.y) > 0.02
        || abs(lastCursor.scale - firstCursor.scale) > 0.0002
        || abs(lastCursor.rotation - firstCursor.rotation) > 0.0002
    return cameraMoves || cursorMoves ? Array(0..<samples) : [samples / 2]
}

private struct CameraMove {
    let label: String
    let start: Double
    let end: Double
    let from: CameraState
    let to: CameraState
}

private let cursorLeadFraction = 0.10

func precomputeCameraSamples(composition: NativeComposition, frameCount: Int, fps: Int32, samples: Int) throws -> [CameraState] {
    let count = frameCount * samples
    let rate = Double(fps) * Double(samples)
    let base = CameraState(x: logicalOutputSize.width / 2, y: logicalOutputSize.height / 2, logScale: 0)
    let moves = buildCameraMoves(composition: composition, base: base)
    var result: [CameraState] = []
    var emergencyVisibilityCorrections = 0
    var emergencyCorrectionIndices: [Int] = []
    result.reserveCapacity(count)
    for index in 0..<count {
        let outputTime = (Double(index) + 0.5) / rate
        let sourceTime = composition.sourceTime(atOutputTime: outputTime)
        var state = cameraState(at: outputTime, moves: moves, base: base)
        let unconstrained = state
        state = composition.enforcingFactualActionVisibility(state, at: sourceTime)
        let correctedX = abs(state.x - unconstrained.x) > 0.0001
        let correctedY = abs(state.y - unconstrained.y) > 0.0001
        let correctedScale = abs(state.logScale - unconstrained.logScale) > 0.0001
        if correctedX || correctedY || correctedScale {
            emergencyVisibilityCorrections += 1
            emergencyCorrectionIndices.append(index)
        }
        result.append(unconstrained)
    }
    print("native camera emergency-visibility-corrections=\(emergencyVisibilityCorrections)/\(count)")
    if !emergencyCorrectionIndices.isEmpty {
        var ranges: [ClosedRange<Int>] = []
        var start = emergencyCorrectionIndices[0]
        var previous = start
        for index in emergencyCorrectionIndices.dropFirst() {
            if index > previous + 1 {
                ranges.append(start...previous)
                start = index
            }
            previous = index
        }
        ranges.append(start...previous)
        let summary = ranges.map {
            String(format: "%.2f-%.2f", Double($0.lowerBound) / rate, Double($0.upperBound) / rate)
        }.joined(separator: ",")
        print("native camera emergency-ranges-out=\(summary)")
        // A valid recording must never fail because a heuristic camera plan
        // cropped factual input. Widen to the guaranteed-visible base pose for
        // the offending span and blend over a 350 ms shoulder so the recovery
        // remains a continuous camera move rather than an emergency jump.
        let shoulder = max(1, Int(rate * 0.35))
        for range in ranges {
            let expandedStart = max(0, range.lowerBound - shoulder)
            let expandedEnd = min(count - 1, range.upperBound + shoulder)
            for index in expandedStart...expandedEnd {
                let strength: CGFloat
                if range.contains(index) { strength = 1 }
                else if index < range.lowerBound {
                    strength = CGFloat(smoothRecovery(Double(index - expandedStart) / Double(max(1, range.lowerBound - expandedStart))))
                } else {
                    strength = CGFloat(smoothRecovery(Double(expandedEnd - index) / Double(max(1, expandedEnd - range.upperBound))))
                }
                let original = result[index]
                result[index] = CameraState(
                    x: original.x + (base.x - original.x) * strength,
                    y: original.y + (base.y - original.y) * strength,
                    logScale: original.logScale + (base.logScale - original.logScale) * strength
                )
            }
        }
        print("native camera recovery=base-pose-smoothed ranges=\(ranges.count)")
    }
    let moveSummary = moves.map {
        "\($0.label){\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end)),scale:\(String(format: "%.2f", exp($0.from.logScale)))->\(String(format: "%.2f", exp($0.to.logScale)))}"
    }.joined(separator: " | ")
    print("native camera moves=\(moveSummary)")
    return result
}

private func smoothRecovery(_ value: Double) -> Double {
    let t = min(1, max(0, value))
    return t * t * t * (t * (t * 6 - 15) + 10)
}

private func buildCameraMoves(composition: NativeComposition, base: CameraState) -> [CameraMove] {
    let orderedActions = composition.actions.filter { $0.attention != nil }.sorted { $0.time < $1.time }
    let shotByAction = Dictionary(uniqueKeysWithValues: composition.shots.flatMap { shot in
        shot.actions.map { ($0.id, shot.id) }
    })
    var moves: [CameraMove] = []
    var pose = base
    var previousAction: DirectedAction?
    var previousActionOutput = 0.0

    func appendMove(label: String, start proposedStart: Double, end proposedEnd: Double, to target: CameraState) {
        let isNoOp = abs(target.x - pose.x) < 0.001
            && abs(target.y - pose.y) < 0.001
            && abs(target.logScale - pose.logScale) < 0.00001
        if isNoOp { return }
        let lastEnd = moves.last?.end ?? 0
        let start = max(lastEnd, proposedStart)
        let end = max(start + 0.18, proposedEnd)
        moves.append(CameraMove(label: label, start: start, end: end, from: pose, to: target))
        pose = target
    }

    for action in orderedActions {
        guard let settled = composition.settledCamera(forActionID: action.id) else { continue }
        let actionOutput = composition.outputTime(atSourceTime: action.time)
        let sameShot = previousAction.flatMap { shotByAction[$0.id] } == shotByAction[action.id]
        let trip = composition.pointerTrip(forActionID: action.id)

        if let previousAction, !sameShot,
           (actionOutput - previousActionOutput > 2.0 || action.requiresEstablishingTransition) {
            if action.requiresEstablishingTransition, let trip {
                let tripStart = composition.outputTime(atSourceTime: trip.start)
                let end = tripStart - 0.08
                let earliest = previousActionOutput + (previousAction.kind == "click" ? 0.28 : 0.38)
                let start = max(earliest, end - 0.56)
                appendMove(label: "viewport-relocation-zoom-out", start: start, end: end, to: base)
            } else {
                let nominalStart = previousActionOutput + (previousAction.kind == "click" ? 0.52 : 0.68)
                let start = max(nominalStart, (moves.last?.end ?? nominalStart) + 0.60)
                appendMove(label: "shot-zoom-out", start: start, end: start + 0.62, to: base)
            }
        }

        if let trip {
            let tripStart = composition.outputTime(atSourceTime: trip.start)
            let projectedStart = projectPointThroughCamera(trip.from, camera: pose, outputSize: logicalOutputSize)
            let safe = CGRect(
                x: logicalOutputSize.width * 0.075, y: logicalOutputSize.height * 0.11,
                width: logicalOutputSize.width * 0.85, height: logicalOutputSize.height * 0.78
            )
            let tripEnd = composition.outputTime(atSourceTime: trip.end)
            let cameraDelay = max(0, tripEnd - tripStart) * cursorLeadFraction
            let delayedStart = tripStart + cameraDelay
            let delayedEnd = tripEnd + cameraDelay
            let proposedDirect = CameraMove(
                label: "pointer-preflight", start: delayedStart, end: delayedEnd, from: pose, to: settled
            )
            let directKeepsPointerVisible = stride(from: 0.0, through: 1.0, by: 1.0 / 40.0).allSatisfy { phase in
                let time = tripStart + (delayedEnd - tripStart) * phase
                let camera = cameraState(at: time, moves: [proposedDirect], base: pose)
                let sourceTime = composition.sourceTime(atOutputTime: time)
                let cursor = composition.cursor(at: sourceTime).point
                return safe.contains(projectPointThroughCamera(cursor, camera: camera, outputSize: logicalOutputSize))
            }
            if action.requiresEstablishingTransition {
                // Computer Use may scroll an offscreen semantic target into
                // view before activation. Establish the relocated viewport
                // first, show the factual click in that wide context, and
                // only then focus the new region. Pointer travel is now
                // causally fenced behind relocation settlement, so the AX
                // post-action snapshot delay must not be applied a second
                // time here; doing so would miss the action's visual response.
                let focusStart = max(delayedEnd, actionOutput + 0.08)
                appendMove(
                    label: "action-\(action.id)-relocation-focus",
                    start: focusStart,
                    end: focusStart + 0.62,
                    to: settled
                )
            } else if !safe.contains(projectedStart) || !directKeepsPointerVisible {
                let route = CGRect(
                    x: min(trip.from.x, trip.to.x), y: min(trip.from.y, trip.to.y),
                    width: abs(trip.to.x - trip.from.x), height: abs(trip.to.y - trip.from.y)
                ).insetBy(dx: -40, dy: -40).intersection(CGRect(origin: .zero, size: logicalOutputSize))
                let routePose = composition.cameraPose(
                    containing: route, maximumScale: min(exp(pose.logScale), exp(settled.logScale))
                )
                // If a tight semantic focus leaves the idle cursor outside the
                // next route, the camera must briefly establish that departure
                // point before the cursor becomes factual input again. Keep
                // this exceptional lead proportional and close to the trip;
                // ordinary visible departures continue to let the cursor lead.
                let tripDuration = max(0, tripEnd - tripStart)
                let routeStart = tripStart - min(0.18, tripDuration * 0.22)
                let routeEnd = delayedStart + max(0, delayedEnd - delayedStart) * 0.55
                appendMove(
                    label: "action-\(action.id)-route-fit",
                    start: routeStart, end: routeEnd, to: routePose
                )
                // Let the pointer establish intent first, then follow from the
                // stable route viewport to the attention model's click target.
                // The lead is proportional to this trip's edited duration.
                appendMove(
                    label: "action-\(action.id)-delayed-focus",
                    start: delayedStart,
                    end: delayedEnd,
                    to: settled
                )
            } else {
                appendMove(
                    label: "action-\(action.id)-direct",
                    start: delayedStart, end: delayedEnd, to: settled
                )
            }
        } else {
            appendMove(
                label: "action-\(action.id)-direct",
                start: actionOutput - 0.78, end: actionOutput + 0.10, to: settled
            )
        }
        previousAction = action
        previousActionOutput = actionOutput
    }
    if previousAction != nil {
        let nominalStart = previousActionOutput + 0.62
        let start = max(nominalStart, (moves.last?.end ?? nominalStart) + 0.60)
        appendMove(
            label: "final-zoom-out",
            start: start,
            end: start + 0.62,
            to: base
        )
    }
    return moves
}

private func cameraState(at time: Double, moves: [CameraMove], base: CameraState) -> CameraState {
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

func writeCameraTrajectoryAudit(
    composition: NativeComposition,
    cameras: [CameraState],
    frameCount: Int,
    fps: Int32,
    samples: Int,
    output: URL
) throws {
    let frameCameras = (0..<frameCount).map { frame in
        cameras[min(cameras.count - 1, frame * samples + samples / 2)]
    }
    func directionReversals(_ values: [CGFloat], threshold: CGFloat) -> Int {
        let signs = zip(values, values.dropFirst()).compactMap { left, right -> Int? in
            let delta = right - left
            guard abs(delta) >= threshold else { return nil }
            return delta > 0 ? 1 : -1
        }
        return zip(signs, signs.dropFirst()).filter { $0 != $1 }.count
    }
    func metrics(start: Int, end: Int) -> [String: Any] {
        let slice = Array(frameCameras[start...end])
        let points = slice.map { CGPoint(x: $0.x, y: $0.y) }
        let translations = zip(points, points.dropFirst()).map { hypot($1.x - $0.x, $1.y - $0.y) }
        let pathLength = translations.reduce(0, +)
        let displacement = hypot(points.last!.x - points.first!.x, points.last!.y - points.first!.y)
        let scales = slice.map { exp($0.logScale) }
        let scaleTravel = zip(scales, scales.dropFirst()).map { abs($1 - $0) }.reduce(0, +)
        let scaleDisplacement = abs(scales.last! - scales.first!)
        let lineDX = points.last!.x - points.first!.x
        let lineDY = points.last!.y - points.first!.y
        let lineLength = max(0.001, hypot(lineDX, lineDY))
        let lineConstant = points.last!.x * points.first!.y - points.last!.y * points.first!.x
        let maxLineDeviation = points.map { point in
            let numerator = abs(lineDY * point.x - lineDX * point.y + lineConstant)
            return numerator / lineLength
        }.max() ?? 0
        return [
            "start": Double(start) / Double(fps),
            "end": Double(end) / Double(fps),
            "translation": ["dx": lineDX, "dy": lineDY],
            "scale": ["start": scales.first!, "end": scales.last!, "minimum": scales.min()!, "maximum": scales.max()!],
            "xReversals": directionReversals(slice.map(\.x), threshold: 0.04),
            "yReversals": directionReversals(slice.map(\.y), threshold: 0.04),
            "scaleReversals": directionReversals(scales, threshold: 0.0002),
            "pathEfficiency": pathLength > 0.01 ? displacement / pathLength : 1,
            "scaleEfficiency": scaleTravel > 0.0001 ? scaleDisplacement / scaleTravel : 1,
            "maxLineDeviation": maxLineDeviation
        ]
    }

    let windows: [[String: Any]] = composition.actions.map { action in
        let actionOutput = composition.outputTime(atSourceTime: action.time)
        let start = max(0, Int((actionOutput - 1.5) * Double(fps)))
        let end = min(frameCameras.count - 1, Int((actionOutput + 1.0) * Double(fps)))
        var result = metrics(start: start, end: end)
        result["actionID"] = action.id
        result["kind"] = action.kind
        result["actionTime"] = actionOutput
        return result
    }
    let base = CameraState(x: logicalOutputSize.width / 2, y: logicalOutputSize.height / 2, logScale: 0)
    let moveWindows: [[String: Any]] = buildCameraMoves(composition: composition, base: base).map { move in
        let start = max(0, min(frameCameras.count - 1, Int(move.start * Double(fps))))
        let end = max(start, min(frameCameras.count - 1, Int(move.end * Double(fps))))
        var result = metrics(start: start, end: end)
        result["label"] = move.label
        return result
    }
    let report: [String: Any] = ["version": 1, "windows": windows, "moves": moveWindows]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("camera-audit.json")
    try data.write(to: url, options: .atomic)
    print("native camera audit=\(url.path)")
}

func composeMotionBlurredFrame(
    sourceFrames: [DecodedFrame],
    wallpaper: CIImage,
    cursor: CIImage,
    cursorMetadata: CursorMetadata,
    contentRect: CGRect,
    composition: NativeComposition,
    frame: Int,
    fps: Int32,
    samples: Int,
    sampleSlots: [Int],
    shutter: CGFloat,
    cameras: [CameraState],
    debug: Bool,
    motionObservations: [VisualMotionObservation]
) -> CIImage {
    var accumulated: CIImage?
    let centerIndex = min(cameras.count - 1, frame * samples + samples / 2)
    let centerCamera = cameras[centerIndex]
    for (blendIndex, sample) in sampleSlots.enumerated() {
        let index = min(cameras.count - 1, frame * samples + sample)
        let outputTime = (Double(index) + 0.5) / (Double(fps) * Double(samples))
        let sourceTime = composition.sourceTime(atOutputTime: outputTime)
        let source = interpolatedSourceImage(at: sourceTime, frames: sourceFrames)
        let cursorState = composition.cursor(at: sourceTime)
        let sampled = cameras[index]
        let camera = CameraState(
            x: centerCamera.x + (sampled.x - centerCamera.x) * shutter,
            y: centerCamera.y + (sampled.y - centerCamera.y) * shutter,
            logScale: centerCamera.logScale + (sampled.logScale - centerCamera.logScale) * shutter
        )
        let base = composeBase(source: source, wallpaper: wallpaper, contentRect: contentRect)
        let scale = exp(camera.logScale)
        let transform = CGAffineTransform(translationX: outputSize.width / 2, y: outputSize.height / 2)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -camera.x * renderScale, y: -camera.y * renderScale)
        let transformed = base.transformed(by: transform).cropped(to: CGRect(origin: .zero, size: outputSize))
        let withCursor = overlayCursor(
            cursor,
            over: transformed,
            state: cursorState,
            camera: camera,
            cameraScale: scale,
            cursorScale: composition.cursorScale,
            metadata: cursorMetadata
        )
        if let previous = accumulated {
            accumulated = withCursor.applyingFilter("CIMix", parameters: [
                kCIInputBackgroundImageKey: previous,
                kCIInputAmountKey: CGFloat(1) / CGFloat(blendIndex + 1)
            ])
        } else { accumulated = withCursor }
    }
    var result = accumulated!.cropped(to: CGRect(origin: .zero, size: outputSize))
    if debug {
        let sourceTime = composition.sourceTime(atOutputTime: (Double(frame) + 0.5) / Double(fps))
        result = directorDebugOverlay(
            over: result,
            composition: composition,
            sourceTime: sourceTime,
            camera: centerCamera,
            observations: motionObservations,
            contentRect: contentRect
        )
    }
    return result
}

func directorDebugOverlay(
    over background: CIImage,
    composition: NativeComposition,
    sourceTime: Double,
    camera: CameraState,
    observations: [VisualMotionObservation],
    contentRect: CGRect
) -> CIImage {
    var result = background
    func projected(_ bounds: CGRect) -> CGRect {
        let a = projectPointThroughCamera(CGPoint(x: bounds.minX, y: bounds.minY), camera: camera, outputSize: logicalOutputSize)
        let b = projectPointThroughCamera(CGPoint(x: bounds.maxX, y: bounds.maxY), camera: camera, outputSize: logicalOutputSize)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .scaled(by: renderScale)
    }
    for observation in observations where abs(observation.time - sourceTime) <= 0.9 {
        let bounds = CGRect(
            x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
            width: observation.normalizedBounds.width * contentRect.width,
            height: observation.normalizedBounds.height * contentRect.height
        )
        let color = observation.kind == .translation
            ? CIColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.9)
            : CIColor(red: 1, green: 0.18, blue: 0.32, alpha: 0.9)
        result = drawOutline(projected(bounds), color: color, width: 3 * renderScale, over: result)
    }
    if let action = composition.actions.min(by: { abs($0.time - sourceTime) < abs($1.time - sourceTime) }),
       abs(action.time - sourceTime) <= 2.0,
       let attention = action.attention {
        for evidence in attention.evidence {
            let color: CIColor
            switch evidence.source {
            case .pointer: color = CIColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.9)
            case .visualPointer: color = CIColor(red: 1, green: 0.48, blue: 0.08, alpha: 0.8)
            case .dragPath: color = CIColor(red: 1, green: 0.55, blue: 0.1, alpha: 0.9)
            case .accessibility: color = CIColor(red: 0.25, green: 1, blue: 0.45, alpha: 0.9)
            case .visualResponse: color = CIColor(red: 1, green: 0.18, blue: 0.65, alpha: 0.9)
            }
            result = drawOutline(projected(evidence.bounds), color: color, width: 2 * renderScale, over: result)
        }
        result = drawOutline(projected(attention.bounds), color: CIColor(red: 0.1, green: 0.95, blue: 1, alpha: 1), width: 5 * renderScale, over: result)
    }
    return result.cropped(to: CGRect(origin: .zero, size: outputSize))
}

func drawOutline(_ rect: CGRect, color: CIColor, width: CGFloat, over background: CIImage) -> CIImage {
    let clipped = rect.intersection(CGRect(origin: .zero, size: outputSize))
    guard !clipped.isNull, clipped.width > width * 2, clipped.height > width * 2 else { return background }
    let strips = [
        CGRect(x: clipped.minX, y: clipped.minY, width: clipped.width, height: width),
        CGRect(x: clipped.minX, y: clipped.maxY - width, width: clipped.width, height: width),
        CGRect(x: clipped.minX, y: clipped.minY, width: width, height: clipped.height),
        CGRect(x: clipped.maxX - width, y: clipped.minY, width: width, height: clipped.height)
    ]
    return strips.reduce(background) { image, strip in
        CIImage(color: color).cropped(to: strip).composited(over: image)
    }
}

func writeDirectorDebugReport(composition: NativeComposition, motionAnalysis: MotionAnalysis, output: URL) throws {
    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    let actions: [[String: Any]] = composition.actions.map { action in
        var item: [String: Any] = [
            "id": action.id,
            "actionId": action.actionId,
            "kind": action.kind,
            "sourceTime": action.time,
            "outputTime": composition.outputTime(atSourceTime: action.time),
            "renderedCursor": action.rendersCursor
        ]
        if let episodeID = action.episodeID { item["episodeID"] = episodeID }
        if let point = action.point {
            item["pointer"] = [
                "x": point.x,
                "y": point.y,
                "provenance": action.pointProvenance ?? "unknown",
                "confidence": action.pointConfidence,
                "factual": action.rendersCursor
            ] as [String: Any]
        }
        if let phase = composition.interactionPhases[action.id] {
            var timing: [String: Any] = [
                "rawEstimate": phase.rawEstimate,
                "toolStart": phase.toolStart,
                "toolEnd": phase.toolEnd,
                "pointerArrival": phase.pointerArrival,
                "activation": phase.activation,
                "source": phase.source
            ]
            if let responseOnset = phase.responseOnset { timing["responseOnset"] = responseOnset }
            if let end = phase.preActivationActivityEnd { timing["preActivationActivityEnd"] = end }
            if let threshold = phase.activityThreshold { timing["activityThreshold"] = threshold }
            item["timing"] = timing
        }
        if let camera = composition.settledCamera(forActionID: action.id) {
            item["camera"] = ["centerX": camera.x, "centerY": camera.y, "scale": exp(camera.logScale)]
        }
        if let attention = action.attention {
            item["attention"] = [
                "behavior": attention.behavior.rawValue,
                "confidence": attention.confidence,
                "bounds": rect(attention.bounds),
                "evidence": attention.evidence.map { evidence in
                    [
                        "source": evidence.source.rawValue,
                        "bounds": rect(evidence.bounds),
                        "confidence": evidence.confidence,
                        "framingWeight": evidence.framingWeight,
                        "persistence": evidence.persistence
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        return item
    }
    let report: [String: Any] = [
        "version": 1,
        "output": ["width": Int(outputSize.width), "height": Int(outputSize.height), "duration": composition.outputDuration],
        "legend": ["attention": "cyan", "appearance": "red", "translation": "blue", "pointer": "yellow", "visualPointer": "orange", "accessibility": "green", "visualResponse": "magenta"],
        "actions": actions,
        "shots": composition.shots.map { shot in
            ["id": shot.id, "start": shot.start, "end": shot.end, "baseScale": shot.scale, "actionIDs": shot.actions.map(\.id)] as [String: Any]
        },
        "motion": [
            "coordinateSpace": "source-window-normalized-top-left",
            "sampledFrames": motionAnalysis.sampledFrames,
            "movingFrames": motionAnalysis.motionFrames,
            "components": motionAnalysis.observations.map { observation in
                ["time": observation.time, "kind": observation.kind.rawValue, "bounds": rect(observation.normalizedBounds), "changedFraction": observation.changedFraction, "magnitude": observation.magnitude] as [String: Any]
            }
        ] as [String: Any]
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("director.json")
    try data.write(to: url, options: .atomic)
    print("native director debug report=\(url.path)")
}

func interpolatedSourceImage(at time: Double, frames: [DecodedFrame]) -> CIImage {
    guard let afterIndex = frames.firstIndex(where: { $0.time >= time }) else {
        return CIImage(cvPixelBuffer: frames.last!.buffer)
    }
    guard afterIndex > 0 else { return CIImage(cvPixelBuffer: frames[afterIndex].buffer) }
    let before = frames[afterIndex - 1]
    let after = frames[afterIndex]
    let span = after.time - before.time
    guard span > 0.000_001 else { return CIImage(cvPixelBuffer: after.buffer) }
    let amount = CGFloat(min(1, max(0, (time - before.time) / span)))
    return CIImage(cvPixelBuffer: after.buffer).applyingFilter("CIMix", parameters: [
        kCIInputBackgroundImageKey: CIImage(cvPixelBuffer: before.buffer),
        kCIInputAmountKey: amount
    ])
}

func composeBase(source: CIImage, wallpaper: CIImage, contentRect: CGRect) -> CIImage {
    let canvas = CGRect(origin: .zero, size: outputSize)
    let renderContentRect = contentRect.scaled(by: renderScale)
    var result = aspectFill(wallpaper, into: canvas)
    let rounded = CIFilter.roundedRectangleGenerator()
    rounded.extent = renderContentRect
    rounded.radius = Float(23 * renderScale)
    rounded.color = .white
    let mask = rounded.outputImage!.cropped(to: canvas)
    let ambientShadow = shadowLayer(mask: mask, canvas: canvas, radius: 108 * renderScale, offsetY: -28 * renderScale, opacity: 0.64)
    let contactShadow = shadowLayer(mask: mask, canvas: canvas, radius: 28 * renderScale, offsetY: -9 * renderScale, opacity: 0.48)
    result = contactShadow.composited(over: ambientShadow.composited(over: result))

    let sourceScale = renderContentRect.width / source.extent.width
    let placedSource = source.transformed(by: CGAffineTransform(scaleX: sourceScale, y: sourceScale))
        .transformed(by: CGAffineTransform(translationX: renderContentRect.minX, y: renderContentRect.minY))
    result = placedSource.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: result,
        kCIInputMaskImageKey: mask
    ])

    return result.cropped(to: canvas)
}

func shadowLayer(mask: CIImage, canvas: CGRect, radius: CGFloat, offsetY: CGFloat, opacity: CGFloat) -> CIImage {
    let blurredMask = mask
        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
        .transformed(by: CGAffineTransform(translationX: 0, y: offsetY))
        .cropped(to: canvas)
    let color = CIImage(color: CIColor(red: 0.01, green: 0.02, blue: 0.04, alpha: opacity)).cropped(to: canvas)
    let clear = CIImage(color: .clear).cropped(to: canvas)
    return color.applyingFilter("CIBlendWithAlphaMask", parameters: [
        kCIInputBackgroundImageKey: clear,
        kCIInputMaskImageKey: blurredMask
    ]).cropped(to: canvas)
}

func overlayCursor(
    _ cursor: CIImage,
    over background: CIImage,
    state: CursorState,
    camera: CameraState,
    cameraScale: CGFloat,
    cursorScale: CGFloat,
    metadata: CursorMetadata
) -> CIImage {
    let logicalWidth = metadata.logicalWidth
    let logicalHeight = metadata.logicalHeight
    let hotspotFromTop = CGPoint(x: metadata.hotspotX, y: metadata.hotspotY)
    let visualScale = cursorScale * state.scale * cameraScale * renderScale
    let logicalCursorWidth = logicalWidth * visualScale
    let imageScale = logicalCursorWidth / cursor.extent.width
    // NSCursor metadata is top-left based; Core Image is bottom-left based.
    let hotspot = coreImageCursorHotspot(
        logicalSize: CGSize(width: logicalWidth, height: logicalHeight),
        hotspotFromTopLeft: hotspotFromTop,
        scale: visualScale
    )
    let logicalProjected = projectPointThroughCamera(state.point, camera: camera, outputSize: logicalOutputSize)
    let projected = CGPoint(x: logicalProjected.x * renderScale, y: logicalProjected.y * renderScale)
    let placedCursor = cursor
        .transformed(by: CGAffineTransform(scaleX: imageScale, y: imageScale))
        .transformed(by: CGAffineTransform(translationX: -hotspot.x, y: -hotspot.y))
        .transformed(by: CGAffineTransform(rotationAngle: state.rotation))
        .transformed(by: CGAffineTransform(translationX: projected.x, y: projected.y))
    return placedCursor.composited(over: background).cropped(to: CGRect(origin: .zero, size: outputSize))
}

func loadCursorMetadata(_ cursorURL: URL) throws -> CursorMetadata {
    let metadataURL = URL(fileURLWithPath: cursorURL.path + ".json")
    return try JSONDecoder().decode(CursorMetadata.self, from: Data(contentsOf: metadataURL))
}

func aspectFill(_ image: CIImage, into rect: CGRect) -> CIImage {
    let scale = max(rect.width / image.extent.width, rect.height / image.extent.height)
    let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    return scaled.transformed(by: CGAffineTransform(translationX: rect.midX - scaled.extent.midX, y: rect.midY - scaled.extent.midY)).cropped(to: rect)
}

func loadImage(_ url: URL) throws -> CIImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Failure("could not load image at \(url.path)")
    }
    return CIImage(cgImage: image)
}

private extension CGRect {
    func scaled(by scale: CGFloat) -> CGRect {
        CGRect(x: minX * scale, y: minY * scale, width: width * scale, height: height * scale)
    }
}

func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw Failure(message) }
    return value
}
