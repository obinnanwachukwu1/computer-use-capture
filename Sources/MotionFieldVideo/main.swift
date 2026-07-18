@preconcurrency import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import NativeDirector

private enum DiagnosticFailure: Error, CustomStringConvertible {
    case usage
    case message(String)

    var description: String {
        switch self {
        case .usage:
            "usage: motion-field-video <source.mov> <output.mp4> [--fps 6] [--analysis-width 320] [--start 0] [--duration seconds]"
        case let .message(value): value
        }
    }
}

private struct Options {
    let source: URL
    let output: URL
    let fps: Int
    let analysisWidth: Int
    let start: Double
    let duration: Double?

    init(arguments: [String]) throws {
        guard arguments.count >= 2 else { throw DiagnosticFailure.usage }
        source = URL(fileURLWithPath: arguments[0])
        output = URL(fileURLWithPath: arguments[1])
        var fps = 6
        var analysisWidth = 320
        var start = 0.0
        var duration: Double?
        var index = 2
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw DiagnosticFailure.usage }
            switch arguments[index] {
            case "--fps": fps = Int(arguments[index + 1]) ?? 0
            case "--analysis-width": analysisWidth = Int(arguments[index + 1]) ?? 0
            case "--start": start = Double(arguments[index + 1]) ?? -1
            case "--duration": duration = Double(arguments[index + 1])
            default: throw DiagnosticFailure.usage
            }
            index += 2
        }
        guard fps > 0, analysisWidth >= 96, start >= 0,
              duration == nil || duration! > 0
        else { throw DiagnosticFailure.usage }
        self.fps = fps
        self.analysisWidth = analysisWidth
        self.start = start
        self.duration = duration
    }
}

private struct DiagnosticFrame {
    let time: Double
    let sourceTime: Double
    let tileColumns: Int
    let tileRows: Int
    let rawChangedPixels: Int
    let counts: [MotionEvidenceChannel: Int]
    let materialTiles: [MotionEvidenceTile]
    let pixels: [UInt8]
}

@main
private enum MotionFieldVideo {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("motion-field-video: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
        let asset = AVURLAsset(url: options.source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw DiagnosticFailure.message("source has no video track")
        }
        let naturalSize = try await track.load(.naturalSize)
        let sourceWidth = max(1, Int(abs(naturalSize.width).rounded()))
        let sourceHeight = max(1, Int(abs(naturalSize.height).rounded()))
        let analysisHeight = max(1, Int((Double(options.analysisWidth) * Double(sourceHeight) / Double(sourceWidth)).rounded()))
        let displayScale = 2
        let panelWidth = options.analysisWidth * displayScale
        let panelHeight = analysisHeight * displayScale
        let legendHeight = 40
        let outputWidth = panelWidth * 2
        let outputHeight = panelHeight + legendHeight

        let reader = try AVAssetReader(asset: asset)
        if let duration = options.duration {
            reader.timeRange = CMTimeRange(
                start: CMTime(seconds: options.start, preferredTimescale: 600),
                duration: CMTime(seconds: duration, preferredTimescale: 600)
            )
        }
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        readerOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(readerOutput) else { throw DiagnosticFailure.message("reader rejected video output") }
        reader.add(readerOutput)

        try? FileManager.default.removeItem(at: options.output)
        try FileManager.default.createDirectory(
            at: options.output.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let writer = try AVAssetWriter(outputURL: options.output, fileType: .mp4)
        let writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoExpectedSourceFrameRateKey: options.fps,
                AVVideoMaxKeyFrameIntervalKey: options.fps * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ])
        writerInput.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: outputWidth,
                kCVPixelBufferHeightKey as String: outputHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        guard writer.canAdd(writerInput) else { throw DiagnosticFailure.message("writer rejected video input") }
        writer.add(writerInput)
        guard reader.startReading(), writer.startWriting() else {
            throw DiagnosticFailure.message(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "media pipeline failed to start")
        }
        writer.startSession(atSourceTime: .zero)

