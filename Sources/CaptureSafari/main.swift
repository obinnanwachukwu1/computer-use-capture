import AVFoundation
import AppKit
import CoreMedia
import CaptureTruth
import Darwin
import Foundation
import ScreenCaptureKit

struct CaptureOptions {
    let outputURL: URL
    let duration: TimeInterval
    let bundleIdentifier: String
    let framesPerSecond: Int32
    let mode: CaptureMode
    let codec: CaptureCodec

    static func parse() throws -> CaptureOptions {
        let arguments = CommandLine.arguments
        guard arguments.count >= 2 else {
            throw CaptureError.usage("Usage: capture-app <output.mov> [duration-seconds] [bundle-id]")
        }

        let outputURL = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let duration = arguments.count >= 3 ? TimeInterval(arguments[2]) ?? 6 : 6
        guard duration > 0 else {
            throw CaptureError.usage("Duration must be greater than zero")
        }
        let bundleIdentifier = arguments.count >= 4 ? arguments[3] : "com.apple.Safari"
        guard bundleIdentifier.contains(".") else {
            throw CaptureError.usage("The target app must be a macOS bundle identifier")
        }

        let modeName = ProcessInfo.processInfo.environment["AGENTRECORDER_CAPTURE_MODE"] ?? "application"
        guard let mode = CaptureMode(rawValue: modeName) else {
            throw CaptureError.usage(
                "AGENTRECORDER_CAPTURE_MODE must be 'application' or 'window'"
            )
        }
        let codecName = ProcessInfo.processInfo.environment["AGENTRECORDER_CAPTURE_CODEC"] ?? "hevc"
        guard let codec = CaptureCodec(rawValue: codecName) else {
            throw CaptureError.usage(
                "AGENTRECORDER_CAPTURE_CODEC must be 'hevc', 'h264', 'prores422lt', or 'prores4444'"
            )
        }

        return CaptureOptions(
            outputURL: outputURL,
            duration: duration,
            bundleIdentifier: bundleIdentifier,
            framesPerSecond: 60,
            mode: mode,
            codec: codec
        )
    }
}

enum CaptureMode: String {
    case application
    case window
}

enum CaptureCodec: String {
    case hevc
    case h264
    case prores422lt
    case prores4444

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .prores422lt: .proRes422LT
        case .prores4444: .proRes4444
        }
    }

    var compressionProperties: [String: Any]? {
        switch self {
        case .hevc:
            [
                AVVideoAverageBitRateKey: 32_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
            ]
        case .h264:
            [
                AVVideoAverageBitRateKey: 40_000_000,
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ]
        case .prores422lt, .prores4444:
            nil
        }
    }
}

enum CaptureError: LocalizedError {
    case usage(String)
    case targetWindowNotFound(String)
    case targetWindowAmbiguous(String, Int)
    case writerSetup(String)
    case noFrames

    var errorDescription: String? {
        switch self {
        case .usage(let message), .writerSetup(let message):
            return message
        case .targetWindowNotFound(let bundleIdentifier):
            return "No eligible onscreen window was found for \(bundleIdentifier)"
        case .targetWindowAmbiguous(let bundleIdentifier, let count):
            return "Expected one eligible onscreen window for \(bundleIdentifier), found \(count)"
        case .noFrames:
            return "ScreenCaptureKit did not deliver any complete frames"
        }
    }
}

