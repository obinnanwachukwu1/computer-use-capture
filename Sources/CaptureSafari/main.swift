import AVFoundation
import AppKit
import CoreMedia
import CaptureTruth
import Darwin
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

struct CaptureOptions {
    let outputURL: URL
    let duration: TimeInterval
    let bundleIdentifier: String
    let targetWindowTitle: String?
    let framesPerSecond: Int32
    let mode: CaptureMode
    let codec: CaptureCodec
    let diagnosticCheckpointInterval: TimeInterval?
    let diagnosticCheckpointDirectory: URL?
    let diagnosticCheckpointLimit: Int

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

        let modeName = ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_CAPTURE_MODE"] ?? "window-crop"
        guard let mode = CaptureMode(rawValue: modeName) else {
            throw CaptureError.usage(
                "COMPUTER_USE_CAPTURE_CAPTURE_MODE must be 'application', 'window', 'window-crop', or 'display-crop'"
            )
        }
        let codecName = ProcessInfo.processInfo.environment["COMPUTER_USE_CAPTURE_CAPTURE_CODEC"] ?? "hevc"
        guard let codec = CaptureCodec(rawValue: codecName) else {
            throw CaptureError.usage(
                "COMPUTER_USE_CAPTURE_CAPTURE_CODEC must be 'hevc', 'h264', 'prores422lt', or 'prores4444'"
            )
        }
        let checkpointInterval: TimeInterval?
        if let raw = ProcessInfo.processInfo.environment[
            "COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_INTERVAL_SECONDS"
        ] {
            guard let value = TimeInterval(raw), value > 0 else {
                throw CaptureError.usage(
                    "COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_INTERVAL_SECONDS must be positive"
                )
            }
            checkpointInterval = value
        } else {
            checkpointInterval = nil
        }
        let checkpointDirectory = ProcessInfo.processInfo.environment[
            "COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_DIRECTORY"
        ].map { URL(fileURLWithPath: $0).standardizedFileURL }
        let checkpointLimit: Int
        if let raw = ProcessInfo.processInfo.environment[
            "COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_LIMIT"
        ] {
            guard let value = Int(raw), value > 0 else {
                throw CaptureError.usage(
                    "COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_LIMIT must be a positive integer"
                )
            }
            checkpointLimit = value
        } else {
            checkpointLimit = 120
        }
        let targetWindowTitle = ProcessInfo.processInfo.environment[
            "COMPUTER_USE_CAPTURE_TARGET_WINDOW_TITLE"
        ]

        return CaptureOptions(
            outputURL: outputURL,
            duration: duration,
            bundleIdentifier: bundleIdentifier,
            targetWindowTitle: targetWindowTitle,
            framesPerSecond: 60,
            mode: mode,
            codec: codec,
            diagnosticCheckpointInterval: checkpointInterval,
            diagnosticCheckpointDirectory: checkpointDirectory,
            diagnosticCheckpointLimit: checkpointLimit
        )
    }
}

enum CaptureMode: String {
    case application
    case window
    case windowCrop = "window-crop"
    case displayCrop = "display-crop"
}

