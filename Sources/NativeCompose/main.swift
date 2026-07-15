import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreMedia
import CaptureTruth
import Darwin
import Foundation
import ImageIO
import Metal
import NativeDirector

// MCP and CLI callers consume progress a line at a time. stdio becomes block
// buffered when it is piped, which previously made a healthy render look
// frozen until process exit.
setlinebuf(stdout)
setlinebuf(stderr)

struct Options {
    enum CameraPlanner { case normal, experimental }
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
    let cameraPlanner: CameraPlanner
    let experimentalMotionObservations: URL?
    let experimentalScenePlan: URL?
    let profile: URL?
    let useAnalysisCache: Bool

    static func parse() throws -> Options {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            throw Failure("usage: native-compose <source.mov> <timeline.json> <output.mp4> [--experimental-camera-planner] [--output-scale 1|2] [--fps 60] [--samples 8] [--shutter 0.55] [--cursor-path natural|straight] [--cursor-tilt-strength 0...1.5] [--keep-waiting] [--waiting-time milliseconds] [--experimental-motion-observations study.json | --experimental-scene-plan scene-plan.json] [--plan-only] [--director-debug] [--profile [profile.json]] [--no-analysis-cache]")
        }
        func value(_ flag: String, _ fallback: String) -> String {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return fallback }
            return args[index + 1]
        }
        func optionalValue(_ flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if args.contains("--camera-planner")
            || ProcessInfo.processInfo.environment["AGENTRECORDER_CAMERA_PLANNER"] != nil {
            throw Failure("--camera-planner was removed; normal is the default and the replacement is available only through --experimental-camera-planner")
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
        let cameraPlanner: CameraPlanner = args.contains("--experimental-camera-planner")
            || ProcessInfo.processInfo.environment["AGENTRECORDER_EXPERIMENTAL_CAMERA_PLANNER"] == "1"
            ? .experimental : .normal
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let experimentalMotionObservations = optionalValue("--experimental-motion-observations").map {
            URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL
        }
        let experimentalScenePlan = optionalValue("--experimental-scene-plan").map {
            URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL
        }
        guard experimentalMotionObservations == nil || experimentalScenePlan == nil else {
            throw Failure("use either --experimental-motion-observations or --experimental-scene-plan, not both")
        }
        let output = URL(fileURLWithPath: args[2], relativeTo: cwd).standardizedFileURL
        let profile: URL?
        if let index = args.firstIndex(of: "--profile") {
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                profile = URL(fileURLWithPath: args[index + 1], relativeTo: cwd).standardizedFileURL
            } else {
                profile = URL(fileURLWithPath: output.path + ".profile.json")
            }
        } else {
            profile = nil
        }
        return Options(
            source: URL(fileURLWithPath: args[0], relativeTo: cwd).standardizedFileURL,
            timeline: URL(fileURLWithPath: args[1], relativeTo: cwd).standardizedFileURL,
            output: output,
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
            cursorTiltStrength: cursorTiltStrength,
            cameraPlanner: cameraPlanner,
            experimentalMotionObservations: experimentalMotionObservations,
            experimentalScenePlan: experimentalScenePlan,
            profile: profile,
            useAnalysisCache: !args.contains("--no-analysis-cache")
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

private struct CaptureTruthContext {
    let verifiedIdleRanges: [ClosedRange<Double>]?
    let provenIdleActionIDs: Set<Int>
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
    let profiler = PipelineProfiler()
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
    profiler.complete("setup")
    emitProgress(phase: "analyzing", percent: 0)
    // The same decoded-frame prepass serves two independent consumers:
    // waiting reduction and the default attention director.
    let fallbackActionTimes = Dictionary(uniqueKeysWithValues: timeline.events.enumerated().compactMap { id, event in
        event.time.map { (id, $0) }
    })
    let collectMotionFields = options.directorDebug || options.experimentalMotionObservations != nil
    let cachedMotionAnalysis = try MotionAnalysisCache.resolve(
        source: options.source,
        fallbackActionTimes: fallbackActionTimes,
        timingProbes: timingProbes,
        relocationActionIDs: relocationActionIDs,
        enabled: options.useAnalysisCache,
        collectMotionFields: collectMotionFields
    ) {
        try MotionAnalyzer.analyze(
            asset: asset,
            track: track,
            context: context,
            sourceDuration: sourceDuration,
            fallbackActionTimes: fallbackActionTimes,
            timingProbes: timingProbes,
            relocationActionIDs: relocationActionIDs,
            collectMotionFields: collectMotionFields
        )
    }
    let rawMotionAnalysis = cachedMotionAnalysis.analysis
    profiler.complete("motionAnalysis")
    let motionAnalysis: MotionAnalysis
    if let scenePlanURL = options.experimentalScenePlan {
        let scenePlan = try JSONDecoder().decode(
            GlobalScenePlanFile.self,
            from: Data(contentsOf: scenePlanURL)
        )
        guard scenePlan.version == 1 else {
            throw Failure("experimental scene plan must use version 1")
        }
        guard scenePlan.coordinateSpace == "source-window-normalized-top-left" else {
            throw Failure("experimental scene plan must use source-window-normalized-top-left coordinates")
        }
        motionAnalysis = MotionAnalysis(
            ranges: rawMotionAnalysis.ranges,
            sampledFrames: rawMotionAnalysis.sampledFrames,
            motionFrames: rawMotionAnalysis.motionFrames,
            observations: applyingGlobalScenePlan(scenePlan, to: rawMotionAnalysis.observations),
            interactionPhases: rawMotionAnalysis.interactionPhases,
            motionFields: rawMotionAnalysis.motionFields
        )
        print("native experimental-scene-plan=\(scenePlan.sceneEpisodes.count) model=\(scenePlan.model) source=\(scenePlanURL.path)")
    } else if let overrideURL = options.experimentalMotionObservations {
        let overrideFile = try JSONDecoder().decode(
            MotionObservationOverrideFile.self,
            from: Data(contentsOf: overrideURL)
        )
        guard overrideFile.version == 1 else {
            throw Failure("experimental motion observations must use version 1")
        }
        guard overrideFile.coordinateSpace == "source-window-normalized-top-left" else {
            throw Failure("experimental motion observations must use source-window-normalized-top-left coordinates")
        }
        motionAnalysis = MotionAnalysis(
            ranges: rawMotionAnalysis.ranges,
            sampledFrames: rawMotionAnalysis.sampledFrames,
            motionFrames: rawMotionAnalysis.motionFrames,
            observations: applyingMotionObservationOverrides(
                overrideFile.observationOverrides,
                to: rawMotionAnalysis.observations
            ),
            interactionPhases: rawMotionAnalysis.interactionPhases,
            motionFields: rawMotionAnalysis.motionFields
        )
        print("native experimental-motion-observations=\(overrideFile.observationOverrides.count) source=\(overrideURL.path)")
    } else {
        motionAnalysis = rawMotionAnalysis
    }
    let captureTruth = loadCaptureTruth(
        timeline: timeline,
        timelineURL: options.timeline,
        sourceDuration: sourceDuration
    )
    profiler.complete("analysisOverridesAndCaptureTruth")
    if options.reduceWaiting {
        print("motion analysis samples=\(motionAnalysis.sampledFrames) moving=\(motionAnalysis.motionFrames) ranges=\(motionAnalysis.ranges.count)")
        let rangeSummary = motionAnalysis.ranges.map {
            "\(String(format: "%.2f", $0.lowerBound))-\(String(format: "%.2f", $0.upperBound))"
        }.joined(separator: ",")
        print("motion ranges=\(rangeSummary)")
    }
    let baseComposition = NativeComposition(
        timeline: timeline,
        size: logicalOutputSize,
        contentRect: contentRect,
        sourceDuration: sourceDuration,
        reduceWaiting: options.reduceWaiting,
        waitingTime: options.waitingTime,
        motionRanges: motionAnalysis.ranges,
        motionObservations: motionAnalysis.observations,
        interactionPhases: motionAnalysis.interactionPhases,
        verifiedIdleRanges: captureTruth.verifiedIdleRanges,
        provenIdleActionIDs: captureTruth.provenIdleActionIDs,
        cursorPathOverride: options.cursorPath,
        cursorTiltStrengthOverride: options.cursorTiltStrength
    )
    profiler.complete("compositionConstruction")
    let baseCamera = CameraState(
        x: logicalOutputSize.width / 2,
        y: logicalOutputSize.height / 2,
        logScale: 0
    )
    let planned = makeCameraPlan(
        composition: baseComposition,
        base: baseCamera,
        planner: options.cameraPlanner,
        contentRect: contentRect,
        sourceDuration: sourceDuration,
        motionAnalysis: motionAnalysis,
        captureTruth: captureTruth,
        reduceWaiting: options.reduceWaiting,
        waitingTime: options.waitingTime
    )
    profiler.complete("cameraPlanning")
    let composition = planned.composition
    if let first = composition.retime.first, first.sourceStart > 0.000_001 {
        let sourceStart = String(format: "%.3f", first.sourceStart)
        let firstPointer = composition.firstPointerMovementTime
            .map { String(format: "%.3f", $0) } ?? "none"
        print("native leading-idle-trim source-start=\(sourceStart) first-pointer=\(firstPointer)")
    }
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
    let cameraPlan = planned.camera
    print("native camera planner=\(cameraPlan.diagnostics.plannerVersion) feasible=\(cameraPlan.diagnostics.feasible) moves=\(cameraPlan.moves.count) tracks=\(cameraPlan.tracks.count)")
    if let global = planned.global {
        print("native production graph hypotheses=\(global.hypothesisCount) beam=\(global.beamWidth) decisions=\(global.decisions.count)")
        let summary = global.decisions.map {
            let scale = String(format: "%.2f", exp($0.pose.logScale))
            return "a\($0.actionID){timing:\($0.timingSource),obs:\($0.observationIDs.sorted()),scale:\(scale)}"
        }.joined(separator: " | ")
        print("native production decisions=\(summary)")
        try writeGlobalProductionPlanReport(global, output: options.output)
    }
    if let experimental = planned.experimental {
        print("native experimental subjects=\(experimental.subjects.subjects.count) shots=\(experimental.schedule.shots.count) factualSamples=\(experimental.factualSamples) trackingSamples=\(experimental.trackingSamples)")
        try writeExperimentalProductionPlanReport(experimental, output: options.output)
    }
    profiler.complete("planReporting")
    if options.planOnly {
        let totalFrames = Int(ceil(composition.outputDuration * Double(options.fps)))
        let sampledPlan = try precomputeCameraSamples(
            composition: composition, plan: cameraPlan, base: baseCamera,
            frameCount: totalFrames, fps: options.fps, samples: options.samples
        )
        try writeCameraTrajectoryAudit(
            composition: composition, plan: cameraPlan, sampledPlan: sampledPlan,
            frameCount: totalFrames, fps: options.fps, samples: options.samples,
            output: options.output
        )
        profiler.complete("cameraSamplingAndAudit")
        if let profile = options.profile {
            try profiler.write(
                to: profile, mode: "plan-only", planner: cameraPlan.diagnostics.plannerVersion,
                source: options.source, timeline: options.timeline, output: options.output,
                sourceDuration: sourceDuration, outputDuration: composition.outputDuration,
                sourceSize: naturalSize, outputSize: outputSize, fps: options.fps,
                samples: options.samples, analysisCacheHit: cachedMotionAnalysis.hit,
                analyzedFrames: motionAnalysis.sampledFrames,
                motionFrames: motionAnalysis.motionFrames, actionCount: composition.actions.count,
                shotCount: composition.shots.count, outputFrameCount: totalFrames
            )
        }
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
    profiler.complete("mediaPipelineSetup")
    emitProgress(phase: "rendering", percent: 0)
    let sampledPlan = try precomputeCameraSamples(
        composition: composition, plan: cameraPlan, base: baseCamera,
        frameCount: totalFrames, fps: options.fps, samples: options.samples
    )
    let cameraSamples = sampledPlan.states
    try writeCameraTrajectoryAudit(
        composition: composition, plan: cameraPlan, sampledPlan: sampledPlan,
        frameCount: totalFrames,
        fps: options.fps,
        samples: options.samples,
        output: options.output
    )
    profiler.complete("cameraSamplingAndAudit")
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

    profiler.complete("decodeCompositeAndEncode")

    writerInput.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else { throw Failure(writer.error?.localizedDescription ?? "writer failed") }
    reader.cancelReading()
    try? FileManager.default.removeItem(at: options.output)
    try FileManager.default.moveItem(at: temporaryOutput, to: options.output)
    profiler.complete("writerFinalizationAndMove")
    try writeCompositionReport(composition: composition, output: options.output, state: "completed")
    emitProgress(phase: "completed", percent: 100)
    print("temporal blur frames=\(motionBlurredFrames)/\(totalFrames)")
    profiler.complete("finalReporting")
    if let profile = options.profile {
        try profiler.write(
            to: profile, mode: "render", planner: cameraPlan.diagnostics.plannerVersion,
            source: options.source, timeline: options.timeline, output: options.output,
            sourceDuration: sourceDuration, outputDuration: composition.outputDuration,
            sourceSize: naturalSize, outputSize: outputSize, fps: options.fps,
            samples: options.samples, analysisCacheHit: cachedMotionAnalysis.hit,
            analyzedFrames: motionAnalysis.sampledFrames,
            motionFrames: motionAnalysis.motionFrames, actionCount: composition.actions.count,
            shotCount: composition.shots.count, outputFrameCount: totalFrames
        )
    }
}

private func loadCaptureTruth(
    timeline: Timeline,
    timelineURL: URL,
    sourceDuration: Double
) -> CaptureTruthContext {
    guard let provenancePath = timeline.capture?.frameProvenance else {
        print("capture truth=legacy-unavailable fallback=editorial-motion")
        return CaptureTruthContext(
            verifiedIdleRanges: nil, provenIdleActionIDs: []
        )
    }
    let provenanceURL = URL(
        fileURLWithPath: provenancePath,
        relativeTo: timelineURL.deletingLastPathComponent()
    ).standardizedFileURL
    let ledger: CaptureFrameLedger
    do {
        ledger = try JSONDecoder().decode(
            CaptureFrameLedger.self, from: Data(contentsOf: provenanceURL)
        )
    } catch {
        // A timeline that declares provenance but cannot supply it must fail
        // closed: no time is considered verified idle.
        print("capture truth=unavailable preserve=all error=\(error.localizedDescription)")
        return CaptureTruthContext(
            verifiedIdleRanges: [], provenIdleActionIDs: []
        )
    }
    let windows = factualActionWindows(timeline: timeline, sourceDuration: sourceDuration)
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger, sourceDuration: sourceDuration, actions: windows
    )
    let provenIdleActionIDs = Set(windows.compactMap { window in
        // Scroll has no synthetic pointer or keystroke overlay. Removing its
        // generic hold changes timing only when WindowServer proved that the
        // entire causal interval had no visible consequence.
        window.kind == "scroll" && analysis.actionStates[window.id] == .provenIdle
            ? window.id : nil
    })
    let counts = analysis.actionStates.values.reduce(into: [VisibleChangeState: Int]()) {
        $0[$1, default: 0] += 1
    }
    print(
        "capture truth samples=\(ledger.samples.count) " +
            "idleRanges=\(analysis.provenIdleRanges.count) " +
            "actions=visible:\(counts[.visibleChange, default: 0])," +
            "idle:\(counts[.provenIdle, default: 0]),unknown:\(counts[.unknown, default: 0]) " +
            "emptyScrolls=\(provenIdleActionIDs.sorted())"
    )
    return CaptureTruthContext(
        verifiedIdleRanges: analysis.provenIdleRanges,
        provenIdleActionIDs: provenIdleActionIDs
    )
}

private func factualActionWindows(
    timeline: Timeline,
    sourceDuration: Double
) -> [FactualActionWindow] {
    guard let captureStart = timeline.capture?.startedAt.flatMap(parseISO8601) else { return [] }
    let starts: [Double?] = timeline.events.map { event in
        event.timing?.toolCallStartedAt.flatMap(parseISO8601).map {
            max(0, $0.timeIntervalSince(captureStart))
        }
    }
    return timeline.events.enumerated().compactMap { index, event in
        guard let start = starts[index], start < sourceDuration else { return nil }
        let end: Double
        if index + 1 < starts.count {
            // Do not bridge over an action whose clock could not be joined.
            guard let nextStart = starts[index + 1], nextStart > start else { return nil }
            end = min(sourceDuration, nextStart)
        } else {
            end = sourceDuration
        }
        guard end > start else { return nil }
        return FactualActionWindow(
            id: index,
            actionID: event.actionId ?? "action-\(index)",
            kind: event.action ?? event.method ?? "unknown",
            start: start,
            end: end
        )
    }
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
              let end = parseISO8601(endText)
        else { return nil }
        // A coordinate-less Computer Use click is still a factual action with
        // a tool envelope. Analyze its full-viewport response so dialogs and
        // other large reveals are not lost merely because AX geometry could
        // not reconstruct the synthetic pointer target.
        let spatialTarget = normalizedTimingTarget(event)
        let target = spatialTarget ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return InteractionTimingProbe(
            actionID: id,
            rawEstimate: rawEstimate,
            toolStart: start.timeIntervalSince(captureStart),
            toolEnd: end.timeIntervalSince(captureStart),
            finalActionInToolCall: event.timing?.actionIsFinalSkyCall ?? false,
            normalizedTarget: target,
            hasSpatialTarget: spatialTarget != nil,
            focusIntent: motionFocusIntent(event)
        )
    }
}

func motionFocusIntent(_ event: Timeline.Event) -> MotionFocusIntent {
    let title = event.semanticTarget?.title?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let dismissalTitles: Set<String> = ["close", "dismiss", "cancel", "done"]
    return title.map(dismissalTitles.contains) == true ? .dismissal : .automatic
}

func normalizedTimingTarget(_ event: Timeline.Event) -> CGRect? {
    let semanticBounds: CGRect? = {
        guard let bounds = event.semanticTarget?.bounds,
              let x = bounds.xNorm, let y = bounds.yNorm,
              let width = bounds.widthNorm, let height = bounds.heightNorm,
              [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
        else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }()
    let point: CGPoint? = {
        guard let x = event.coordinates?.xNorm, let y = event.coordinates?.yNorm,
              x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }()
    return InteractionTimingTarget.resolve(
        semanticBounds: semanticBounds,
        normalizedPoint: point
    )
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

private let cursorLeadFraction = 0.10

private struct SampledCameraPlan {
    let states: [CameraState]
    let emergencyCorrections: Int
    let emergencyRanges: [ClosedRange<Int>]
}

private func makeCameraPlan(
    composition: NativeComposition,
    base: CameraState,
    planner: Options.CameraPlanner,
    contentRect: CGRect,
    sourceDuration: Double,
    motionAnalysis: MotionAnalysis,
    captureTruth: CaptureTruthContext,
    reduceWaiting: Bool,
    waitingTime: Double
) -> (
    composition: NativeComposition,
    camera: CameraPlan,
    global: GlobalProductionPlan?,
    experimental: ExperimentalProductionPlan?
) {
    switch planner {
    case .normal, .experimental:
        var resolvedComposition = composition
        var protectedObservationIDs = Set(
            motionAnalysis.observations.indices.filter {
                SpatialMotion.isFramingEligible(motionAnalysis.observations[$0])
            }
        )
        let initialRetime = GlobalRetimePlanner.plan(
            actions: resolvedComposition.actions,
            sourceDuration: sourceDuration,
            motionRanges: motionAnalysis.ranges,
            protectedInteractionRanges: resolvedComposition.protectedPointerTravelRanges(
                sourceDuration: sourceDuration
            ),
            protectedResponseRanges: GlobalRetimePlanner.protectedResponseRanges(
                observations: motionAnalysis.observations,
                observationIDs: protectedObservationIDs,
                sourceDuration: sourceDuration
            ),
            verifiedIdleRanges: captureTruth.verifiedIdleRanges,
            provenIdleActionIDs: captureTruth.provenIdleActionIDs,
            firstPointerMovementTime: resolvedComposition.firstPointerMovementTime,
            reduceWaiting: reduceWaiting,
            waitingTime: waitingTime,
            deadTimeRate: resolvedComposition.recipe.deadTimeRate
        )
        resolvedComposition = resolvedComposition.replacingWithGlobalPlan(
            actions: resolvedComposition.actions,
            retime: initialRetime,
            interactionPhases: resolvedComposition.interactionPhases
        )
        var lastSignature: String?
        var iterations = 0
        for iteration in 0..<6 {
            let graph = ProductionPlanGraph.make(
                from: resolvedComposition,
                contentRect: contentRect,
                sourceDuration: sourceDuration,
                observations: motionAnalysis.observations,
                motionRanges: motionAnalysis.ranges
            )
            let pass = ProductionPlanner.plan(
                graph: graph, composition: resolvedComposition, base: base
            )
            guard pass.camera.diagnostics.feasible else {
                return (resolvedComposition, pass.camera, pass, nil)
            }
            let signature = pass.decisions.map {
                "\($0.actionID):\($0.timingID):\($0.attentionID)"
            }.joined(separator: "|")
            let actions = graph.resolvedActions(from: pass.decisions)
            let phases = graph.resolvedInteractionPhases(
                from: pass.decisions,
                existing: resolvedComposition.interactionPhases
            )
            let choreography = resolvedComposition.replacingWithGlobalPlan(
                actions: actions,
                retime: resolvedComposition.retime,
                interactionPhases: phases
            )
            protectedObservationIDs = Set(pass.decisions.flatMap(\.observationIDs))
            let retime = GlobalRetimePlanner.plan(
                actions: actions,
                sourceDuration: sourceDuration,
                motionRanges: motionAnalysis.ranges,
                protectedInteractionRanges: choreography.protectedPointerTravelRanges(
                    sourceDuration: sourceDuration
                ),
                protectedResponseRanges: GlobalRetimePlanner.protectedResponseRanges(
                    observations: motionAnalysis.observations,
                    observationIDs: protectedObservationIDs,
                    sourceDuration: sourceDuration
                ),
                verifiedIdleRanges: captureTruth.verifiedIdleRanges,
                provenIdleActionIDs: captureTruth.provenIdleActionIDs,
                firstPointerMovementTime: choreography.firstPointerMovementTime,
                reduceWaiting: reduceWaiting,
                waitingTime: waitingTime,
                deadTimeRate: resolvedComposition.recipe.deadTimeRate
            )
            resolvedComposition = resolvedComposition.replacingWithGlobalPlan(
                actions: actions, retime: retime, interactionPhases: phases
            )
            iterations = iteration + 1
            if signature == lastSignature { break }
            lastSignature = signature
        }
        let finalGraph = ProductionPlanGraph.make(
            from: resolvedComposition,
            contentRect: contentRect,
            sourceDuration: sourceDuration,
            observations: motionAnalysis.observations,
            motionRanges: motionAnalysis.ranges
        )
        let global = ProductionPlanner.plan(
            graph: finalGraph, composition: resolvedComposition, base: base
        )
        print("native production fixed-point-iterations=\(iterations)")
        if planner == .normal {
            return (resolvedComposition, global.camera, global, nil)
        }
        let experimental = ExperimentalCameraPlanner.plan(
            graph: finalGraph,
            composition: resolvedComposition,
            base: base
        )
        let experimentalGlobal = GlobalProductionPlan(
            camera: experimental.camera,
            decisions: global.decisions,
            hypothesisCount: global.hypothesisCount,
            beamWidth: global.beamWidth,
            searchTrace: global.searchTrace
        )
        return (resolvedComposition, experimental.camera, experimentalGlobal, experimental)
    }
}

private func precomputeCameraSamples(
    composition: NativeComposition,
    plan: CameraPlan,
    base: CameraState,
    frameCount: Int,
    fps: Int32,
    samples: Int
) throws -> SampledCameraPlan {
    let count = frameCount * samples
    let rate = Double(fps) * Double(samples)
    var result: [CameraState] = []
    var visibilityAdjusted: [CameraState] = []
    var emergencyVisibilityCorrections = 0
    result.reserveCapacity(count)
    visibilityAdjusted.reserveCapacity(count)
    for index in 0..<count {
        let outputTime = (Double(index) + 0.5) / rate
        let sourceTime = composition.sourceTime(atOutputTime: outputTime)
        var state = cameraState(at: outputTime, plan: plan, base: base)
        let unconstrained = state
        let factualInset: CGFloat = plan.diagnostics.plannerVersion.hasPrefix("normal")
            || plan.diagnostics.plannerVersion.hasPrefix("experimental") ? 28 : 50
        state = composition.enforcingFactualActionVisibility(state, at: sourceTime, inset: factualInset)
        let correctedX = abs(state.x - unconstrained.x) > 0.0001
        let correctedY = abs(state.y - unconstrained.y) > 0.0001
        let correctedScale = abs(state.logScale - unconstrained.logScale) > 0.0001
        if correctedX || correctedY || correctedScale {
            emergencyVisibilityCorrections += 1
        }
        result.append(unconstrained)
        visibilityAdjusted.append(state)
    }
    print("native camera emergency-visibility-corrections=\(emergencyVisibilityCorrections)/\(count)")
    let recovery = smoothedVisibilityCorrections(
        unconstrained: result, adjusted: visibilityAdjusted, samplesPerSecond: rate
    )
    result = recovery.states
    if !recovery.ranges.isEmpty {
        let ranges = recovery.ranges
        let summary = ranges.map {
            String(format: "%.2f-%.2f", Double($0.lowerBound) / rate, Double($0.upperBound) / rate)
        }.joined(separator: ",")
        print("native camera emergency-ranges-out=\(summary)")
        print("native camera recovery=minimal-visibility-smoothed ranges=\(ranges.count)")
    }
    let moveSummary = plan.moves.map {
        "\($0.label){\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end)),scale:\(String(format: "%.2f", exp($0.from.logScale)))->\(String(format: "%.2f", exp($0.to.logScale)))}"
    }.joined(separator: " | ")
    print("native camera moves=\(moveSummary)")
    let trackSummary = plan.tracks.map {
        "\($0.label){\(String(format: "%.2f", $0.start))-\(String(format: "%.2f", $0.end)),keys:\($0.keyframes.count)}"
    }.joined(separator: " | ")
    if !trackSummary.isEmpty { print("native camera tracks=\(trackSummary)") }
    return SampledCameraPlan(
        states: result,
        emergencyCorrections: emergencyVisibilityCorrections,
        emergencyRanges: recovery.ranges
    )
}

private func writeCameraTrajectoryAudit(
    composition: NativeComposition,
    plan: CameraPlan,
    sampledPlan: SampledCameraPlan,
    frameCount: Int,
    fps: Int32,
    samples: Int,
    output: URL
) throws {
    let cameras = sampledPlan.states
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
    let moveWindows: [[String: Any]] = plan.moves.map { move in
        let start = max(0, min(frameCameras.count - 1, Int(move.start * Double(fps))))
        let end = max(start, min(frameCameras.count - 1, Int(move.end * Double(fps))))
        var result = metrics(start: start, end: end)
        result["label"] = move.label
        return result
    }
    let trackWindows: [[String: Any]] = plan.tracks.compactMap { track in
        guard track.end >= track.start else { return nil }
        let start = max(0, min(frameCameras.count - 1, Int(track.start * Double(fps))))
        let end = max(start, min(frameCameras.count - 1, Int(track.end * Double(fps))))
        var result = metrics(start: start, end: end)
        result["label"] = track.label
        result["keyframes"] = track.keyframes.count
        return result
    }
    let sampleRate = Double(fps) * Double(samples)
    func camera(atSourceTime sourceTime: Double) -> (camera: CameraState, outputTime: Double) {
        let outputTime = composition.outputTime(atSourceTime: sourceTime)
        let index = max(0, min(cameras.count - 1, Int((outputTime * sampleRate).rounded())))
        return (cameras[index], outputTime)
    }
    func pointerCheck(action: DirectedAction, label: String, sourceTime: Double, target: CGPoint) -> [String: Any] {
        let sampled = camera(atSourceTime: sourceTime)
        let cursorState = composition.cursor(at: sourceTime)
        let cursor = cursorState.point
        let projected = projectPointThroughCamera(target, camera: sampled.camera, outputSize: logicalOutputSize)
        return [
            "actionID": action.id,
            "actionId": action.actionId,
            "kind": action.kind,
            "check": label,
            "sourceTime": sourceTime,
            "outputTime": sampled.outputTime,
            "target": ["x": target.x, "y": target.y],
            "cursor": ["x": cursor.x, "y": cursor.y],
            "hotspotError": hypot(cursor.x - target.x, cursor.y - target.y),
            "projected": ["x": projected.x, "y": projected.y],
            "visible": projected.x >= 0 && projected.x <= logicalOutputSize.width
                && projected.y >= 0 && projected.y <= logicalOutputSize.height,
            "safeVisible": projected.x >= 50 && projected.x <= logicalOutputSize.width - 50
                && projected.y >= 50 && projected.y <= logicalOutputSize.height - 50,
            "cameraScale": exp(sampled.camera.logScale),
            "cursorScale": cursorState.scale,
            "provenance": action.pointProvenance ?? "unknown"
        ]
    }
    var alignment: [[String: Any]] = []
    for action in composition.actions where ["click", "drag"].contains(action.kind) && action.rendersCursor {
        if action.kind == "drag", let from = action.from, let to = action.to {
            alignment.append(pointerCheck(
                action: action, label: "drag-start",
                sourceTime: action.time - action.duration / 2, target: from
            ))
            alignment.append(pointerCheck(
                action: action, label: "drag-end",
                sourceTime: action.time + action.duration / 2, target: to
            ))
        } else if let point = action.point {
            alignment.append(pointerCheck(action: action, label: "pointer-activation", sourceTime: action.time, target: point))
        }
    }
    for action in composition.actions {
        guard let bounds = action.semanticBounds else { continue }
        let sampled = camera(atSourceTime: action.time)
        let projectedMin = projectPointThroughCamera(
            CGPoint(x: bounds.minX, y: bounds.minY), camera: sampled.camera, outputSize: logicalOutputSize
        )
        let projectedMax = projectPointThroughCamera(
            CGPoint(x: bounds.maxX, y: bounds.maxY), camera: sampled.camera, outputSize: logicalOutputSize
        )
        let projected = CGRect(
            x: min(projectedMin.x, projectedMax.x), y: min(projectedMin.y, projectedMax.y),
            width: abs(projectedMax.x - projectedMin.x), height: abs(projectedMax.y - projectedMin.y)
        )
        alignment.append([
            "actionID": action.id,
            "actionId": action.actionId,
            "kind": action.kind,
            "check": "semantic-bounds",
            "sourceTime": action.time,
            "outputTime": sampled.outputTime,
            "projected": ["x": projected.minX, "y": projected.minY, "width": projected.width, "height": projected.height],
            "visible": projected.minX >= 0 && projected.maxX <= logicalOutputSize.width
                && projected.minY >= 0 && projected.maxY <= logicalOutputSize.height,
            "safeVisible": projected.minX >= 50 && projected.maxX <= logicalOutputSize.width - 50
                && projected.minY >= 50 && projected.maxY <= logicalOutputSize.height - 50,
            "cameraScale": exp(sampled.camera.logScale)
        ])
    }
    let beatScales: [[String: Any]] = composition.actions.map { action in
        let sampled = camera(atSourceTime: action.time)
        return [
            "actionID": action.id,
            "kind": action.kind,
            "outputTime": sampled.outputTime,
            "scale": exp(sampled.camera.logScale)
        ]
    }
    let pointerActions = composition.actions.filter { ["click", "drag"].contains($0.kind) }
    let factualPointers = pointerActions.filter { $0.rendersCursor && isFactualCursorTarget($0) }
    let inferredRenderedPointers = pointerActions.filter { $0.rendersCursor && !isFactualCursorTarget($0) }
    let inferredOmittedPointers = pointerActions.filter {
        !$0.rendersCursor && $0.pointProvenance == "visual-inferred"
    }
    let unresolvedPointers = pointerActions.filter {
        !$0.rendersCursor && $0.pointProvenance != "visual-inferred"
    }
    let report: [String: Any] = [
        "version": 3,
        "planner": plan.diagnostics.plannerVersion,
        "planFeasible": plan.diagnostics.feasible,
        "planFailure": plan.diagnostics.failure ?? NSNull(),
        "emergencyCorrections": sampledPlan.emergencyCorrections,
        "emergencyRanges": sampledPlan.emergencyRanges.map { ["start": $0.lowerBound, "end": $0.upperBound] },
        "rejectedNodes": plan.diagnostics.rejectedNodes,
        "rejectedEdges": plan.diagnostics.rejectedEdges,
        "pointerEvidence": [
            "total": pointerActions.count,
            "factual": factualPointers.count,
            "inferredRendered": inferredRenderedPointers.count,
            "inferredOmitted": inferredOmittedPointers.count,
            "unresolved": unresolvedPointers.count,
            "unresolvedActionIds": unresolvedPointers.map(\.actionId)
        ],
        "windows": windows,
        "moves": moveWindows,
        "tracks": trackWindows,
        "beatScales": beatScales,
        "alignment": alignment
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("camera-audit.json")
    try data.write(to: url, options: .atomic)
    print("native camera audit=\(url.path)")
}

private func writeGlobalProductionPlanReport(
    _ plan: GlobalProductionPlan,
    output: URL
) throws {
    func camera(_ state: CameraState) -> [String: Any] {
        [
            "x": state.x,
            "y": state.y,
            "scale": exp(state.logScale)
        ]
    }
    let decisions: [[String: Any]] = plan.decisions.map { decision in
        [
            "actionID": decision.actionID,
            "timingHypothesisID": decision.timingID,
            "attentionHypothesisID": decision.attentionID,
            "activation": decision.activation,
            "timingSource": decision.timingSource,
            "observationIDs": decision.observationIDs.sorted(),
            "arrivalPose": camera(decision.arrivalPose),
            "responsePose": camera(decision.pose),
            "cumulativeCost": decision.cumulativeCost
        ]
    }
    var report: [String: Any] = [
        "version": 1,
        "planner": plan.camera.diagnostics.plannerVersion,
        "feasible": plan.camera.diagnostics.feasible,
        "hypothesisCount": plan.hypothesisCount,
        "beamWidth": plan.beamWidth,
        "searchTrace": plan.searchTrace.map { step in
            [
                "actionID": step.actionID,
                "candidateCount": step.candidateCount,
                "incomingPathCount": step.incomingPathCount,
                "proposalCount": step.proposalCount,
                "uniqueTrajectoryCount": step.uniqueTrajectoryCount,
                "feasibleTrajectoryCount": step.feasibleTrajectoryCount,
                "outputPathCount": step.outputPathCount
            ]
        },
        "decisions": decisions,
        "moves": plan.camera.moves.map { move in
            [
                "label": move.label,
                "start": move.start,
                "end": move.end,
                "from": camera(move.from),
                "to": camera(move.to)
            ] as [String: Any]
        },
        "tracks": plan.camera.tracks.map { track in
            [
                "label": track.label,
                "start": track.start,
                "end": track.end,
                "keyframeCount": track.keyframes.count
            ] as [String: Any]
        }
    ]
    if let failure = plan.camera.diagnostics.failure {
        report["failure"] = failure
    }
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("production-plan.json")
    try data.write(to: url, options: .atomic)
    print("native production plan=\(url.path)")
}

private func writeExperimentalProductionPlanReport(
    _ plan: ExperimentalProductionPlan,
    output: URL
) throws {
    func camera(_ state: CameraState) -> [String: Any] {
        ["x": state.x, "y": state.y, "scale": exp(state.logScale)]
    }
    let report: [String: Any] = [
        "version": 1,
        "planner": plan.camera.diagnostics.plannerVersion,
        "feasible": plan.camera.diagnostics.feasible,
        "factualSamples": plan.factualSamples,
        "trackingSamples": plan.trackingSamples,
        "subjects": plan.subjects.subjects.map { subject in
            [
                "id": subject.id,
                "kind": subject.kind.rawValue,
                "bounds": [
                    "x": subject.bounds.minX, "y": subject.bounds.minY,
                    "width": subject.bounds.width, "height": subject.bounds.height
                ],
                "sourceStart": subject.sourceRange.lowerBound,
                "sourceEnd": subject.sourceRange.upperBound,
                "actionIDs": subject.actionIDs,
                "observationIDs": subject.observationIDs.sorted(),
                "confidence": subject.confidence
            ] as [String: Any]
        },
        "transitions": plan.subjects.transitions.map { transition in
            [
                "observationID": transition.observationID,
                "sourceTime": transition.sourceTime,
                "causalActionID": transition.causalActionID ?? NSNull(),
                "responseSubjectID": transition.responseSubjectID ?? NSNull()
            ] as [String: Any]
        },
        "shots": plan.schedule.shots.map { shot in
            [
                "id": shot.id,
                "subjectID": shot.subjectID ?? NSNull(),
                "intent": shot.intent.rawValue,
                "start": shot.interval.lowerBound,
                "end": shot.interval.upperBound,
                "pose": camera(shot.pose),
                "actionIDs": shot.actionIDs,
                "readabilityValue": shot.readabilityValue
            ] as [String: Any]
        },
        "moves": plan.camera.moves.map { move in
            [
                "label": move.label,
                "start": move.start, "end": move.end,
                "from": camera(move.from), "to": camera(move.to)
            ] as [String: Any]
        },
        "tracks": plan.camera.tracks.map { track in
            [
                "label": track.label,
                "start": track.start, "end": track.end,
                "keyframeCount": track.keyframes.count
            ] as [String: Any]
        }
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("experimental-plan.json")
    try data.write(to: url, options: .atomic)
    print("native experimental plan=\(url.path)")
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
    for observation in observations where
        abs(observation.time - sourceTime) <= 0.9
        && SpatialMotion.isFramingEligible(observation) {
        let bounds = CGRect(
            x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
            width: observation.normalizedBounds.width * contentRect.width,
            height: observation.normalizedBounds.height * contentRect.height
        )
        let color: CIColor = switch observation.kind {
        case .translation: CIColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.9)
        case .contextTransition: CIColor(red: 0.72, green: 0.32, blue: 1, alpha: 0.95)
        default: CIColor(red: 1, green: 0.18, blue: 0.32, alpha: 0.9)
        }
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
            case .visualFocus: color = CIColor(red: 0.2, green: 0.95, blue: 0.7, alpha: 0.95)
            case .contextTransition: color = CIColor(red: 0.72, green: 0.32, blue: 1, alpha: 0.95)
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
        if let trip = composition.pointerTrip(forActionID: action.id) {
            item["pointerTrip"] = [
                "sourceStart": trip.start,
                "sourceEnd": trip.end,
                "outputStart": composition.outputTime(atSourceTime: trip.start),
                "outputEnd": composition.outputTime(atSourceTime: trip.end),
                "from": ["x": trip.from.x, "y": trip.from.y],
                "to": ["x": trip.to.x, "y": trip.to.y]
            ] as [String: Any]
        }
        if let phase = composition.interactionPhases[action.id] {
            var timing: [String: Any] = [
                "rawEstimate": phase.rawEstimate,
                "toolStart": phase.toolStart,
                "toolEnd": phase.toolEnd,
                "pointerArrival": phase.pointerArrival,
                "pointerArrivalSource": phase.pointerArrivalSource,
                "activation": phase.activation,
                "source": phase.source
            ]
            if let responseOnset = phase.responseOnset { timing["responseOnset"] = responseOnset }
            if let end = phase.preActivationActivityEnd { timing["preActivationActivityEnd"] = end }
            if let threshold = phase.activityThreshold { timing["activityThreshold"] = threshold }
            timing["activityClusters"] = phase.activityClusters.map { cluster in
                [
                    "start": cluster.start,
                    "end": cluster.end,
                    "peak": cluster.peak,
                    "peakTime": cluster.peakTime,
                    "count": cluster.count
                ] as [String: Any]
            }
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
                    var item: [String: Any] = [
                        "source": evidence.source.rawValue,
                        "bounds": rect(evidence.bounds),
                        "confidence": evidence.confidence,
                        "framingWeight": evidence.framingWeight,
                        "persistence": evidence.persistence
                    ]
                    if let transition = evidence.focusTransition {
                        item["focusTransition"] = transition.rawValue
                    }
                    return item
                }
            ] as [String: Any]
        }
        return item
    }
    let report: [String: Any] = [
        "version": 1,
        "output": ["width": Int(outputSize.width), "height": Int(outputSize.height), "duration": composition.outputDuration],
        "legend": ["attention": "cyan", "appearance": "red", "translation": "blue", "contextTransition": "purple", "pointer": "yellow", "visualPointer": "orange", "accessibility": "green", "visualResponse": "magenta", "visualFocus": "mint"],
        "actions": actions,
        "shots": composition.shots.map { shot in
            ["id": shot.id, "start": shot.start, "end": shot.end, "baseScale": shot.scale, "actionIDs": shot.actions.map(\.id)] as [String: Any]
        },
        "motion": [
            "coordinateSpace": "source-window-normalized-top-left",
            "sampledFrames": motionAnalysis.sampledFrames,
            "movingFrames": motionAnalysis.motionFrames,
            "components": motionAnalysis.observations.map { observation in
                var item: [String: Any] = ["time": observation.time, "kind": observation.kind.rawValue, "bounds": rect(observation.normalizedBounds), "changedFraction": observation.changedFraction, "magnitude": observation.magnitude]
                if let transition = observation.focusTransition {
                    item["focusTransition"] = transition.rawValue
                }
                return item
            },
            "fields": motionAnalysis.motionFields.map { sample in
                let field = sample.field
                var item: [String: Any] = [
                    "actionID": sample.actionID,
                    "isActivationResponse": sample.isActivationResponse,
                    "beforeTime": field.beforeTime,
                    "afterTime": field.afterTime,
                    "shifts": field.shifts.map {
                        [
                            "bounds": rect($0.normalizedBounds),
                            "vector": ["dx": $0.normalizedVector.dx, "dy": $0.normalizedVector.dy],
                            "supportFraction": $0.supportFraction,
                            "confidence": $0.confidence,
                            "density": $0.density
                        ] as [String: Any]
                    },
                    "structural": field.structural.map {
                        [
                            "bounds": rect($0.normalizedBounds),
                            "changedFraction": $0.changedFraction,
                            "density": $0.density,
                            "energy": $0.energy,
                            "polarity": $0.polarity.rawValue
                        ] as [String: Any]
                    }
                ]
                if let activeFocus = sample.activeFocus {
                    item["activeFocus"] = rect(activeFocus)
                }
                if let transition = sample.focusTransition {
                    item["focusTransition"] = transition.rawValue
                }
                if let photometric = field.photometric {
                    item["photometric"] = [
                        "coveredFraction": photometric.coveredFraction,
                        "gain": photometric.meanGain,
                        "offset": photometric.meanOffset,
                        "residual": photometric.meanResidual,
                        "direction": photometric.direction.rawValue
                    ] as [String: Any]
                }
                if let backdrop = field.backdrop {
                    var context: [String: Any] = [
                        "coveredFraction": backdrop.coveredFraction,
                        "explainedChangeFraction": backdrop.explainedChangeFraction,
                        "blurRadius": backdrop.blurRadius,
                        "gain": backdrop.gain,
                        "offset": backdrop.offset,
                        "residual": backdrop.residual,
                        "confidence": backdrop.confidence,
                        "direction": backdrop.direction.rawValue
                    ]
                    if let focus = backdrop.focusedBounds { context["focusedBounds"] = rect(focus) }
                    item["backdrop"] = context
                }
                return item
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