final class MovieWriter: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let provenanceURL: URL
    private let expectedFrameInterval: Double
    private let lock = NSLock()
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var frameCount = 0
    private var droppedNonMonotonicFrameCount = 0
    private var droppedBackpressureFrameCount = 0
    private var appendFailedFrameCount = 0
    private var invalidMetadataSampleCount = 0
    private var preRollSampleCount = 0
    private var provenanceSamples: [CapturedFrameSample] = []
    private var previousFramePixels: [UInt8]?
    private var appendError: Error?

    init(
        outputURL: URL,
        provenanceURL: URL,
        width: Int,
        height: Int,
        codec: CaptureCodec,
        framesPerSecond: Int32
    ) throws {
        self.provenanceURL = provenanceURL
        expectedFrameInterval = 1 / Double(framesPerSecond)
        try? FileManager.default.removeItem(at: outputURL)
        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        if let properties = codec.compressionProperties {
            outputSettings[AVVideoCompressionPropertiesKey] = properties
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw CaptureError.writerSetup("AVAssetWriter rejected the video input")
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? CaptureError.writerSetup("AVAssetWriter failed to start")
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen, sampleBuffer.isValid else { return }
        guard let metadata = frameMetadata(sampleBuffer) else {
            lock.withLock { invalidMetadataSampleCount += 1 }
            return
        }
        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid, presentationTime.isNumeric else {
            lock.withLock { invalidMetadataSampleCount += 1 }
            return
        }

        lock.lock()
        defer { lock.unlock() }
        guard appendError == nil else { return }
        if firstPresentationTime == nil, metadata.status != .complete {
            preRollSampleCount += 1
            return
        }
        if firstPresentationTime == nil, !input.isReadyForMoreMediaData {
            // Capture time zero is the first committed frame, never a frame
            // that backpressure prevented from entering the source movie.
            droppedBackpressureFrameCount += 1
            return
        }
        var firstFrameMessage: String?
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            let bufferWidth = CMSampleBufferGetImageBuffer(sampleBuffer).map(CVPixelBufferGetWidth) ?? 0
            let bufferHeight = CMSampleBufferGetImageBuffer(sampleBuffer).map(CVPixelBufferGetHeight) ?? 0
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let callbackHostTime = mach_absolute_time()
            let displayDelay = metadata.displayTime.map {
                hostTimeSeconds(callbackHostTime &- min(callbackHostTime, $0))
            } ?? 0
            // Anchor the action log to when WindowServer displayed the first
            // frame, not to when this callback happened to run.
            let wallTime = formatter.string(from: Date().addingTimeInterval(-displayDelay))
            firstFrameMessage =
                "CAPTURE_FRAME buffer=\(bufferWidth)x\(bufferHeight) " +
                    "scaleFactor=\(metadata.scaleFactor) contentScale=\(metadata.contentScale) " +
                    "wallTime=\(wallTime) ptsSeconds=\(presentationTime.seconds)\n"
            writer.startSession(atSourceTime: presentationTime)
        }

        guard let firstPresentationTime else { return }
        let sourceTime = max(0, CMTimeSubtract(presentationTime, firstPresentationTime).seconds)
        let pixelComparison = compareCapturedPixels(sampleBuffer)
        var disposition: FrameWriterDisposition = .notApplicable
        if metadata.status == .complete {
            if let lastPresentationTime,
               CMTimeCompare(presentationTime, lastPresentationTime) <= 0
            {
                // Retain this as an integrity failure in the provenance ledger.
                // A later reducer must not infer idleness across the dropped frame.
                droppedNonMonotonicFrameCount += 1
                disposition = .droppedNonMonotonic
            } else if !input.isReadyForMoreMediaData {
                droppedBackpressureFrameCount += 1
                disposition = .droppedBackpressure
            } else if input.append(sampleBuffer) {
                lastPresentationTime = presentationTime
                frameCount += 1
                disposition = .appended
                if let firstFrameMessage { writeStandardOutput(firstFrameMessage) }
            } else {
                appendFailedFrameCount += 1
                disposition = .appendFailed
                appendError = writer.error ?? CaptureError.writerSetup("Failed to append a video frame")
            }
        }
        provenanceSamples.append(CapturedFrameSample(
            sourceTime: sourceTime,
            displayTime: metadata.displayTime,
            status: metadata.status,
            dirtyRects: metadata.dirtyRects,
            writerDisposition: disposition,
            pixelComparison: pixelComparison
        ))
    }

    func finish() async throws -> (
        frameCount: Int,
        droppedNonMonotonicFrameCount: Int,
        droppedBackpressureFrameCount: Int
    ) {
        let result: (
            count: Int,
            nonMonotonic: Int,
            backpressure: Int,
            ledger: CaptureFrameLedger,
            error: Error?
        ) = lock.withLock {
            input.markAsFinished()
            return (
                frameCount,
                droppedNonMonotonicFrameCount,
                droppedBackpressureFrameCount,
                CaptureFrameLedger(
                    expectedFrameInterval: expectedFrameInterval,
                    samples: provenanceSamples,
                    integrity: CaptureIntegrity(
                        invalidMetadataSamples: invalidMetadataSampleCount,
                        preRollSamples: preRollSampleCount,
                        droppedBackpressureFrames: droppedBackpressureFrameCount,
                        droppedNonMonotonicFrames: droppedNonMonotonicFrameCount,
                        appendFailedFrames: appendFailedFrameCount
                    )
                ),
                appendError
            )
        }
        if let error = result.error {
            writer.cancelWriting()
            throw error
        }
        guard result.count > 0 else {
            writer.cancelWriting()
            throw CaptureError.noFrames
        }

        await writer.finishWriting()
        if let error = writer.error {
            throw error
        }
        try writeProvenance(result.ledger)
        return (result.count, result.nonMonotonic, result.backpressure)
    }

    private struct FrameMetadata {
        let status: CapturedFrameStatus
        let displayTime: UInt64?
        let dirtyRects: [CaptureDamageRect]
        let scaleFactor: Double
        let contentScale: Double
    }

    private func frameMetadata(_ sampleBuffer: CMSampleBuffer) -> FrameMetadata? {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusValue)
        else {
            return nil
        }
        let info = attachments[0]
        let dirtyRects = (info[.dirtyRects] as? [NSValue] ?? []).map { value in
            let rect = value.rectValue
            return CaptureDamageRect(
                x: rect.minX, y: rect.minY, width: rect.width, height: rect.height
            )
        }
        return FrameMetadata(
            status: capturedStatus(status),
            displayTime: (info[.displayTime] as? NSNumber)?.uint64Value,
            dirtyRects: dirtyRects,
            scaleFactor: (info[.scaleFactor] as? NSNumber)?.doubleValue ?? .nan,
            contentScale: (info[.contentScale] as? NSNumber)?.doubleValue ?? .nan
        )
    }

    private func capturedStatus(_ status: SCFrameStatus) -> CapturedFrameStatus {
        switch status {
        case .complete: .complete
        case .idle: .idle
        case .blank: .blank
        case .suspended: .suspended
        case .started: .started
        case .stopped: .stopped
        @unknown default: .unknown
        }
    }

    /// Exhaustively compares every active BGRA byte before encoding. This is
    /// not an editorial motion threshold: `identical` means the actual pixels
    /// available to the recorder did not change between delivered frames.
    private func compareCapturedPixels(_ sampleBuffer: CMSampleBuffer) -> CapturedPixelComparison {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return .unavailable }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            return .unavailable
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .unavailable }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let activeRowBytes = width * 4
        guard activeRowBytes <= rowBytes, height > 0 else { return .unavailable }

        let required = activeRowBytes * height
        if previousFramePixels?.count != required {
            previousFramePixels = [UInt8](repeating: 0, count: required)
            previousFramePixels!.withUnsafeMutableBytes { destination in
                for row in 0..<height {
                    memcpy(
                        destination.baseAddress!.advanced(by: row * activeRowBytes),
                        base.advanced(by: row * rowBytes),
                        activeRowBytes
                    )
                }
            }
            return .unavailable
        }

        let identical = previousFramePixels!.withUnsafeBytes { previous in
            for row in 0..<height where memcmp(
                previous.baseAddress!.advanced(by: row * activeRowBytes),
                base.advanced(by: row * rowBytes),
                activeRowBytes
            ) != 0 {
                return false
            }
            return true
        }
        guard !identical else { return .identical }
        previousFramePixels!.withUnsafeMutableBytes { destination in
            for row in 0..<height {
                memcpy(
                    destination.baseAddress!.advanced(by: row * activeRowBytes),
                    base.advanced(by: row * rowBytes),
                    activeRowBytes
                )
            }
        }
        return .changed
    }

    private func writeProvenance(_ ledger: CaptureFrameLedger) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(ledger)
        let temporary = provenanceURL.appendingPathExtension("tmp-\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: temporary, options: .atomic)
        try? FileManager.default.removeItem(at: provenanceURL)
        try FileManager.default.moveItem(at: temporary, to: provenanceURL)
    }
}