private func capturePixelDimension(_ value: CGFloat) -> Int {
    let rounded = max(2, Int(ceil(value)))
    return rounded.isMultiple(of: 2) ? rounded : rounded + 1
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

private struct DiagnosticCheckpointRecord: Codable, Sendable {
    let sequence: Int
    let sourceTime: Double
    let file: String
    let geometry: CaptureFrameGeometry
    let pixelComparison: CapturedPixelComparison
}

private struct DiagnosticCheckpointManifest: Codable, Sendable {
    let version: Int
    let sourceTimebase: String
    let intervalSeconds: Double
    let checkpoints: [DiagnosticCheckpointRecord]
    let skippedBusy: Int
    let errors: [String]
}

private struct DiagnosticCheckpointSummary: Sendable {
    let written: Int
    let skippedBusy: Int
    let errors: Int
}

/// Diagnostic-only, bounded raw-frame checkpoints. Pixel bytes are copied on
/// the capture queue before AVAssetWriter sees them, then PNG compression runs
/// on a separate serial queue so codec analysis cannot alter production timing.
private final class DiagnosticCheckpointWriter: @unchecked Sendable {
    let directory: URL
    private let interval: Double
    private let limit: Int
    private let queue = DispatchQueue(
        label: "computerusecapture.capture.checkpoints", qos: .utility
    )
    private let stateLock = NSLock()
    private var nextSourceTime = 0.0
    private var reserved = 0
    private var pending = 0
    private var skippedBusy = 0
    private var records: [DiagnosticCheckpointRecord] = []
    private var errors: [String] = []

    init(directory: URL, interval: Double, limit: Int) throws {
        self.directory = directory
        self.interval = interval
        self.limit = limit
        try FileManager.default.removeItemIfPresent(at: directory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    func captureIfDue(
        _ pixelBuffer: CVPixelBuffer,
        sourceTime: Double,
        geometry: CaptureFrameGeometry,
        pixelComparison: CapturedPixelComparison
    ) {
        let sequence: Int? = stateLock.withLock {
            guard sourceTime + 0.000_001 >= nextSourceTime, reserved < limit else { return nil }
            nextSourceTime = sourceTime + interval
            guard pending < 2 else {
                skippedBusy += 1
                return nil
            }
            let result = reserved
            reserved += 1
            pending += 1
            return result
        }
        guard let sequence else { return }
        guard let pixels = Self.copyBGRA(pixelBuffer) else {
            stateLock.withLock { pending -= 1 }
            queue.async { self.errors.append("Could not copy checkpoint \(sequence) pixels") }
            return
        }
        let filename = String(format: "frame-%04d-t%010.3f.png", sequence, sourceTime)
        queue.async {
            defer { self.stateLock.withLock { self.pending -= 1 } }
            do {
                try Self.writePNG(
                    pixels: pixels.data,
                    width: pixels.width,
                    height: pixels.height,
                    bytesPerRow: pixels.bytesPerRow,
                    to: self.directory.appendingPathComponent(filename)
                )
                self.records.append(DiagnosticCheckpointRecord(
                    sequence: sequence,
                    sourceTime: sourceTime,
                    file: filename,
                    geometry: geometry,
                    pixelComparison: pixelComparison
                ))
            } catch {
                self.errors.append("Checkpoint \(sequence): \(error.localizedDescription)")
            }
        }
    }

    func finish() throws -> DiagnosticCheckpointSummary {
        try queue.sync {
            records.sort { $0.sequence < $1.sequence }
            let manifest = DiagnosticCheckpointManifest(
                version: 1,
                sourceTimebase: "first-complete-frame-presentation-time",
                intervalSeconds: interval,
                checkpoints: records,
                skippedBusy: stateLock.withLock { skippedBusy },
                errors: errors
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(manifest).write(
                to: directory.appendingPathComponent("checkpoints.json"), options: .atomic
            )
            return DiagnosticCheckpointSummary(
                written: records.count,
                skippedBusy: manifest.skippedBusy,
                errors: errors.count
            )
        }
    }

    private static func copyBGRA(
        _ pixelBuffer: CVPixelBuffer
    ) -> (data: Data, width: Int, height: Int, bytesPerRow: Int)? {
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationRowBytes = width * 4
        guard width > 0, height > 0, sourceRowBytes >= destinationRowBytes else { return nil }
        var data = Data(count: destinationRowBytes * height)
        data.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * destinationRowBytes),
                    base.advanced(by: row * sourceRowBytes),
                    destinationRowBytes
                )
            }
        }
        return (data, width, height, destinationRowBytes)
    }

    private static func writePNG(
        pixels: Data,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        to url: URL
    ) throws {
        guard let provider = CGDataProvider(data: pixels as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw CaptureError.writerSetup("Could not create checkpoint image provider")
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
        )
        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ), let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw CaptureError.writerSetup("Could not create checkpoint PNG")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CaptureError.writerSetup("Could not write checkpoint PNG")
        }
    }
}