        let context = CIContext(options: [.cacheIntermediates: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let analysisBounds = CGRect(x: 0, y: 0, width: options.analysisWidth, height: analysisHeight)
        let rowBytes = options.analysisWidth * 4
        var previous: [UInt8]?
        var outputFrame = 0
        var nextSampleTime = options.start
        var reportFrames: [DiagnosticFrame] = []
        let configuration = MotionFieldConfiguration(
            tileSize: MotionFieldConfiguration.normalizedTileSize(forRasterWidth: options.analysisWidth),
            maximumShift: min(48, max(16, options.analysisWidth / 7)),
            shiftStep: 4,
            retainDenseEvidence: true
        )

        while let sample = readerOutput.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if time + 0.0001 < options.start { continue }
            guard time + 0.0001 >= nextSampleTime,
                  let buffer = CMSampleBufferGetImageBuffer(sample)
            else { continue }
            nextSampleTime += 1 / Double(options.fps)
            let source = CIImage(cvPixelBuffer: buffer)
            let scaleX = CGFloat(options.analysisWidth) / source.extent.width
            let scaleY = CGFloat(analysisHeight) / source.extent.height
            let scaled = source.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY)).cropped(to: analysisBounds)
            var current = [UInt8](repeating: 0, count: rowBytes * analysisHeight)
            context.render(
                scaled,
                toBitmap: &current,
                rowBytes: rowBytes,
                bounds: analysisBounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )

            let comparison = previous ?? current
            let localTime = time - options.start
            let field = SpatialMotion.motionField(
                previous: comparison,
                current: current,
                width: options.analysisWidth,
                height: analysisHeight,
                beforeTime: max(0, localTime - 1 / Double(options.fps)),
                afterTime: localTime,
                configuration: configuration
            )
            guard let evidence = field.denseEvidence else {
                throw DiagnosticFailure.message("dense evidence was not retained")
            }
            let canvas = makeCanvas(
                source: current,
                evidence: evidence,
                panelWidth: panelWidth,
                panelHeight: panelHeight,
                legendHeight: legendHeight
            )
            while !writerInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
            }
            guard let pool = adaptor.pixelBufferPool else {
                throw DiagnosticFailure.message("writer pixel-buffer pool unavailable")
            }
            var outputBuffer: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer) == kCVReturnSuccess,
                  let outputBuffer
            else { throw DiagnosticFailure.message("could not allocate output frame") }
            copyBGRA(canvas, width: outputWidth, height: outputHeight, to: outputBuffer)
            let outputTime = CMTime(value: CMTimeValue(outputFrame), timescale: CMTimeScale(options.fps))
            guard adaptor.append(outputBuffer, withPresentationTime: outputTime) else {
                throw DiagnosticFailure.message(writer.error?.localizedDescription ?? "writer rejected frame \(outputFrame)")
            }
            let counts = Dictionary(grouping: evidence.tiles, by: \.channel).mapValues(\.count)
            reportFrames.append(DiagnosticFrame(
                time: localTime,
                sourceTime: time,
                tileColumns: evidence.tileColumns,
                tileRows: evidence.tileRows,
                rawChangedPixels: evidence.rawDelta.reduce(0) { $0 + ($1 >= 20 ? 1 : 0) },
                counts: counts,
                materialTiles: evidence.tiles.filter { $0.channel != .unchanged },
                pixels: current
            ))
            previous = current
            outputFrame += 1
            if outputFrame % max(1, options.fps * 5) == 0 {
                print("motion field \(Int(localTime))s frames=\(outputFrame)")
            }
        }
        guard reader.status == .completed else {
            throw DiagnosticFailure.message(reader.error?.localizedDescription ?? "reader failed")
        }
        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw DiagnosticFailure.message(writer.error?.localizedDescription ?? "writer failed")
        }
        try writeReport(options: options, evidenceWidth: options.analysisWidth, evidenceHeight: analysisHeight, frames: reportFrames)
        print("motion-field-video output=\(options.output.path) frames=\(outputFrame)")
    }
}