@main
struct CaptureApp {
    static func main() async {
        do {
            _ = NSApplication.shared
            let options = try CaptureOptions.parse()
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            let targetWindows = content.windows
                .filter({ $0.owningApplication?.bundleIdentifier == options.bundleIdentifier })
                .filter({ $0.frame.width >= 320 && $0.frame.height >= 240 })
            guard !targetWindows.isEmpty else {
                throw CaptureError.targetWindowNotFound(options.bundleIdentifier)
            }
            guard targetWindows.count == 1 else {
                throw CaptureError.targetWindowAmbiguous(options.bundleIdentifier, targetWindows.count)
            }
            let targetWindow = targetWindows[0]
            guard let targetApplication = targetWindow.owningApplication else {
                throw CaptureError.writerSetup("Target window has no owning application")
            }

            let windowCenter = CGPoint(x: targetWindow.frame.midX, y: targetWindow.frame.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(windowCenter) }) else {
                throw CaptureError.writerSetup("Could not resolve the display containing the target window")
            }

            let filter: SCContentFilter
            switch options.mode {
            case .application:
                filter = SCContentFilter(
                    display: display,
                    including: [targetApplication],
                    exceptingWindows: []
                )
            case .window:
                filter = SCContentFilter(desktopIndependentWindow: targetWindow)
            }
            let pointPixelScale = CGFloat(filter.pointPixelScale)
            let width = max(2, Int(ceil(targetWindow.frame.width * pointPixelScale))) & ~1
            let height = max(2, Int(ceil(targetWindow.frame.height * pointPixelScale))) & ~1
            let configuration = SCStreamConfiguration()
            configuration.width = width
            configuration.height = height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: options.framesPerSecond)
            configuration.queueDepth = 8
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.showsCursor = false
            configuration.captureResolution = .best
            // Shadows are authored by the compositor so they remain consistent across
            // application-filter and strict single-window capture modes.
            configuration.ignoreShadowsDisplay = true
            configuration.ignoreShadowsSingleWindow = true
            configuration.scalesToFit = false
            configuration.preservesAspectRatio = true
            if options.mode == .application {
                configuration.sourceRect = CGRect(
                    x: targetWindow.frame.minX - display.frame.minX,
                    y: targetWindow.frame.minY - display.frame.minY,
                    width: targetWindow.frame.width,
                    height: targetWindow.frame.height
                )
            }
            let movieWriter = try MovieWriter(
                outputURL: options.outputURL,
                provenanceURL: options.outputURL.deletingPathExtension().appendingPathExtension("capture.json"),
                width: width,
                height: height,
                codec: options.codec,
                framesPerSecond: options.framesPerSecond
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let outputQueue = DispatchQueue(label: "agentrecorder.capture.video", qos: .userInteractive)
            try stream.addStreamOutput(movieWriter, type: .screen, sampleHandlerQueue: outputQueue)

            try await stream.startCapture()
            writeStandardOutput(
                "CAPTURE_READY app=\(options.bundleIdentifier) window=\(targetWindow.title ?? "Untitled") " +
                    "size=\(width)x\(height) scale=\(pointPixelScale) " +
                    "mode=\(options.mode.rawValue) codec=\(options.codec.rawValue)\n"
            )
            let stopReason = await waitForStopOrTimeout(seconds: options.duration)
            try await stream.stopCapture()
            let result = try await movieWriter.finish()
            writeStandardOutput(
                "CAPTURE_COMPLETE reason=\(stopReason.rawValue) frames=\(result.frameCount) " +
                    "droppedNonMonotonicFrames=\(result.droppedNonMonotonicFrameCount) " +
                    "droppedBackpressureFrames=\(result.droppedBackpressureFrameCount) " +
                    "output=\(options.outputURL.path) " +
                    "provenance=\(options.outputURL.deletingPathExtension().appendingPathExtension("capture.json").path)\n"
            )
        } catch {
            FileHandle.standardError.write(Data("capture-app: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
    }
}


private func writeStandardOutput(_ message: String) {
    FileHandle.standardOutput.write(Data(message.utf8))
}

private func hostTimeSeconds(_ ticks: UInt64) -> Double {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return Double(ticks) * Double(info.numer) / Double(info.denom) / 1_000_000_000
}

private enum StopReason: String, Sendable { case requested, timeout }

private func waitForStopOrTimeout(seconds: TimeInterval) async -> StopReason {
    signal(SIGINT, SIG_IGN)
    let interrupts = AsyncStream<Void> { continuation in
        let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        source.setEventHandler {
            continuation.yield()
            continuation.finish()
        }
        source.resume()
        continuation.onTermination = { _ in source.cancel() }
    }

    return await withTaskGroup(of: StopReason.self) { group in
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return .timeout
        }
        group.addTask {
            for await _ in interrupts {
                return .requested
            }
            return .requested
        }
        let reason = await group.next() ?? .timeout
        group.cancelAll()
        return reason
    }
}