private extension FileManager {
    func removeItemIfPresent(at url: URL) throws {
        guard fileExists(atPath: url.path) else { return }
        try removeItem(at: url)
    }
}

private final class MovieWriter: NSObject, SCStreamOutput, @unchecked Sendable {
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
    private var geometryDiscontinuityFrameCount = 0
    private var geometryMetadataIncompleteFrameCount = 0
    private var invalidMetadataSampleCount = 0
    private var preRollSampleCount = 0
    private var provenanceSamples: [CapturedFrameSample] = []
    private var previousFramePixels: [UInt8]?
    private var appendError: Error?
    private var geometryMonitor = CaptureGeometryMonitor()
    private let geometryContract: CaptureGeometryContract
    private let diagnosticCheckpointWriter: DiagnosticCheckpointWriter?

    init(
        outputURL: URL,
        provenanceURL: URL,
        width: Int,
        height: Int,
        codec: CaptureCodec,
        framesPerSecond: Int32,
        geometryContract: CaptureGeometryContract,
        diagnosticCheckpointWriter: DiagnosticCheckpointWriter?
    ) throws {
        self.provenanceURL = provenanceURL
        self.geometryContract = geometryContract
        self.diagnosticCheckpointWriter = diagnosticCheckpointWriter
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
        let geometry = frameGeometry(sampleBuffer, metadata: metadata)
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
        let geometryDiscontinuities: [CaptureGeometryDiscontinuity]
        if metadata.status == .complete {
            if metadata.contentRect == nil || metadata.boundingRect == nil
                || metadata.scaleFactor == nil || metadata.contentScale == nil {
                geometryMetadataIncompleteFrameCount += 1
            }
            geometryDiscontinuities = geometryMonitor.inspect(geometry)
            if !geometryDiscontinuities.isEmpty {
                geometryDiscontinuityFrameCount += 1
            }
        } else {
            geometryDiscontinuities = []
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
                    "scaleFactor=\(format(metadata.scaleFactor)) contentScale=\(format(metadata.contentScale)) " +
                    "contentRect=\(format(metadata.contentRect)) " +
                    "boundingRect=\(format(metadata.boundingRect)) " +
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
            } else {
                if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    diagnosticCheckpointWriter?.captureIfDue(
                        pixelBuffer,
                        sourceTime: sourceTime,
                        geometry: geometry,
                        pixelComparison: pixelComparison
                    )
                }
                if input.append(sampleBuffer) {
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
        }
        provenanceSamples.append(CapturedFrameSample(
            sourceTime: sourceTime,
            displayTime: metadata.displayTime,
            status: metadata.status,
            dirtyRects: metadata.dirtyRects,
            writerDisposition: disposition,
            pixelComparison: pixelComparison,
            geometry: geometry,
            geometryDiscontinuities: geometryDiscontinuities.isEmpty ? nil : geometryDiscontinuities
        ))
    }