private func makeCanvas(
    source: [UInt8],
    evidence: DenseMotionEvidence,
    panelWidth: Int,
    panelHeight: Int,
    legendHeight: Int
) -> [UInt8] {
    let outputWidth = panelWidth * 2
    let outputHeight = panelHeight + legendHeight
    var canvas = [UInt8](repeating: 0, count: outputWidth * outputHeight * 4)
    for pixel in 0..<(outputWidth * outputHeight) { canvas[pixel * 4 + 3] = 255 }
    // Spatial smoothing is presentation-only. The canonical evidence remains
    // `rawDelta` plus per-tile channels; this scale-space view makes sparse UI
    // edges legible without inventing a bounding rectangle or retaining heat
    // from an earlier frame.
    let spatialHeat = makeSpatialHeat(evidence)

    let legend: [(MotionEvidenceChannel, (UInt8, UInt8, UInt8))] = [
        (.structural, (255, 76, 36)),
        (.translation, (0, 196, 255)),
        (.photometric, (190, 80, 255)),
        (.backdrop, (50, 110, 255))
    ]
    let swatchWidth = panelWidth / legend.count
    for (index, item) in legend.enumerated() {
        fillBGRA(
            &canvas,
            canvasWidth: outputWidth,
            x: index * swatchWidth + 4,
            y: 8,
            width: max(1, swatchWidth - 8),
            height: legendHeight - 16,
            rgb: item.1
        )
    }
    fillBGRA(
        &canvas, canvasWidth: outputWidth,
        x: panelWidth + 4, y: 8, width: panelWidth - 8, height: legendHeight - 16,
        rgb: (72, 72, 76)
    )

    for displayY in 0..<panelHeight {
        let sourceY = min(evidence.pixelHeight - 1, displayY * evidence.pixelHeight / panelHeight)
        for displayX in 0..<panelWidth {
            let sourceX = min(evidence.pixelWidth - 1, displayX * evidence.pixelWidth / panelWidth)
            let sourcePixel = sourceY * evidence.pixelWidth + sourceX
            let heat = spatialHeat[sourcePixel]
            setBGRA(&canvas, width: outputWidth, x: displayX, y: displayY + legendHeight, rgb: heat)

            let sourceOffset = sourcePixel * 4
            let sourceColor = (source[sourceOffset], source[sourceOffset + 1], source[sourceOffset + 2])
            setBGRA(
                &canvas, width: outputWidth,
                x: panelWidth + displayX, y: displayY + legendHeight,
                rgb: sourceColor
            )
        }
    }
    return canvas
}

private func makeSpatialHeat(_ evidence: DenseMotionEvidence) -> [(UInt8, UInt8, UInt8)] {
    // Sub-threshold raw change remains in DenseMotionEvidence and the JSON
    // report for blame/audit work, but is deliberately hidden from the review
    // video so codec and raster noise cannot obscure material explanations.
    let channels: [MotionEvidenceChannel] = [.structural, .translation, .photometric, .backdrop]
    let colors: [MotionEvidenceChannel: (Double, Double, Double)] = [
        .structural: (255, 76, 36),
        .translation: (0, 196, 255),
        .photometric: (190, 80, 255),
        .backdrop: (50, 110, 255)
    ]
    let count = evidence.pixelWidth * evidence.pixelHeight
    var raw = Dictionary(uniqueKeysWithValues: channels.map { ($0, [Double](repeating: 0, count: count)) })
    for y in 0..<evidence.pixelHeight {
        for x in 0..<evidence.pixelWidth {
            let index = y * evidence.pixelWidth + x
            let delta = evidence.rawDelta[index]
            guard delta > 0 else { continue }
            let tileX = min(evidence.tileColumns - 1, x / evidence.tileSize)
            let tileY = min(evidence.tileRows - 1, y / evidence.tileSize)
            let channel = evidence.tiles[tileY * evidence.tileColumns + tileX].channel
            raw[channel]?[index] = sqrt(Double(delta) / 255)
        }
    }
    var support: [MotionEvidenceChannel: [Double]] = [:]
    for channel in channels {
        let exact = raw[channel] ?? [Double](repeating: 0, count: count)
        let local = boxBlur(exact, width: evidence.pixelWidth, height: evidence.pixelHeight, radius: 5)
        let regional = boxBlur(exact, width: evidence.pixelWidth, height: evidence.pixelHeight, radius: 12)
        support[channel] = exact.indices.map { index in
            min(1, max(exact[index] * 0.85, local[index] * 3.5, regional[index] * 8.0))
        }
    }
    return (0..<count).map { index in
        var red = 0.0, green = 0.0, blue = 0.0, total = 0.0, peak = 0.0
        for channel in channels {
            let value = support[channel]?[index] ?? 0
            guard value > 0.008, let color = colors[channel] else { continue }
            red += color.0 * value
            green += color.1 * value
            blue += color.2 * value
            total += value
            peak = max(peak, value)
        }
        guard total > 0 else { return (0, 0, 0) }
        let brightness = min(1, 0.08 + peak * 1.15)
        return (
            UInt8(min(255, red / total * brightness).rounded()),
            UInt8(min(255, green / total * brightness).rounded()),
            UInt8(min(255, blue / total * brightness).rounded())
        )
    }
}

