import AVFoundation
import AppKit
import CoreMedia
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
    private let lock = NSLock()
    private var firstPresentationTime: CMTime?
    private var lastPresentationTime: CMTime?
    private var frameCount = 0
    private var droppedNonMonotonicFrameCount = 0
    private var appendError: Error?

    init(outputURL: URL, width: Int, height: Int, codec: CaptureCodec) throws {
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
        guard isCompleteFrame(sampleBuffer) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard appendError == nil else { return }
        guard input.isReadyForMoreMediaData else { return }

        let presentationTime = sampleBuffer.presentationTimeStamp
        guard presentationTime.isValid, presentationTime.isNumeric else { return }
        if let lastPresentationTime,
           CMTimeCompare(presentationTime, lastPresentationTime) <= 0
        {
            // ScreenCaptureKit may emit multiple complete window frames with the
            // same timestamp while native-app child windows and popovers change.
            // AVAssetWriter can accept those samples but produce a stream with
            // duplicate DTS values that AVAssetReader later refuses to decode.
            droppedNonMonotonicFrameCount += 1
            return
        }
        var firstFrameMessage: String?
        if firstPresentationTime == nil {
            firstPresentationTime = presentationTime
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer, createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]]
            let info = attachments?.first
            let scaleFactor = (info?[.scaleFactor] as? NSNumber)?.doubleValue ?? .nan
            let contentScale = (info?[.contentScale] as? NSNumber)?.doubleValue ?? .nan
            let bufferWidth = CMSampleBufferGetImageBuffer(sampleBuffer).map(CVPixelBufferGetWidth) ?? 0
            let bufferHeight = CMSampleBufferGetImageBuffer(sampleBuffer).map(CVPixelBufferGetHeight) ?? 0
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let wallTime = formatter.string(from: Date())
            firstFrameMessage =
                "CAPTURE_FRAME buffer=\(bufferWidth)x\(bufferHeight) " +
                    "scaleFactor=\(scaleFactor) contentScale=\(contentScale) " +
                    "wallTime=\(wallTime) ptsSeconds=\(presentationTime.seconds)\n"
            writer.startSession(atSourceTime: presentationTime)
        }

        if input.append(sampleBuffer) {
            lastPresentationTime = presentationTime
            frameCount += 1
            if let firstFrameMessage { writeStandardOutput(firstFrameMessage) }
        } else {
            appendError = writer.error ?? CaptureError.writerSetup("Failed to append a video frame")
        }
    }

    func finish() async throws -> (frameCount: Int, droppedNonMonotonicFrameCount: Int) {
        let result: (count: Int, dropped: Int, error: Error?) = lock.withLock {
            input.markAsFinished()
            return (frameCount, droppedNonMonotonicFrameCount, appendError)
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
        return (result.count, result.dropped)
    }

    private func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard
            let attachments = CMSampleBufferGetSampleAttachmentsArray(
                sampleBuffer,
                createIfNecessary: false
            ) as? [[SCStreamFrameInfo: Any]],
            let statusValue = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: statusValue)
        else {
            return false
        }
        return status == .complete
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
                width: width,
                height: height,
                codec: options.codec
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
                    "output=\(options.outputURL.path)\n"
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