    func finish() async throws -> (
        frameCount: Int,
        droppedNonMonotonicFrameCount: Int,
        droppedBackpressureFrameCount: Int,
        geometryDiscontinuityFrameCount: Int,
        geometryMetadataIncompleteFrameCount: Int
    ) {
        let result: (
            count: Int,
            nonMonotonic: Int,
            backpressure: Int,
            geometryDiscontinuities: Int,
            geometryMetadataIncomplete: Int,
            ledger: CaptureFrameLedger,
            error: Error?
        ) = lock.withLock {
            input.markAsFinished()
            return (
                frameCount,
                droppedNonMonotonicFrameCount,
                droppedBackpressureFrameCount,
                geometryDiscontinuityFrameCount,
                geometryMetadataIncompleteFrameCount,
                CaptureFrameLedger(
                    expectedFrameInterval: expectedFrameInterval,
                    samples: provenanceSamples,
                    integrity: CaptureIntegrity(
                        invalidMetadataSamples: invalidMetadataSampleCount,
                        preRollSamples: preRollSampleCount,
                        droppedBackpressureFrames: droppedBackpressureFrameCount,
                        droppedNonMonotonicFrames: droppedNonMonotonicFrameCount,
                        appendFailedFrames: appendFailedFrameCount,
                        geometryDiscontinuityFrames: geometryDiscontinuityFrameCount,
                        geometryMetadataIncompleteFrames: geometryMetadataIncompleteFrameCount
                    ),
                    geometryContract: geometryContract,
                    geometryBaseline: geometryMonitor.baseline
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
        if let diagnosticCheckpointWriter {
            let summary = try diagnosticCheckpointWriter.finish()
            writeStandardOutput(
                "CAPTURE_CHECKPOINTS written=\(summary.written) " +
                    "skippedBusy=\(summary.skippedBusy) errors=\(summary.errors) " +
                    "directory=\(diagnosticCheckpointWriter.directory.path)\n"
            )
        }
        return (
            result.count, result.nonMonotonic, result.backpressure,
            result.geometryDiscontinuities, result.geometryMetadataIncomplete
        )
    }

    private struct FrameMetadata {
        let status: CapturedFrameStatus
        let displayTime: UInt64?
        let dirtyRects: [CaptureDamageRect]
        let scaleFactor: Double?
        let contentScale: Double?
        let contentRect: CaptureFrameRect?
        let boundingRect: CaptureFrameRect?
        let screenRect: CaptureFrameRect?
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
            scaleFactor: finiteDouble(info[.scaleFactor]),
            contentScale: finiteDouble(info[.contentScale]),
            contentRect: frameRect(info[.contentRect]),
            boundingRect: frameRect(info[.boundingRect]),
            screenRect: frameRect(info[.screenRect])
        )
    }

    private func frameGeometry(
        _ sampleBuffer: CMSampleBuffer,
        metadata: FrameMetadata
    ) -> CaptureFrameGeometry {
        let buffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        return CaptureFrameGeometry(
            bufferWidth: buffer.map(CVPixelBufferGetWidth) ?? 0,
            bufferHeight: buffer.map(CVPixelBufferGetHeight) ?? 0,
            contentRect: metadata.contentRect,
            boundingRect: metadata.boundingRect,
            screenRect: metadata.screenRect,
            scaleFactor: metadata.scaleFactor,
            contentScale: metadata.contentScale
        )
    }

    private func finiteDouble(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber else { return nil }
        let result = value.doubleValue
        return result.isFinite ? result : nil
    }

    private func frameRect(_ value: Any?) -> CaptureFrameRect? {
        guard let value else { return nil }
        let rect: CGRect
        if let value = value as? NSValue {
            rect = value.rectValue
        } else if CFGetTypeID(value as CFTypeRef) == CFDictionaryGetTypeID(),
                  let decoded = CGRect(
                    dictionaryRepresentation: unsafeBitCast(value as CFTypeRef, to: CFDictionary.self)
                  ) {
            // ScreenCaptureKit's frame attachments use Core Foundation
            // dictionary representations for rectangles. Accept NSValue as
            // well so the ledger remains compatible across macOS releases.
            rect = decoded
        } else {
            return nil
        }
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite else { return nil }
        return CaptureFrameRect(
            x: rect.minX, y: rect.minY, width: rect.width, height: rect.height
        )
    }

    private func format(_ value: Double?) -> String {
        value.map { String(format: "%.6f", $0) } ?? "unavailable"
    }

    private func format(_ rect: CaptureFrameRect?) -> String {
        guard let rect else { return "unavailable" }
        return String(
            format: "%.3f,%.3f,%.3f,%.3f", rect.x, rect.y, rect.width, rect.height
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
                .filter({ options.targetWindowTitle == nil || $0.title == options.targetWindowTitle })
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
            case .windowCrop:
                filter = SCContentFilter(display: display, including: [targetWindow])
            case .displayCrop:
                // A true region recording: preserve the display's composed pixels
                // (including transient and overlapping surfaces), then crop the
                // stream to the target window's initial bounds below.
                filter = SCContentFilter(display: display, excludingWindows: [])
            }
            let pointPixelScale = CGFloat(filter.pointPixelScale)
            // The 4:2:0 production codecs require even visible dimensions.
            // Expand the crop by at most one physical pixel below instead of
            // shrinking or stretching the target window to make it even.
            let width = capturePixelDimension(targetWindow.frame.width * pointPixelScale)
            let height = capturePixelDimension(targetWindow.frame.height * pointPixelScale)
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
            if #available(macOS 14.2, *) {
                configuration.includeChildWindows = true
            }
            if options.mode != .window {
                configuration.sourceRect = CGRect(
                    x: targetWindow.frame.minX - display.frame.minX,
                    y: targetWindow.frame.minY - display.frame.minY,
                    width: CGFloat(width) / pointPixelScale,
                    height: CGFloat(height) / pointPixelScale
                )
            }
            let checkpointWriter: DiagnosticCheckpointWriter?
            if let interval = options.diagnosticCheckpointInterval {
                let directory = options.diagnosticCheckpointDirectory
                    ?? options.outputURL.deletingPathExtension().appendingPathExtension(
                        "capture-checkpoints"
                    )
                checkpointWriter = try DiagnosticCheckpointWriter(
                    directory: directory,
                    interval: interval,
                    limit: options.diagnosticCheckpointLimit
                )
            } else {
                checkpointWriter = nil
            }
            let movieWriter = try MovieWriter(
                outputURL: options.outputURL,
                provenanceURL: options.outputURL.deletingPathExtension().appendingPathExtension("capture.json"),
                width: width,
                height: height,
                codec: options.codec,
                framesPerSecond: options.framesPerSecond,
                geometryContract: CaptureGeometryContract(
                    configuredWidth: width,
                    configuredHeight: height,
                    pointPixelScale: Double(pointPixelScale),
                    pixelFormat: "32BGRA",
                    captureResolution: "best",
                    scalesToFit: configuration.scalesToFit,
                    preservesAspectRatio: configuration.preservesAspectRatio
                ),
                diagnosticCheckpointWriter: checkpointWriter
            )
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            let outputQueue = DispatchQueue(label: "computerusecapture.capture.video", qos: .userInteractive)
            try stream.addStreamOutput(movieWriter, type: .screen, sampleHandlerQueue: outputQueue)

            try await stream.startCapture()
            writeStandardOutput(
                "CAPTURE_READY app=\(options.bundleIdentifier) window=\(targetWindow.title ?? "Untitled") " +
                    "size=\(width)x\(height) scale=\(pointPixelScale) " +
                    "windowFrame=\(targetWindow.frame) displayFrame=\(display.frame) " +
                    "filterContentRect=\(filter.contentRect) filterStyle=\(filter.style.rawValue) " +
                    "scalesToFit=\(configuration.scalesToFit) " +
                    "mode=\(options.mode.rawValue) codec=\(options.codec.rawValue) " +
                    "checkpoints=\(checkpointWriter == nil ? "disabled" : "enabled")\n"
            )
            let stopReason = await waitForStopOrTimeout(seconds: options.duration)
            try await stream.stopCapture()
            let result = try await movieWriter.finish()
            writeStandardOutput(
                "CAPTURE_COMPLETE reason=\(stopReason.rawValue) frames=\(result.frameCount) " +
                    "droppedNonMonotonicFrames=\(result.droppedNonMonotonicFrameCount) " +
                    "droppedBackpressureFrames=\(result.droppedBackpressureFrameCount) " +
                    "geometryDiscontinuityFrames=\(result.geometryDiscontinuityFrameCount) " +
                    "geometryMetadataIncompleteFrames=\(result.geometryMetadataIncompleteFrameCount) " +
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