private func boxBlur(_ values: [Double], width: Int, height: Int, radius: Int) -> [Double] {
    let stride = width + 1
    var integral = [Double](repeating: 0, count: (width + 1) * (height + 1))
    for y in 0..<height {
        var row = 0.0
        for x in 0..<width {
            row += values[y * width + x]
            integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + row
        }
    }
    var result = [Double](repeating: 0, count: values.count)
    for y in 0..<height {
        let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
        for x in 0..<width {
            let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
            let sum = integral[y1 * stride + x1]
                - integral[y0 * stride + x1]
                - integral[y1 * stride + x0]
                + integral[y0 * stride + x0]
            result[y * width + x] = sum / Double((x1 - x0) * (y1 - y0))
        }
    }
    return result
}

private func setBGRA(
    _ pixels: inout [UInt8],
    width: Int,
    x: Int,
    y: Int,
    rgb: (UInt8, UInt8, UInt8)
) {
    let offset = (y * width + x) * 4
    pixels[offset] = rgb.2
    pixels[offset + 1] = rgb.1
    pixels[offset + 2] = rgb.0
    pixels[offset + 3] = 255
}

private func fillBGRA(
    _ pixels: inout [UInt8],
    canvasWidth: Int,
    x: Int,
    y: Int,
    width: Int,
    height: Int,
    rgb: (UInt8, UInt8, UInt8)
) {
    for py in y..<(y + height) {
        for px in x..<(x + width) {
            setBGRA(&pixels, width: canvasWidth, x: px, y: py, rgb: rgb)
        }
    }
}

private func copyBGRA(_ pixels: [UInt8], width: Int, height: Int, to buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return }
    let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
    pixels.withUnsafeBytes { source in
        guard let sourceBase = source.baseAddress else { return }
        for row in 0..<height {
            memcpy(destination.advanced(by: row * destinationStride), sourceBase.advanced(by: row * width * 4), width * 4)
        }
    }
}

