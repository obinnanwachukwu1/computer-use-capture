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
    let wallpaper: URL?
    let backgroundColor: CIColor?
    let cursor: URL
    let cursorMetadata: URL
    let fps: Int32
    let samples: Int
    let shutter: CGFloat
    let reduceWaiting: Bool
    let waitingTime: Double
    let planOnly: Bool
    let directorDebug: Bool
    let objectDetectionDebug: Bool
    let overviewBlameDebug: Bool
    let cursorPath: CursorPathStyle?
    let cursorTiltStrength: Double?
    let cameraPlanner: CameraPlanner
    let evaluationCondition: ProductionEvaluationCondition
    let oracleSupport: URL?
    let profile: URL?
    let useAnalysisCache: Bool
    let verifyAssetsOnly: Bool

    static func parse() throws -> Options {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3 else {
            throw Failure("usage: native-compose <source.mov> <timeline.json> <output.mp4> [--wallpaper image] [--background-color '#RRGGBB'] [--cursor image --cursor-metadata json] [--legacy-camera-planner] [--camera-eval-condition a-current|b-optional-motion|c-oracle-current|d-oracle-gated --oracle-support fixture.json] [--output-scale 1|2] [--fps 60] [--samples 8] [--shutter 0.55] [--cursor-path natural|straight] [--cursor-tilt-strength 0...1.5] [--keep-waiting] [--waiting-time milliseconds] [--plan-only] [--director-debug|--object-detection-debug|--overview-blame-debug] [--profile [profile.json]] [--no-analysis-cache]")
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
            || ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_CAMERA_PLANNER"] != nil {
            throw Failure("--camera-planner was removed; the global scheduler is the default and the previous planner is available only through --legacy-camera-planner")
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
        let legacyCamera = args.contains("--legacy-camera-planner")
            || ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_LEGACY_CAMERA_PLANNER"] == "1"
        // Keep accepting the pre-promotion opt-in as a compatibility no-op.
        // Existing development scripts and saved commands should continue to
        // select the same global scheduler after it becomes the default.
        let globalCameraAlias = args.contains("--experimental-camera-planner")
            || ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_EXPERIMENTAL_CAMERA_PLANNER"] == "1"
        if legacyCamera && globalCameraAlias {
            throw Failure("--legacy-camera-planner and --experimental-camera-planner are mutually exclusive")
        }
        let cameraPlanner: CameraPlanner = legacyCamera ? .normal : .experimental
        let evaluationCondition: ProductionEvaluationCondition
        if let rawCondition = optionalValue("--camera-eval-condition") {
            guard let parsed = ProductionEvaluationCondition(rawValue: rawCondition),
                  parsed != .production else {
                throw Failure("--camera-eval-condition must be a-current, b-optional-motion, c-oracle-current, or d-oracle-gated")
            }
            evaluationCondition = parsed
        } else {
            evaluationCondition = .production
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let output = URL(fileURLWithPath: args[2], relativeTo: cwd).standardizedFileURL
        let wallpaper = optionalValue("--wallpaper").map {
            URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL
        }
        let backgroundColor = try optionalValue("--background-color").map(parseHexColor)
        if wallpaper != nil && backgroundColor != nil {
            throw Failure("--wallpaper and --background-color are mutually exclusive")
        }
        let cursor = URL(fileURLWithPath: value("--cursor", "artifacts/macos-arrow.png"), relativeTo: cwd).standardizedFileURL
        let cursorMetadata = URL(
            fileURLWithPath: value("--cursor-metadata", cursor.path + ".json"), relativeTo: cwd
        ).standardizedFileURL
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
        let objectDetectionDebug = args.contains("--object-detection-debug")
        let overviewBlameDebug = args.contains("--overview-blame-debug")
        return Options(
            source: URL(fileURLWithPath: args[0], relativeTo: cwd).standardizedFileURL,
            timeline: URL(fileURLWithPath: args[1], relativeTo: cwd).standardizedFileURL,
            output: output,
            wallpaper: wallpaper,
            backgroundColor: backgroundColor,
            cursor: cursor,
            cursorMetadata: cursorMetadata,
            fps: max(30, Int32(value("--fps", "60")) ?? 60),
            samples: max(1, Int(value("--samples", "8")) ?? 8),
            shutter: min(1, max(0, CGFloat(Double(value("--shutter", "0.55")) ?? 0.55))),
            // Editorial waiting cuts are the product default. Keep the old
            // affirmative flag compatible while providing an explicit opt-out.
            reduceWaiting: !args.contains("--keep-waiting"),
            waitingTime: max(0, (Double(value("--waiting-time", "100")) ?? 100) / 1000),
            planOnly: args.contains("--plan-only"),
            directorDebug: args.contains("--director-debug")
                || objectDetectionDebug
                || overviewBlameDebug,
            objectDetectionDebug: objectDetectionDebug,
            overviewBlameDebug: overviewBlameDebug,
            cursorPath: cursorPath,
            cursorTiltStrength: cursorTiltStrength,
            cameraPlanner: cameraPlanner,
            evaluationCondition: evaluationCondition,
            oracleSupport: optionalValue("--oracle-support").map {
                URL(fileURLWithPath: $0, relativeTo: cwd).standardizedFileURL
            },
            profile: profile,
            useAnalysisCache: !args.contains("--no-analysis-cache"),
            verifyAssetsOnly: args.contains("--verify-assets-only")
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
    let environmentValue = ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_OUTPUT_SCALE"].flatMap(Double.init)
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
    if options.verifyAssetsOnly {
        if let wallpaper = options.wallpaper { _ = try loadImage(wallpaper) }
        _ = try loadImage(options.cursor)
        _ = try loadCursorMetadata(options.cursorMetadata)
        print("native render assets verified")
        return
    }
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
    let textInputs = textInputEvidence(timeline: timeline)
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
    // The fixed-camera object view consumes canonical observations and the
    // object graph, both of which are cacheable. Per-action raw motion fields
    // are only needed by the broader director debugger; collecting them would
    // force every object-only review to re-run the full analysis pass.
    let collectMotionFields = options.directorDebug
        && !options.objectDetectionDebug
        && !options.overviewBlameDebug
    let cachedMotionAnalysis = try MotionAnalysisCache.resolve(
        source: options.source,
        fallbackActionTimes: fallbackActionTimes,
        timingProbes: timingProbes,
        textInputEvidence: textInputs,
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
            textInputEvidence: textInputs,
            relocationActionIDs: relocationActionIDs,
            collectMotionFields: collectMotionFields
        )
    }
    let rawMotionAnalysis = cachedMotionAnalysis.analysis
    profiler.complete("motionAnalysis")
    let motionAnalysis = MotionAnalyzer.canonicalized(rawMotionAnalysis)
    var planningObservations = motionAnalysis.observations
    var supportObservationIDs = Set<Int>()
    var oracleSupportLifecycles: [OracleForegroundSupportLifecycle] = []
    if options.evaluationCondition.usesOracleSupport {
        guard let oracleURL = options.oracleSupport else {
            throw Failure("\(options.evaluationCondition.rawValue) requires --oracle-support")
        }
        let fixture = try JSONDecoder().decode(
            OracleForegroundSupportFixture.self,
            from: Data(contentsOf: oracleURL)
        ).validated(sourceDuration: sourceDuration)
        let supportEvidence = fixture.plannerEvidence(
            startingObservationID: planningObservations.count
        )
        let support = supportEvidence.observations
        oracleSupportLifecycles = supportEvidence.lifecycles
        supportObservationIDs = Set(planningObservations.count..<(planningObservations.count + support.count))
        planningObservations.append(contentsOf: support)
        print("native oracle support fixture=\(oracleURL.path) spans=\(fixture.observations.count) endpoints=\(support.count)")
    } else if options.oracleSupport != nil {
        throw Failure("--oracle-support is valid only with c-oracle-current or d-oracle-gated")
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
        let caretSummary = motionAnalysis.caretBlinkRanges.map {
            "\(String(format: "%.2f", $0.lowerBound))-\(String(format: "%.2f", $0.upperBound))"
        }.joined(separator: ",")
        print("caret blink ranges=\(caretSummary)")
    }
    let baseComposition = NativeComposition(
        timeline: timeline,
        size: logicalOutputSize,
        contentRect: contentRect,
        sourceDuration: sourceDuration,
        reduceWaiting: options.reduceWaiting,
        waitingTime: options.waitingTime,
        motionRanges: motionAnalysis.ranges,
        caretBlinkRanges: motionAnalysis.caretBlinkRanges,
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
        waitingTime: options.waitingTime,
        planningObservations: planningObservations,
        supportObservationIDs: supportObservationIDs,
        oracleSupportLifecycles: oracleSupportLifecycles,
        evaluationCondition: options.evaluationCondition
    )
    profiler.complete("cameraPlanning")
    let composition = planned.composition
    let actionResponseSlices = ActionResponseSlicer.make(
        actions: composition.actions,
        phases: composition.interactionPhases,
        evidence: motionAnalysis.episodeVisualEvidence,
        sourceDuration: sourceDuration
    )
    let objectBirthAudit = planned.experimental.map {
        ObjectBirthAudit.make(
            objects: $0.objects,
            evidence: motionAnalysis.episodeVisualEvidence,
            contentRect: contentRect
        )
    }
    if let first = composition.retime.first, first.sourceStart > 0.000_001 {
        let sourceStart = String(format: "%.3f", first.sourceStart)
        let firstPointer = composition.firstPointerMovementTime
            .map { String(format: "%.3f", $0) } ?? "none"
        print("native leading-idle-trim source-start=\(sourceStart) first-pointer=\(firstPointer)")
    }
    if options.directorDebug {
        try writeDirectorDebugReport(
            composition: composition,
            motionAnalysis: motionAnalysis,
            planningObservations: planningObservations,
            supportObservationIDs: supportObservationIDs,
            experimental: planned.experimental,
            output: options.output
        )
    }
    guard composition.outputDuration > 0 else { throw Failure("director produced an empty composition") }
    print("native director actions=\(composition.actions.count) shots=\(composition.shots.count) source=\(String(format: "%.2f", sourceDuration))s output=\(String(format: "%.2f", composition.outputDuration))s waiting=\(options.reduceWaiting ? "cut" : "compressed")")
    let pointerActions = composition.actions.filter { ["click", "drag"].contains($0.kind) }
    let factualPointers = pointerActions.filter { $0.rendersCursor && isFactualCursorTarget($0) }
    let inferredRenderedPointers = pointerActions.filter { $0.rendersCursor && !isFactualCursorTarget($0) }
    let inferredPointers = pointerActions.filter { ($0.point != nil || $0.to != nil) && !$0.rendersCursor }
    let missingPointers = pointerActions.filter { $0.point == nil && $0.to == nil }
    print("native pointer coverage=\(factualPointers.count + inferredRenderedPointers.count)/\(pointerActions.count) factual=\(factualPointers.count) inferredRendered=\(inferredRenderedPointers.count) inferredOmitted=\(inferredPointers.count) unresolved=\(missingPointers.map(\.actionId))")
    try writeCompositionReport(
        composition: composition,
        output: options.output,
        state: "planned",
        sourceSize: naturalSize,
        contentRect: contentRect,
        renderScale: renderScale
    )
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
        try writeGlobalProductionPlanReport(
            global,
            observations: planningObservations,
            supportObservationIDs: supportObservationIDs,
            evaluationCondition: options.evaluationCondition,
            output: options.output
        )
    }
    if let experimental = planned.experimental {
        print("native experimental subjects=\(experimental.subjects.subjects.count) shots=\(experimental.schedule.shots.count) factualSamples=\(experimental.factualSamples) trackingSamples=\(experimental.trackingSamples)")
        if let objectBirthAudit {
            try writeObjectBirthAudit(objectBirthAudit, output: options.output)
        }
        try writeExperimentalProductionPlanReport(experimental, output: options.output)
        try writeOverviewBlameReport(
            experimental,
            composition: composition,
            observations: planningObservations,
            contentRect: contentRect,
            output: options.output
        )
        try writeActionResponseSliceReport(
            actionResponseSlices,
            output: options.output
        )
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
            motionObservations: planningObservations,
            actionResponseSlices: actionResponseSlices,
            contentRect: contentRect,
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

    let wallpaper = try options.wallpaper.map(loadImage)
        ?? CIImage(color: options.backgroundColor ?? CIColor(red: 0.12, green: 0.12, blue: 0.14))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    let cursor = try loadImage(options.cursor)
    let cursorMetadata = try loadCursorMetadata(options.cursorMetadata)
    let totalFrames = Int(ceil(composition.outputDuration * Double(options.fps)))
    profiler.complete("mediaPipelineSetup")
    emitProgress(phase: "rendering", percent: 0)
    let sampledPlan = try precomputeCameraSamples(
        composition: composition, plan: cameraPlan, base: baseCamera,
        frameCount: totalFrames, fps: options.fps, samples: options.samples
    )
    // Object-detection diagnosis must have a stable coordinate system. Keep
    // running the real planner and its audit so the overlays can show selected
    // ownership and target viewports, but remove camera motion only from this
    // diagnostic render. Production output is completely unchanged.
    let cameraSamples = options.objectDetectionDebug || options.overviewBlameDebug
        ? Array(repeating: baseCamera, count: sampledPlan.states.count)
        : sampledPlan.states
    if options.objectDetectionDebug || options.overviewBlameDebug {
        print("native diagnostic camera=fixed-overview planner-still-evaluated=true")
    }
    try writeCameraTrajectoryAudit(
        composition: composition, plan: cameraPlan, sampledPlan: sampledPlan,
        frameCount: totalFrames,
        fps: options.fps,
        samples: options.samples,
        motionObservations: motionAnalysis.observations,
        actionResponseSlices: actionResponseSlices,
        contentRect: contentRect,
        output: options.output
    )
    profiler.complete("cameraSamplingAndAudit")
    var nextSample = readerOutput.copyNextSampleBuffer()
    var decodedFrames: [DecodedFrame] = []
    var motionBlurredFrames = 0
    let debugContext = options.directorDebug ? DirectorDebugContext(
        rawObservations: motionAnalysis.observations,
        planningObservations: planningObservations,
        supportObservationIDs: supportObservationIDs,
        experimental: planned.experimental,
        objectBirthAudit: objectBirthAudit,
        objectDetectionOnly: options.objectDetectionDebug,
        overviewBlameOnly: options.overviewBlameDebug
    ) : nil

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
            debugContext: debugContext
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
    let maximumCameraScale = sampledPlan.states.map { exp($0.logScale) }.max() ?? 1
    try writeCompositionReport(
        composition: composition,
        output: options.output,
        state: "completed",
        sourceSize: naturalSize,
        contentRect: contentRect,
        renderScale: renderScale,
        maximumCameraScale: maximumCameraScale
    )
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
    print("COMPUTER_USE_CAPTURE_PROGRESS \(String(decoding: data, as: UTF8.self))")
}

func writeCompositionReport(
    composition: NativeComposition,
    output: URL,
    state: String,
    sourceSize: CGSize,
    contentRect: CGRect,
    renderScale: CGFloat,
    maximumCameraScale: CGFloat? = nil
) throws {
    let pointerActions = composition.actions.filter { ["click", "drag"].contains($0.kind) }
    let baseUpscaleX = contentRect.width * renderScale / max(1, sourceSize.width)
    let baseUpscaleY = contentRect.height * renderScale / max(1, sourceSize.height)
    let baseUpscale = max(baseUpscaleX, baseUpscaleY)
    let maximumUpscale = maximumCameraScale.map { baseUpscale * $0 }
    let report: [String: Any] = [
        "version": 2,
        "state": state,
        "output": output.path,
        "durationSeconds": composition.outputDuration,
        "sourceRaster": [
            "width": sourceSize.width,
            "height": sourceSize.height,
            "baseUpscaleFactor": baseUpscale,
            "maximumCameraScale": maximumCameraScale.map { $0 as Any } ?? NSNull(),
            "maximumUpscaleFactor": maximumUpscale.map { $0 as Any } ?? NSNull(),
            "baseUpscaled": baseUpscale > 1.000_001
        ],
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

func textInputEvidence(timeline: Timeline) -> [TextInputEvidence] {
    let typingActions: Set<String> = ["type_text", "set_value", "select_text"]
    return timeline.events.enumerated().compactMap { index, event in
        let kind = event.action ?? event.method ?? ""
        guard let time = event.time,
              let bounds = normalizedSemanticBounds(event),
              typingActions.contains(kind) || isTextInputRole(event.semanticTarget?.role)
        else { return nil }
        // A typing action corroborates a focus that may have begun when the
        // preceding action revealed the field. Any subsequent non-typing
        // action closes this evidence lifetime; later caret-like motion must
        // earn new text-input evidence instead of inheriting stale context.
        let validFrom = typingActions.contains(kind)
            ? timeline.events[..<index].reversed().compactMap(\.time).first ?? time
            : time
        let validThrough = timeline.events.dropFirst(index + 1).first {
            guard let nextKind = $0.action ?? $0.method else { return false }
            return !typingActions.contains(nextKind)
        }?.time
        return TextInputEvidence(
            time: time,
            normalizedBounds: bounds,
            validFrom: validFrom,
            validThrough: validThrough
        )
    }
}

func isTextInputRole(_ role: String?) -> Bool {
    guard let role = role?.lowercased() else { return false }
    return role.contains("textfield") || role.contains("text field")
        || role.contains("textarea") || role.contains("text area")
}

func normalizedSemanticBounds(_ event: Timeline.Event) -> CGRect? {
    guard let bounds = event.semanticTarget?.bounds,
          let x = bounds.xNorm, let y = bounds.yNorm,
          let width = bounds.widthNorm, let height = bounds.heightNorm,
          [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0
    else { return nil }
    return CGRect(x: x, y: y, width: width, height: height)
}

func motionFocusIntent(_ event: Timeline.Event) -> MotionFocusIntent {
    let title = event.semanticTarget?.title?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    let dismissalTitles: Set<String> = ["close", "dismiss", "cancel", "done"]
    return title.map(dismissalTitles.contains) == true ? .dismissal : .automatic
}

func normalizedTimingTarget(_ event: Timeline.Event) -> CGRect? {
    let semanticBounds = normalizedSemanticBounds(event)
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

struct DirectorDebugContext {
    let rawObservations: [VisualMotionObservation]
    let planningObservations: [VisualMotionObservation]
    let supportObservationIDs: Set<Int>
    let experimental: ExperimentalProductionPlan?
    let objectBirthAudit: ObjectBirthAudit?
    let objectDetectionOnly: Bool
    let overviewBlameOnly: Bool
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
    waitingTime: Double,
    planningObservations: [VisualMotionObservation],
    supportObservationIDs: Set<Int>,
    oracleSupportLifecycles: [OracleForegroundSupportLifecycle],
    evaluationCondition: ProductionEvaluationCondition
) -> (
    composition: NativeComposition,
    camera: CameraPlan,
    global: GlobalProductionPlan?,
    experimental: ExperimentalProductionPlan?
) {
    if evaluationCondition != .production && evaluationCondition != .aCurrent {
        // A factorial condition may change only attention and camera choice.
        // Resolve action timing and retiming once under A, then treat that
        // composition as immutable control data for B/C/D.
        let control = makeCameraPlan(
            composition: composition,
            base: base,
            planner: .normal,
            contentRect: contentRect,
            sourceDuration: sourceDuration,
            motionAnalysis: motionAnalysis,
            captureTruth: captureTruth,
            reduceWaiting: reduceWaiting,
            waitingTime: waitingTime,
            planningObservations: motionAnalysis.observations,
            supportObservationIDs: [],
            oracleSupportLifecycles: [],
            evaluationCondition: .aCurrent
        )
        guard control.camera.diagnostics.feasible else { return control }
        let graph = ProductionPlanGraph.make(
            from: control.composition,
            contentRect: contentRect,
            sourceDuration: sourceDuration,
            observations: planningObservations,
            episodeVisualEvidence: motionAnalysis.episodeVisualEvidence,
            motionRanges: motionAnalysis.ranges,
            evaluationCondition: evaluationCondition,
            supportObservationIDs: supportObservationIDs,
            oracleSupportLifecycles: oracleSupportLifecycles,
            freezeResolvedTiming: true
        )
        let global = ProductionPlanner.plan(
            graph: graph, composition: control.composition, base: base
        )
        print("native camera factorial control=frozen-a-current timing=true retime=true")
        if planner == .experimental {
            let experimental = ExperimentalCameraPlanner.plan(
                graph: graph,
                composition: control.composition,
                base: base,
                episodeVisualEvidence: motionAnalysis.episodeVisualEvidence
            )
            let experimentalGlobal = GlobalProductionPlan(
                camera: experimental.camera,
                decisions: global.decisions,
                hypothesisCount: global.hypothesisCount,
                beamWidth: global.beamWidth,
                searchTrace: global.searchTrace
            )
            return (
                control.composition,
                experimental.camera,
                experimentalGlobal,
                experimental
            )
        }
        return (control.composition, global.camera, global, nil)
    }
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
            caretBlinkRanges: motionAnalysis.caretBlinkRanges,
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
                observations: planningObservations,
                episodeVisualEvidence: motionAnalysis.episodeVisualEvidence,
                motionRanges: motionAnalysis.ranges,
                evaluationCondition: evaluationCondition,
                supportObservationIDs: supportObservationIDs,
                oracleSupportLifecycles: oracleSupportLifecycles
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
            let rawProtectedObservationIDs = protectedObservationIDs.filter {
                $0 < motionAnalysis.observations.count
            }
            let retime = GlobalRetimePlanner.plan(
                actions: actions,
                sourceDuration: sourceDuration,
                motionRanges: motionAnalysis.ranges,
                caretBlinkRanges: motionAnalysis.caretBlinkRanges,
                protectedInteractionRanges: choreography.protectedPointerTravelRanges(
                    sourceDuration: sourceDuration
                ),
                protectedResponseRanges: GlobalRetimePlanner.protectedResponseRanges(
                    observations: motionAnalysis.observations,
                    observationIDs: Set(rawProtectedObservationIDs),
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
            observations: planningObservations,
            episodeVisualEvidence: motionAnalysis.episodeVisualEvidence,
            motionRanges: motionAnalysis.ranges,
            evaluationCondition: evaluationCondition,
            supportObservationIDs: supportObservationIDs,
            oracleSupportLifecycles: oracleSupportLifecycles
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
            base: base,
            episodeVisualEvidence: motionAnalysis.episodeVisualEvidence
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
    motionObservations: [VisualMotionObservation],
    actionResponseSlices: [ActionResponseSlice],
    contentRect: CGRect,
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
            "sourceTime": action.time,
            "camera": [
                "x": sampled.camera.x,
                "y": sampled.camera.y,
                "scale": exp(sampled.camera.logScale)
            ],
            "scale": exp(sampled.camera.logScale)
        ]
    }
    let causalOrdering: [[String: Any]] = composition.actions.compactMap { action in
        guard let phase = composition.interactionPhases[action.id],
              let responseOnset = phase.responseOnset else { return nil }
        let tolerance = 0.08
        return [
            "actionID": action.id,
            "actionId": action.actionId,
            "kind": action.kind,
            "activation": action.time,
            "responseOnset": responseOnset,
            "timingSource": phase.source,
            "valid": action.time <= responseOnset + tolerance
        ]
    }
    let sustainedResponses: [[String: Any]] = motionObservations.compactMap { observation in
        let duration = observation.time - observation.startTime
        guard duration >= 0.75, SpatialMotion.isFramingEligible(observation) else { return nil }
        let sampleTime = min(observation.time, observation.startTime + 0.65)
        let sampled = camera(atSourceTime: sampleTime)
        let subject = CGRect(
            x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
            width: observation.normalizedBounds.width * contentRect.width,
            height: observation.normalizedBounds.height * contentRect.height
        )
        let minimum = projectPointThroughCamera(subject.origin, camera: sampled.camera, outputSize: logicalOutputSize)
        let maximum = projectPointThroughCamera(
            CGPoint(x: subject.maxX, y: subject.maxY), camera: sampled.camera, outputSize: logicalOutputSize
        )
        let projected = CGRect(
            x: min(minimum.x, maximum.x), y: min(minimum.y, maximum.y),
            width: abs(maximum.x - minimum.x), height: abs(maximum.y - minimum.y)
        )
        let visible = projected.intersection(CGRect(origin: .zero, size: logicalOutputSize))
        let visibleFraction = projected.width * projected.height > 0 && !visible.isNull
            ? visible.width * visible.height / (projected.width * projected.height) : 0
        let visibleOccupancy = visible.width * visible.height
            / max(1, logicalOutputSize.width * logicalOutputSize.height)
        let scale = exp(sampled.camera.logScale)
        // A response that already fills nearly the full viewport is correctly
        // framed at overview; zooming further would crop its subject. Smaller
        // sustained responses should receive a genuinely tighter shot.
        let overviewIsTight = observation.normalizedBounds.height >= 0.85
            || observation.normalizedBounds.width >= 0.9
        return [
            "sourceStart": observation.startTime,
            "sourceEnd": observation.time,
            "sampleOutputTime": sampled.outputTime,
            "cameraScale": scale,
            "visibleFraction": visibleFraction,
            "framed": (scale >= 1.08 || overviewIsTight || visibleOccupancy >= 0.30)
                && visibleFraction >= 0.85,
            "visibleOccupancy": visibleOccupancy,
            "bounds": [
                "x": observation.normalizedBounds.minX, "y": observation.normalizedBounds.minY,
                "width": observation.normalizedBounds.width, "height": observation.normalizedBounds.height
            ]
        ]
    }
    let responseCoverageAudit = ActionResponseCoverageAudit.evaluate(
        slices: actionResponseSlices,
        contentRect: contentRect,
        outputSize: logicalOutputSize,
        cameraAtSourceTime: { camera(atSourceTime: $0).camera }
    )
    let responseCoverageEntries: [[String: Any]] = responseCoverageAudit.responses.map { response in
        [
            "actionID": response.actionID,
            "evidenceIDs": response.evidenceIDs,
            "sourceOwnedEvidenceIDs": response.sourceOwnedEvidenceIDs,
            "sourceStart": response.sourceRange.lowerBound,
            "sourceEnd": response.sourceRange.upperBound,
            "worstSourceTime": response.worstSourceTime,
            "worstOutputTime": composition.outputTime(atSourceTime: response.worstSourceTime),
            "bounds": [
                "x": response.normalizedBounds.minX,
                "y": response.normalizedBounds.minY,
                "width": response.normalizedBounds.width,
                "height": response.normalizedBounds.height
            ],
            "evidenceCount": response.evidenceCount,
            "totalChangedFraction": response.totalChangedFraction,
            "relativeSignal": response.relativeSignal,
            "maximumConfidence": response.maximumConfidence,
            "material": response.material,
            "minimumVisibleFraction": response.minimumVisibleFraction,
            "minimumSafeVisibleFraction": response.minimumSafeVisibleFraction,
            "cropped": response.cropped,
            "reason": response.material && response.cropped
                ? "material-exclusive-action-response-cropped-by-selected-camera"
                : response.material
                    ? "material-exclusive-action-response-covered"
                    : "insufficient-exclusive-causal-support-for-camera-authority"
        ]
    }
    let responseCoverageReport: [String: Any] = [
        "version": 1,
        "policy": [
            "authority": "exclusive-action-response-negative-crop-diagnostic",
            "ordinaryMotionCreatesSubjects": false,
            "changesCamera": false
        ],
        "summary": [
            "responses": responseCoverageAudit.responses.count,
            "materialResponses": responseCoverageAudit.materialResponses.count,
            "croppedMaterialResponses": responseCoverageAudit.croppedMaterialResponses.count,
            "croppedActionIDs": Array(Set(
                responseCoverageAudit.croppedMaterialResponses.map(\.actionID)
            )).sorted()
        ],
        "responses": responseCoverageEntries
    ]
    let responseCoverageData = try JSONSerialization.data(
        withJSONObject: responseCoverageReport,
        options: [.prettyPrinted, .sortedKeys]
    )
    let responseCoverageURL = output.deletingPathExtension()
        .appendingPathExtension("response-coverage-blame.json")
    try responseCoverageData.write(to: responseCoverageURL, options: .atomic)
    print("native response coverage blame=\(responseCoverageURL.path) cropped=\(responseCoverageAudit.croppedMaterialResponses.count)")
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
        "version": 4,
        "planner": plan.diagnostics.plannerVersion,
        "canvas": ["width": logicalOutputSize.width, "height": logicalOutputSize.height],
        "contentRect": [
            "x": contentRect.minX, "y": contentRect.minY,
            "width": contentRect.width, "height": contentRect.height
        ],
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
        "trajectory": stride(
            from: 0,
            to: frameCameras.count,
            by: max(1, Int(fps) / 10)
        ).map { index in
            let camera = frameCameras[index]
            return [
                "outputTime": Double(index) / Double(fps),
                "x": camera.x,
                "y": camera.y,
                "scale": exp(camera.logScale)
            ]
        },
        "causalOrdering": [
            "checks": causalOrdering,
            "violations": causalOrdering.filter { ($0["valid"] as? Bool) != true }.count
        ],
        "semanticCoverage": [
            "sustainedResponses": sustainedResponses,
            "unframedSustainedResponses": sustainedResponses.filter { ($0["framed"] as? Bool) != true }.count
        ],
        "actionResponseCoverage": responseCoverageReport,
        "alignment": alignment
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    let url = output.deletingPathExtension().appendingPathExtension("camera-audit.json")
    try data.write(to: url, options: .atomic)
    print("native camera audit=\(url.path)")
}

private func writeGlobalProductionPlanReport(
    _ plan: GlobalProductionPlan,
    observations: [VisualMotionObservation],
    supportObservationIDs: Set<Int>,
    evaluationCondition: ProductionEvaluationCondition,
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
            "evidenceSources": decision.evidenceSources.map(\.rawValue),
            "observationClass": decision.observationClass?.rawValue ?? NSNull(),
            "arrivalPose": camera(decision.arrivalPose),
            "responsePose": camera(decision.pose),
            "cumulativeCost": decision.cumulativeCost
        ]
    }
    let explained = Set(plan.decisions.flatMap(\.observationIDs))
    let observationReport: [[String: Any]] = observations.indices.map { observationID in
        let observation = observations[observationID]
        let observationClass: PlannerObservationClass
        if supportObservationIDs.contains(observationID) {
            observationClass = .oracleForegroundSupport
        } else {
            observationClass = switch observation.kind {
            case .contextTransition: .requiredContext
            case .focus: .foregroundEditorial
            case .appearance, .transformation, .translation: .motionEditorial
            }
        }
        return [
            "id": observationID,
            "class": observationClass.rawValue,
            "kind": observation.kind.rawValue,
            "startTime": observation.startTime,
            "endTime": observation.time,
            "explained": explained.contains(observationID),
            "bounds": [
                "x": observation.normalizedBounds.minX,
                "y": observation.normalizedBounds.minY,
                "width": observation.normalizedBounds.width,
                "height": observation.normalizedBounds.height
            ]
        ]
    }
    var report: [String: Any] = [
        "version": 2,
        "planner": plan.camera.diagnostics.plannerVersion,
        "evaluationCondition": evaluationCondition.rawValue,
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
        "observations": observationReport,
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
        "responseCoverageConstraints": plan.responseCoverageConstraints.map { constraint in
            [
                "actionID": constraint.actionID,
                "sourceStart": constraint.sourceRange.lowerBound,
                "sourceEnd": constraint.sourceRange.upperBound,
                "evidenceIDs": constraint.evidenceIDs,
                "relativeSignal": constraint.relativeSignal,
                "bounds": [
                    "x": constraint.normalizedBounds.minX,
                    "y": constraint.normalizedBounds.minY,
                    "width": constraint.normalizedBounds.width,
                    "height": constraint.normalizedBounds.height
                ]
            ] as [String: Any]
        },
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
                "framingEligibleAt": subject.framingEligibleAt ?? NSNull(),
                "actionIDs": subject.actionIDs,
                "observationIDs": subject.observationIDs.sorted(),
                "confidence": subject.confidence,
                "isForegroundSupport": subject.isForegroundSupport,
                "requiresOverview": subject.requiresOverview,
                "overviewBlame": subject.overviewBlame.map { blame in
                    ["actions": blame.actions.map { evidence in
                        [
                            "actionID": evidence.actionID,
                            "broadObservationIDs": evidence.broadObservationIDs.sorted(),
                            "preexistingBroadObservationIDs": evidence.preexistingBroadObservationIDs.sorted(),
                            "broadResponseEvidenceIDs": evidence.broadResponseEvidence.map(\.id),
                            "preexistingResponseEvidenceIDs": evidence.preexistingResponseEvidence.map(\.id),
                            "crossBoundaryResponseEvidenceIDs": evidence.crossBoundaryResponseEvidence.map(\.id),
                            "broadWeight": evidence.broadWeight,
                            "localizedObservationIDs": evidence.localizedObservationIDs.sorted(),
                            "localizedWeight": evidence.localizedWeight,
                            "causalBasis": evidence.causalBasis,
                            "reason": evidence.reason
                        ] as [String: Any]
                    }] as [String: Any]
                } ?? NSNull(),
                "verifiedReleaseTime": subject.verifiedReleaseTime ?? NSNull(),
                "framingHypotheses": subject.framingHypotheses.map { hypothesis in
                    [
                        "id": hypothesis.id,
                        "bounds": [
                            "x": hypothesis.bounds.minX, "y": hypothesis.bounds.minY,
                            "width": hypothesis.bounds.width, "height": hypothesis.bounds.height
                        ],
                        "observationIDs": hypothesis.observationIDs.sorted(),
                        "evidenceCoverage": hypothesis.evidenceCoverage
                    ] as [String: Any]
                }
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
        "objectCandidates": plan.objects.candidates.map { candidate in
            [
                "id": candidate.id,
                "source": candidate.source.rawValue,
                "bounds": [
                    "x": candidate.bounds.minX, "y": candidate.bounds.minY,
                    "width": candidate.bounds.width, "height": candidate.bounds.height
                ],
                "sourceStart": candidate.sourceRange.lowerBound,
                "sourceEnd": candidate.sourceRange.upperBound,
                "actionIDs": candidate.actionIDs,
                "observationIDs": candidate.observationIDs.sorted(),
                "confidence": candidate.confidence,
                "causalScore": candidate.causalScore
            ] as [String: Any]
        },
        "interactionEpisodes": plan.objects.episodes.map { episode in
            [
                "id": episode.id,
                "actionIDs": episode.actionIDs,
                "sourceStart": episode.sourceRange.lowerBound,
                "sourceEnd": episode.sourceRange.upperBound,
                "triggerCandidateID": episode.triggerCandidateID ?? NSNull(),
                "candidateIDs": episode.candidateIDs,
                "selectedResponseCandidateID": episode.selectedResponseCandidateID ?? NSNull()
            ] as [String: Any]
        },
        "shotScheduleObjectiveValue": plan.schedule.objectiveValue,
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

private func writeOverviewBlameReport(
    _ plan: ExperimentalProductionPlan,
    composition: NativeComposition,
    observations: [VisualMotionObservation],
    contentRect: CGRect,
    output: URL
) throws {
    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    func canvasBounds(_ observation: VisualMotionObservation) -> CGRect {
        CGRect(
            x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
            width: observation.normalizedBounds.width * contentRect.width,
            height: observation.normalizedBounds.height * contentRect.height
        )
    }
    func observationReport(ids: Set<Int>, relation: String) -> [[String: Any]] {
        ids.sorted().compactMap { observationID in
            guard observations.indices.contains(observationID) else { return nil }
            let observation = observations[observationID]
            return [
                "id": observationID,
                "relation": relation,
                "startTime": observation.startTime,
                "endTime": observation.time,
                "kind": observation.kind.rawValue,
                "normalizedBounds": rect(observation.normalizedBounds),
                "canvasBounds": rect(canvasBounds(observation)),
                "changedFraction": observation.changedFraction,
                "magnitude": observation.magnitude,
                "weight": max(0, observation.changedFraction)
                    * max(0.25, observation.magnitude)
            ] as [String: Any]
        }
    }
    func responseEvidenceReport(
        _ evidence: [SubjectGraph.Subject.OverviewBlame.ResponseEvidence],
        relation: String
    ) -> [[String: Any]] {
        evidence.map { item in
            let bounds = item.normalizedBounds
            let canvas = CGRect(
                x: contentRect.minX + bounds.minX * contentRect.width,
                y: contentRect.maxY - bounds.maxY * contentRect.height,
                width: bounds.width * contentRect.width,
                height: bounds.height * contentRect.height
            )
            return [
                "id": item.id,
                "relation": relation,
                "startTime": item.startTime,
                "endTime": item.endTime,
                "kind": item.kind.rawValue,
                "normalizedBounds": rect(bounds),
                "canvasBounds": rect(canvas),
                "changedFraction": item.changedFraction,
                "confidence": item.confidence,
                "weight": max(0, item.changedFraction) * max(0.25, item.confidence)
            ] as [String: Any]
        }
    }

    let constrained = plan.subjects.subjects.compactMap { subject -> [String: Any]? in
        guard let blame = subject.overviewBlame else { return nil }
        return [
            "subjectID": subject.id,
            "subjectKind": subject.kind.rawValue,
            "subjectBounds": rect(subject.bounds),
            "sourceStart": subject.sourceRange.lowerBound,
            "sourceEnd": subject.sourceRange.upperBound,
            "actionEvidence": blame.actions.map { evidence in
                let action = composition.actions.first { $0.id == evidence.actionID }
                return [
                    "actionID": evidence.actionID,
                    "actionKind": action?.kind ?? "unknown",
                    "actionSourceTime": action?.time ?? NSNull(),
                    "actionOutputTime": action.map {
                        composition.outputTime(atSourceTime: $0.time)
                    } ?? NSNull(),
                    "causalBasis": evidence.causalBasis,
                    "broadWeight": evidence.broadWeight,
                    "localizedWeight": evidence.localizedWeight,
                    "reason": evidence.reason,
                    "broadActionAligned": observationReport(
                        ids: evidence.broadObservationIDs,
                        relation: "action-aligned-by-onset"
                    ),
                    "broadAlreadyUnderway": observationReport(
                        ids: evidence.preexistingBroadObservationIDs,
                        relation: "already-underway-before-activation"
                    ),
                    "localizedResponse": observationReport(
                        ids: evidence.localizedObservationIDs,
                        relation: "localized-action-response"
                    ),
                    "broadExclusiveResponseSlice": responseEvidenceReport(
                        evidence.broadResponseEvidence,
                        relation: "exclusive-action-response-slice"
                    ),
                    "broadAlreadyUnderwayResponseSlice": responseEvidenceReport(
                        evidence.preexistingResponseEvidence,
                        relation: "already-underway-before-activation"
                    ),
                    "broadCrossBoundaryResponseSlice": responseEvidenceReport(
                        evidence.crossBoundaryResponseEvidence,
                        relation: "crosses-later-factual-activation"
                    )
                ] as [String: Any]
            }
        ] as [String: Any]
    }
    let report: [String: Any] = [
        "version": 2,
        "constrainedSubjectCount": constrained.count,
        "legend": [
            "yellow": "factual subject bounds",
            "red": "broad action-aligned response",
            "green": "localized action response",
            "blue": "broad motion already underway before activation",
            "magenta": "broad rolling interval crossing a later factual activation"
        ],
        "subjects": constrained
    ]
    let data = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    )
    let url = output.deletingPathExtension()
        .appendingPathExtension("overview-blame.json")
    try data.write(to: url, options: .atomic)
    print("native overview blame=\(url.path) constrained=\(constrained.count)")
}

private func writeActionResponseSliceReport(
    _ slices: [ActionResponseSlice],
    output: URL
) throws {
    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    func evidence(_ items: [ActionResponseSlice.Evidence]) -> [[String: Any]] {
        items.map { item in
            [
                "id": item.id,
                "sourceActionID": item.sourceActionID,
                "startTime": item.startTime,
                "endTime": item.endTime,
                "kind": item.kind.rawValue,
                "normalizedBounds": rect(item.normalizedBounds),
                "changedFraction": item.changedFraction,
                "confidence": item.confidence
            ] as [String: Any]
        }
    }
    let report: [String: Any] = [
        "version": 1,
        "invariant": "only exclusive evidence may constrain one action; preexisting and cross-boundary evidence remain diagnostic",
        "slices": slices.map { slice in
            [
                "actionID": slice.actionID,
                "activation": slice.activation,
                "exclusiveEnd": slice.exclusiveEnd,
                "exclusiveEvidence": evidence(slice.exclusiveEvidence),
                "preexistingEvidence": evidence(slice.preexistingEvidence),
                "crossBoundaryEvidence": evidence(slice.crossBoundaryEvidence)
            ] as [String: Any]
        }
    ]
    let data = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    )
    let url = output.deletingPathExtension()
        .appendingPathExtension("action-response-slices.json")
    try data.write(to: url, options: .atomic)
    let exclusive = slices.reduce(0) { $0 + $1.exclusiveEvidence.count }
    let crossBoundary = slices.reduce(0) { $0 + $1.crossBoundaryEvidence.count }
    print(
        "native action response slices=\(url.path) "
            + "exclusive=\(exclusive) crossBoundary=\(crossBoundary)"
    )
}

private func writeObjectBirthAudit(_ audit: ObjectBirthAudit, output: URL) throws {
    func rect(_ value: CGRect) -> [String: Double] {
        ["x": value.minX, "y": value.minY, "width": value.width, "height": value.height]
    }
    let births = audit.entries.map { entry -> [String: Any] in
        [
            "candidateID": entry.candidateID,
            "source": entry.source.rawValue,
            "birthTime": entry.birthTime,
            "deathTime": entry.deathTime,
            "bounds": rect(entry.bounds),
            "normalizedBounds": rect(entry.normalizedBounds),
            "actionIDs": entry.actionIDs,
            "status": entry.status.rawValue,
            "birthLagMilliseconds": entry.birthLagMilliseconds ?? NSNull(),
            "support": entry.support.map { support in
                [
                    "startTime": support.startTime,
                    "endTime": support.endTime,
                    "normalizedBounds": rect(support.normalizedBounds),
                    "overlap": support.overlap,
                    "changedFraction": support.changedFraction,
                    "localChangedDensity": support.localChangedDensity,
                    "confidence": support.confidence
                ] as [String: Any]
            }
        ]
    }
    let unsupported = audit.unsupportedVisualBirths
    let report: [String: Any] = [
        "version": 1,
        "invariant": "Every visually sourced object must have spatially overlapping motion evidence at its declared birth time.",
        "counts": [
            "total": audit.entries.count,
            "visual": audit.entries.filter { $0.status != .nonVisualEvidence }.count,
            "supportedVisual": audit.entries.filter { $0.status == .supported }.count,
            "unsupportedVisual": unsupported.count,
            "nonVisual": audit.entries.filter { $0.status == .nonVisualEvidence }.count
        ],
        "unsupportedVisualBirths": unsupported.map(\.candidateID),
        "births": births
    ]
    let data = try JSONSerialization.data(
        withJSONObject: report,
        options: [.prettyPrinted, .sortedKeys]
    )
    let url = output.deletingPathExtension().appendingPathExtension("object-births.json")
    try data.write(to: url, options: .atomic)
    print("native object birth audit=\(url.path) unsupported=\(unsupported.count)")
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
    debugContext: DirectorDebugContext?
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
    if let debugContext {
        let outputTime = (Double(frame) + 0.5) / Double(fps)
        let sourceTime = composition.sourceTime(atOutputTime: (Double(frame) + 0.5) / Double(fps))
        result = directorDebugOverlay(
            over: result,
            composition: composition,
            outputTime: outputTime,
            sourceTime: sourceTime,
            camera: centerCamera,
            debug: debugContext,
            contentRect: contentRect
        )
    }
    return result
}

func directorDebugOverlay(
    over background: CIImage,
    composition: NativeComposition,
    outputTime: Double,
    sourceTime: Double,
    camera: CameraState,
    debug: DirectorDebugContext,
    contentRect: CGRect
) -> CIImage {
    var result = background
    func projected(_ bounds: CGRect) -> CGRect {
        let a = projectPointThroughCamera(CGPoint(x: bounds.minX, y: bounds.minY), camera: camera, outputSize: logicalOutputSize)
        let b = projectPointThroughCamera(CGPoint(x: bounds.maxX, y: bounds.maxY), camera: camera, outputSize: logicalOutputSize)
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            .scaled(by: renderScale)
    }
    func canvasBounds(for observation: VisualMotionObservation) -> CGRect {
        CGRect(
            x: contentRect.minX + observation.normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - observation.normalizedBounds.maxY * contentRect.height,
            width: observation.normalizedBounds.width * contentRect.width,
            height: observation.normalizedBounds.height * contentRect.height
        )
    }
    func canvasBounds(for normalizedBounds: CGRect) -> CGRect {
        CGRect(
            x: contentRect.minX + normalizedBounds.minX * contentRect.width,
            y: contentRect.maxY - normalizedBounds.maxY * contentRect.height,
            width: normalizedBounds.width * contentRect.width,
            height: normalizedBounds.height * contentRect.height
        )
    }

    // Overview-blame diagnosis shows only the factual subject and the exact
    // evidence that vetoed a close-up. Yellow is the subject, red is broad
    // action-aligned response, green is localized response, and blue is broad
    // motion already underway before activation. The fixed camera keeps those
    // geometries in one coordinate system throughout the diagnostic render.
    if debug.overviewBlameOnly, let experimental = debug.experimental {
        for subject in experimental.subjects.subjects {
            guard let blame = subject.overviewBlame else { continue }
            let actionTimes = blame.actions.compactMap { evidence in
                composition.actions.first { $0.id == evidence.actionID }?.time
            }
            let observationIDs = Set(blame.actions.flatMap {
                $0.broadObservationIDs
                    .union($0.localizedObservationIDs)
                    .union($0.preexistingBroadObservationIDs)
            })
            let observations = observationIDs.compactMap {
                debug.planningObservations.indices.contains($0)
                    ? debug.planningObservations[$0] : nil
            }
            let responseEvidence = blame.actions.flatMap {
                $0.broadResponseEvidence
                    + $0.preexistingResponseEvidence
                    + $0.crossBoundaryResponseEvidence
            }
            let visibleStart = min(
                actionTimes.min() ?? subject.sourceRange.lowerBound,
                min(
                    observations.map(\.startTime).min() ?? subject.sourceRange.lowerBound,
                    responseEvidence.map(\.startTime).min() ?? subject.sourceRange.lowerBound
                )
            ) - 0.35
            let visibleEnd = max(
                actionTimes.max() ?? subject.sourceRange.upperBound,
                max(
                    observations.map(\.time).max() ?? subject.sourceRange.upperBound,
                    responseEvidence.map(\.endTime).max() ?? subject.sourceRange.upperBound
                )
            ) + 0.85
            guard sourceTime >= visibleStart, sourceTime <= visibleEnd else { continue }

            result = drawOutline(
                projected(subject.bounds),
                color: CIColor(red: 1, green: 0.82, blue: 0.08, alpha: 1),
                width: 7 * renderScale,
                over: result
            )
            for evidence in blame.actions {
                let layers: [(Set<Int>, CIColor, CGFloat)] = [
                    (
                        evidence.preexistingBroadObservationIDs,
                        CIColor(red: 0.12, green: 0.55, blue: 1, alpha: 0.95),
                        3
                    ),
                    (
                        evidence.broadObservationIDs,
                        CIColor(red: 1, green: 0.08, blue: 0.28, alpha: 0.98),
                        6
                    ),
                    (
                        evidence.localizedObservationIDs,
                        CIColor(red: 0.2, green: 1, blue: 0.42, alpha: 0.98),
                        4
                    )
                ]
                for (ids, color, width) in layers {
                    for observationID in ids where
                        debug.planningObservations.indices.contains(observationID) {
                        let observation = debug.planningObservations[observationID]
                        guard sourceTime >= observation.startTime - 0.35,
                              sourceTime <= observation.time + 0.85
                        else { continue }
                        result = drawOutline(
                            projected(canvasBounds(for: observation)),
                            color: color,
                            width: width * renderScale,
                            over: result
                        )
                    }
                }
                let responseLayers: [(
                    [SubjectGraph.Subject.OverviewBlame.ResponseEvidence], CIColor, CGFloat
                )] = [
                    (
                        evidence.preexistingResponseEvidence,
                        CIColor(red: 0.12, green: 0.55, blue: 1, alpha: 0.95),
                        3
                    ),
                    (
                        evidence.crossBoundaryResponseEvidence,
                        CIColor(red: 1, green: 0.12, blue: 0.82, alpha: 0.96),
                        4
                    ),
                    (
                        evidence.broadResponseEvidence,
                        CIColor(red: 1, green: 0.08, blue: 0.28, alpha: 0.98),
                        6
                    )
                ]
                for (items, color, width) in responseLayers {
                    for item in items {
                        guard sourceTime >= item.startTime - 0.35,
                              sourceTime <= item.endTime + 0.85
                        else { continue }
                        result = drawOutline(
                            projected(canvasBounds(for: item.normalizedBounds)),
                            color: color,
                            width: width * renderScale,
                            over: result
                        )
                    }
                }
            }
        }
        return result.cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    // The object-only diagnostic is intentionally austere: no raw detector
    // observations, legacy attention, subject graph, or camera ownership.
    // Those layers previously reused colors and made unrelated hypotheses look
    // like one detector. Each box is now visible only during that candidate's
    // own evidence interval.
    if debug.objectDetectionOnly, let experimental = debug.experimental {
        let selectedIDs = experimental.objects.selectedCandidateIDs(at: sourceTime)
        let birthStatus = Dictionary(uniqueKeysWithValues:
            (debug.objectBirthAudit?.entries ?? []).map { ($0.candidateID, $0.status) }
        )
        for candidate in experimental.objects.activeCandidates(at: sourceTime) {
            let color: CIColor
            if birthStatus[candidate.id] == .unsupported {
                color = CIColor(red: 1, green: 0.08, blue: 0.12, alpha: 0.98)
            } else {
                color = switch candidate.source {
                case .trigger: CIColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.85)
                case .semanticContainer: CIColor(red: 0.18, green: 0.55, blue: 1, alpha: 0.95)
                case .visualLifecycle: CIColor(red: 0.35, green: 1, blue: 0.25, alpha: 0.95)
                case .visualResidual: CIColor(red: 1, green: 0.52, blue: 0.08, alpha: 0.9)
                }
            }
            result = drawOutline(
                projected(candidate.bounds), color: color,
                width: (selectedIDs.contains(candidate.id) ? 7 : 3) * renderScale,
                over: result
            )
        }
        return result
    }

    // Layer 1: raw detector output. These boxes answer only "what changed?"
    // and never imply that the camera selected the region.
    for observation in debug.rawObservations where
        abs(observation.time - sourceTime) <= 0.9
        && SpatialMotion.isFramingEligible(observation) {
        let color: CIColor = switch observation.kind {
        case .translation: CIColor(red: 0.1, green: 0.55, blue: 1, alpha: 0.9)
        case .contextTransition: CIColor(red: 0.72, green: 0.32, blue: 1, alpha: 0.95)
        default: CIColor(red: 1, green: 0.18, blue: 0.32, alpha: 0.9)
        }
        result = drawOutline(
            projected(canvasBounds(for: observation)),
            color: color, width: 2 * renderScale, over: result
        )
    }

    // Layer 2: externally injected foreground-support endpoints. They are
    // intentionally separate from raw motion so an oracle cannot masquerade
    // as detector success in a diagnostic render.
    for observationID in debug.supportObservationIDs.sorted() where
        debug.planningObservations.indices.contains(observationID) {
        let observation = debug.planningObservations[observationID]
        guard abs(observation.time - sourceTime) <= 0.9 else { continue }
        result = drawOutline(
            projected(canvasBounds(for: observation)),
            color: CIColor(red: 0.95, green: 0.2, blue: 1, alpha: 0.95),
            width: 4 * renderScale,
            over: result
        )
    }

    // Factual/per-action evidence remains useful, but its legacy aggregate is
    // no longer colored cyan when the experimental subject scheduler owns the
    // camera. Cyan is reserved for the actual selected subject below.
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
        if debug.experimental == nil {
            result = drawOutline(
                projected(attention.bounds),
                color: CIColor(red: 0.1, green: 0.95, blue: 1, alpha: 1),
                width: 5 * renderScale, over: result
            )
        }
    }

    if let experimental = debug.experimental {
        let selectedObjectIDs = experimental.objects.selectedCandidateIDs(at: sourceTime)
        for candidate in experimental.objects.activeCandidates(at: sourceTime) {
            let color: CIColor = switch candidate.source {
            case .trigger: CIColor(red: 1, green: 0.8, blue: 0.1, alpha: 0.75)
            case .semanticContainer: CIColor(red: 0.18, green: 0.55, blue: 1, alpha: 0.95)
            case .visualLifecycle: CIColor(red: 0.35, green: 1, blue: 0.25, alpha: 0.95)
            case .visualResidual: CIColor(red: 1, green: 0.52, blue: 0.08, alpha: 0.85)
            }
            result = drawOutline(
                projected(candidate.bounds), color: color,
                width: (selectedObjectIDs.contains(candidate.id) ? 7 : 3) * renderScale,
                over: result
            )
        }
        let activeSubjects = experimental.subjects.subjects.filter {
            $0.sourceRange.contains(sourceTime)
        }
        for subject in activeSubjects {
            let color = subject.isForegroundSupport
                ? CIColor(red: 0.95, green: 0.2, blue: 1, alpha: 0.90)
                : CIColor(red: 1, green: 0.52, blue: 0.08, alpha: 0.85)
            result = drawOutline(
                projected(subject.bounds), color: color,
                width: 3 * renderScale, over: result
            )
        }

        // Shot intervals may overlap because they retain semantic ownership.
        // The most recently started active shot is the scheduler's current
        // owner and therefore the only region entitled to the thick cyan box.
        let selectedShot = experimental.schedule.selectedShot(at: outputTime)
        if let shot = selectedShot,
           let subjectID = shot.subjectID,
           let subject = experimental.subjects.subjects.first(where: { $0.id == subjectID }) {
            result = drawOutline(
                projected(subject.bounds),
                color: CIColor(red: 0.05, green: 0.95, blue: 1, alpha: 1),
                width: 6 * renderScale, over: result
            )
            let scale = exp(shot.pose.logScale)
            let targetViewport = CGRect(
                x: shot.pose.x - logicalOutputSize.width / (2 * scale),
                y: shot.pose.y - logicalOutputSize.height / (2 * scale),
                width: logicalOutputSize.width / scale,
                height: logicalOutputSize.height / scale
            )
            result = drawOutline(
                projected(targetViewport),
                color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.9),
                width: 2 * renderScale, over: result
            )
        }
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

func writeDirectorDebugReport(
    composition: NativeComposition,
    motionAnalysis: MotionAnalysis,
    planningObservations: [VisualMotionObservation],
    supportObservationIDs: Set<Int>,
    experimental: ExperimentalProductionPlan?,
    output: URL
) throws {
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
        "legend": [
            "selectedExperimentalSubject": "thick-cyan",
            "selectedShotViewport": "white",
            "verifiedForegroundSupport": "violet",
            "inferredActiveSubject": "orange",
            "rawAppearanceOrFocus": "red",
            "rawTranslation": "blue",
            "rawContextTransition": "purple",
            "pointer": "yellow",
            "visualPointerOrDrag": "orange",
            "accessibility": "green",
            "legacyVisualResponse": "magenta",
            "legacyVisualFocus": "mint",
            "episodeSemanticContainer": "blue",
            "episodeVisualLifecycle": "lime",
            "selectedEpisodeResponse": "thick-source-color"
        ],
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
                if let polarity = observation.polarity {
                    item["polarity"] = polarity.rawValue
                }
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
        ] as [String: Any],
        "planningEvidence": planningObservations.indices.map { observationID in
            let observation = planningObservations[observationID]
            var item: [String: Any] = [
                "id": observationID,
                "source": supportObservationIDs.contains(observationID)
                    ? "verified-foreground-support" : "raw-detector",
                "time": observation.time,
                "startTime": observation.startTime,
                "kind": observation.kind.rawValue,
                "bounds": rect(observation.normalizedBounds)
            ]
            if let transition = observation.focusTransition {
                item["focusTransition"] = transition.rawValue
            }
            return item
        },
        "experimental": experimental.map { plan in
            [
                "subjects": plan.subjects.subjects.map { subject in
                    [
                        "id": subject.id,
                        "kind": subject.kind.rawValue,
                        "sourceStart": subject.sourceRange.lowerBound,
                        "sourceEnd": subject.sourceRange.upperBound,
                        "framingEligibleAt": subject.framingEligibleAt ?? NSNull(),
                        "verifiedReleaseTime": subject.verifiedReleaseTime ?? NSNull(),
                        "isForegroundSupport": subject.isForegroundSupport,
                        "requiresOverview": subject.requiresOverview,
                        "overviewBlame": subject.overviewBlame.map { blame in
                            ["actions": blame.actions.map { evidence in
                                [
                                    "actionID": evidence.actionID,
                                    "broadObservationIDs": evidence.broadObservationIDs.sorted(),
                                    "preexistingBroadObservationIDs": evidence.preexistingBroadObservationIDs.sorted(),
                                    "broadResponseEvidenceIDs": evidence.broadResponseEvidence.map(\.id),
                                    "preexistingResponseEvidenceIDs": evidence.preexistingResponseEvidence.map(\.id),
                                    "crossBoundaryResponseEvidenceIDs": evidence.crossBoundaryResponseEvidence.map(\.id),
                                    "broadWeight": evidence.broadWeight,
                                    "localizedObservationIDs": evidence.localizedObservationIDs.sorted(),
                                    "localizedWeight": evidence.localizedWeight,
                                    "causalBasis": evidence.causalBasis,
                                    "reason": evidence.reason
                                ] as [String: Any]
                            }] as [String: Any]
                        } ?? NSNull(),
                        "bounds": rect(subject.bounds),
                        "actionIDs": subject.actionIDs,
                        "observationIDs": subject.observationIDs.sorted(),
                        "framingHypotheses": subject.framingHypotheses.map { hypothesis in
                            [
                                "id": hypothesis.id,
                                "bounds": rect(hypothesis.bounds),
                                "observationIDs": hypothesis.observationIDs.sorted(),
                                "evidenceCoverage": hypothesis.evidenceCoverage
                            ] as [String: Any]
                        }
                    ] as [String: Any]
                },
                "objectCandidates": plan.objects.candidates.map { candidate in
                    [
                        "id": candidate.id,
                        "source": candidate.source.rawValue,
                        "sourceStart": candidate.sourceRange.lowerBound,
                        "sourceEnd": candidate.sourceRange.upperBound,
                        "bounds": rect(candidate.bounds),
                        "actionIDs": candidate.actionIDs,
                        "observationIDs": candidate.observationIDs.sorted(),
                        "confidence": candidate.confidence,
                        "causalScore": candidate.causalScore
                    ] as [String: Any]
                },
                "interactionEpisodes": plan.objects.episodes.map { episode in
                    [
                        "id": episode.id,
                        "actionIDs": episode.actionIDs,
                        "sourceStart": episode.sourceRange.lowerBound,
                        "sourceEnd": episode.sourceRange.upperBound,
                        "triggerCandidateID": episode.triggerCandidateID ?? NSNull(),
                        "candidateIDs": episode.candidateIDs,
                        "selectedResponseCandidateID": episode.selectedResponseCandidateID ?? NSNull()
                    ] as [String: Any]
                },
                "objectiveValue": plan.schedule.objectiveValue,
                "shots": plan.schedule.shots.map { shot in
                    [
                        "id": shot.id,
                        "subjectID": shot.subjectID ?? NSNull(),
                        "intent": shot.intent.rawValue,
                        "outputStart": shot.interval.lowerBound,
                        "outputEnd": shot.interval.upperBound,
                        "pose": [
                            "x": shot.pose.x,
                            "y": shot.pose.y,
                            "scale": exp(shot.pose.logScale)
                        ]
                    ] as [String: Any]
                }
            ] as [String: Any]
        } ?? NSNull()
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

func loadCursorMetadata(_ metadataURL: URL) throws -> CursorMetadata {
    return try JSONDecoder().decode(CursorMetadata.self, from: Data(contentsOf: metadataURL))
}

func parseHexColor(_ value: String) throws -> CIColor {
    let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6 || raw.count == 8, let number = UInt64(raw, radix: 16) else {
        throw Failure("--background-color must be #RRGGBB or #RRGGBBAA")
    }
    let alpha: CGFloat = raw.count == 8 ? CGFloat(number & 0xff) / 255 : 1
    let shifted = raw.count == 8 ? number >> 8 : number
    return CIColor(
        red: CGFloat((shifted >> 16) & 0xff) / 255,
        green: CGFloat((shifted >> 8) & 0xff) / 255,
        blue: CGFloat(shifted & 0xff) / 255,
        alpha: alpha
    )
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