private func writeReport(
    options: Options,
    evidenceWidth: Int,
    evidenceHeight: Int,
    frames: [DiagnosticFrame]
) throws {
    let names: [MotionEvidenceChannel: String] = [
        .unchanged: "unchanged-or-subthreshold",
        .structural: "structural",
        .translation: "translation",
        .photometric: "photometric",
        .backdrop: "backdrop"
    ]
    let trackGraph = DenseMotionTrackGraph.make(samples: frames.map { frame in
        DenseMotionSample(
            time: frame.time,
            tileColumns: frame.tileColumns,
            tileRows: frame.tileRows,
            tiles: frame.materialTiles
        )
    })
    let componentsByID = Dictionary(uniqueKeysWithValues: trackGraph.components.map { ($0.id, $0) })
    let objectGraph = DenseMotionObjectGraph.make(tracks: trackGraph)
    let surfaceGraph = DenseMotionSurfaceGraph.make(
        tracks: trackGraph,
        objects: objectGraph,
        frames: frames.map {
            DenseMotionRasterFrame(
                time: $0.time,
                width: evidenceWidth,
                height: evidenceHeight,
                pixels: $0.pixels
            )
        },
        tileColumns: frames.first?.tileColumns ?? 0,
        tileRows: frames.first?.tileRows ?? 0
    )
    let transportGraph = DenseMotionTransportGraph.make(
        frames: frames.map {
            DenseTransportFrame(
                time: $0.time,
                width: evidenceWidth,
                height: evidenceHeight,
                pixels: $0.pixels
            )
        },
        evidence: trackGraph
    )
    let transportComponentsByID = Dictionary(
        uniqueKeysWithValues: transportGraph.components.map { ($0.id, $0) }
    )
    let objectsByID = Dictionary(uniqueKeysWithValues: objectGraph.ensembles.map { ($0.id, $0) })
    let ownershipGraph = DenseMotionOwnershipGraph.make(
        seeds: surfaceGraph.surfaces.compactMap { surface in
            guard let object = objectsByID[surface.objectID] else { return nil }
            return ForegroundSupportSeed(
                id: surface.objectID,
                normalizedBounds: surface.normalizedBounds,
                tileIndices: surface.tileIndices,
                birthTime: object.startTime,
                heldTime: surface.heldTime,
                releaseTime: object.endTime,
                supportConfidence: surface.confidence,
                provenanceMotionTrackIDs: object.trackIDs
            )
        },
        motion: trackGraph,
        transport: transportGraph
    )
    func ownershipAssignment(_ assignment: DenseMotionOwnershipGraph.Assignment) -> [String: Any] {
        [
            "trackID": assignment.trackID,
            "lifecycleID": assignment.lifecycleID.map { $0 as Any } ?? NSNull(),
            "status": assignment.status.rawValue,
            "score": assignment.score,
            "candidates": assignment.candidates.map {
                ["lifecycleID": $0.lifecycleID, "score": $0.score]
            }
        ]
    }
    let payload: [String: Any] = [
        "version": 2,
        "source": options.source.path,
        "sourceRange": [
            "start": options.start,
            "duration": options.duration.map { $0 as Any } ?? NSNull()
        ],
        "fps": options.fps,
        "analysis": ["width": evidenceWidth, "height": evidenceHeight],
        "contract": "per-frame raw pixel deltas plus mutually exclusive per-tile explanations; no blur, temporal smoothing, or component rectangles",
        "legend": names.reduce(into: [String: String]()) { result, entry in
            result[String(entry.key.rawValue)] = entry.value
        },
        "objectTracks": trackGraph.tracks.map { track in
            [
                "id": track.id,
                "startTime": track.startTime,
                "endTime": track.endTime,
                "bounds": [
                    "x": track.normalizedBounds.minX,
                    "y": track.normalizedBounds.minY,
                    "width": track.normalizedBounds.width,
                    "height": track.normalizedBounds.height
                ],
                "maximumGap": track.maximumGap,
                "continuityConfidence": track.continuityConfidence,
                "isBroadContext": track.isBroadContext,
                "entryDetailPolarity": track.entryDetailPolarity,
                "releaseDetailPolarity": track.releaseDetailPolarity,
                "components": track.componentIDs.compactMap { componentID -> [String: Any]? in
                    guard let component = componentsByID[componentID] else { return nil }
                    return [
                        "id": component.id,
                        "time": component.time,
                        "bounds": [
                            "x": component.normalizedBounds.minX,
                            "y": component.normalizedBounds.minY,
                            "width": component.normalizedBounds.width,
                            "height": component.normalizedBounds.height
                        ],
                        "tileIndices": component.tileIndices,
                        "energy": component.energy,
                        "confidence": component.confidence,
                        "detailPolarity": component.detailPolarity,
                        "meanLuminanceDelta": component.meanLuminanceDelta,
                        "channelWeights": component.channelWeights.reduce(into: [String: Double]()) {
                            $0[names[$1.key] ?? String($1.key.rawValue)] = $1.value
                        }
                    ]
                }
            ] as [String: Any]
        },
        "objectEnsembles": objectGraph.ensembles.map { ensemble in
            [
                "id": ensemble.id,
                "kind": ensemble.kind.rawValue,
                "trackIDs": ensemble.trackIDs,
                "startTime": ensemble.startTime,
                "endTime": ensemble.endTime,
                "bounds": [
                    "x": ensemble.normalizedBounds.minX,
                    "y": ensemble.normalizedBounds.minY,
                    "width": ensemble.normalizedBounds.width,
                    "height": ensemble.normalizedBounds.height
                ],
                "lifecycleConfidence": ensemble.lifecycleConfidence,
                "spatialOccupancy": ensemble.spatialOccupancy
            ] as [String: Any]
        },
        "objectSurfaces": surfaceGraph.surfaces.map { surface in
            [
                "objectID": surface.objectID,
                "bounds": [
                    "x": surface.normalizedBounds.minX,
                    "y": surface.normalizedBounds.minY,
                    "width": surface.normalizedBounds.width,
                    "height": surface.normalizedBounds.height
                ],
                "tileIndices": surface.tileIndices,
                "beforeTime": surface.beforeTime,
                "heldTime": surface.heldTime,
                "afterTime": surface.afterTime,
                "confidence": surface.confidence
            ] as [String: Any]
        },
        "transportTracks": transportGraph.tracks.map { track in
            [
                "id": track.id,
                "startTime": track.startTime,
                "endTime": track.endTime,
                "dominantAxis": track.dominantAxis.rawValue,
                "normalizedTravel": track.normalizedTravel,
                "directionalCoherence": track.directionalCoherence,
                "confidence": track.confidence,
                "components": track.componentIDs.compactMap { componentID -> [String: Any]? in
                    guard let component = transportComponentsByID[componentID] else { return nil }
                    return [
                        "id": component.id,
                        "time": component.time,
                        "bounds": [
                            "x": component.normalizedBounds.minX,
                            "y": component.normalizedBounds.minY,
                            "width": component.normalizedBounds.width,
                            "height": component.normalizedBounds.height
                        ],
                        "pixelCount": component.pixelCount,
                        "rectangularity": component.rectangularity,
                        "meanColor": [component.meanRed, component.meanGreen, component.meanBlue]
                    ]
                }
            ] as [String: Any]
        },
        "foregroundOwnership": [
            "contract": "diagnostic visible-support ownership only; motion cannot create support, ambiguous evidence abstains, and lifecycle birth/release timestamps are immutable",
            "lifecycles": ownershipGraph.lifecycles.map { lifecycle in
                [
                    "id": lifecycle.id,
                    "bounds": [
                        "x": lifecycle.normalizedBounds.minX,
                        "y": lifecycle.normalizedBounds.minY,
                        "width": lifecycle.normalizedBounds.width,
                        "height": lifecycle.normalizedBounds.height
                    ],
                    "tileIndices": lifecycle.tileIndices,
                    "birthTime": lifecycle.birthTime,
                    "heldTime": lifecycle.heldTime,
                    "releaseTime": lifecycle.releaseTime,
                    "supportConfidence": lifecycle.supportConfidence,
                    "supportingEvidenceStart": lifecycle.supportingEvidenceStart,
                    "supportingEvidenceEnd": lifecycle.supportingEvidenceEnd,
                    "motionTrackIDs": lifecycle.motionTrackIDs,
                    "transportTrackIDs": lifecycle.transportTrackIDs
                ] as [String: Any]
            },
            "motionAssignments": ownershipGraph.motionAssignments.map(ownershipAssignment),
            "transportAssignments": ownershipGraph.transportAssignments.map(ownershipAssignment)
        ] as [String: Any],
        "frames": frames.map { frame in
            [
                "time": frame.time,
                "sourceTime": frame.sourceTime,
                "rawChangedPixels": frame.rawChangedPixels,
                "tileCounts": frame.counts.reduce(into: [String: Int]()) { result, entry in
                    result[names[entry.key] ?? String(entry.key.rawValue)] = entry.value
                },
                "materialTiles": frame.materialTiles.map { tile in
                    [
                        "index": tile.index,
                        "channel": names[tile.channel] ?? String(tile.channel.rawValue),
                        "bounds": [
                            "x": tile.normalizedBounds.minX,
                            "y": tile.normalizedBounds.minY,
                            "width": tile.normalizedBounds.width,
                            "height": tile.normalizedBounds.height
                        ],
                        "changedFraction": tile.changedFraction,
                        "energy": tile.energy,
                        "confidence": tile.confidence,
                        "meanLuminanceDelta": tile.meanLuminanceDelta,
                        "vector": [
                            "dx": tile.normalizedVector.dx,
                            "dy": tile.normalizedVector.dy
                        ]
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
    ]
    let report = options.output.deletingPathExtension().appendingPathExtension("motion-field.json")
    let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: report, options: .atomic)
}
