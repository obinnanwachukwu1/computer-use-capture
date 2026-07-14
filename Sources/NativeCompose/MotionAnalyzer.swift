import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import NativeDirector

struct MotionAnalysis {
    let ranges: [ClosedRange<Double>]
    let sampledFrames: Int
    let motionFrames: Int
    let observations: [VisualMotionObservation]
    let interactionPhases: [Int: InteractionPhases]
}

struct InteractionTimingProbe {
    let actionID: Int
    let rawEstimate: Double
    let toolStart: Double
    let toolEnd: Double
    let finalActionInToolCall: Bool
    let normalizedTarget: CGRect
}

private struct ResponseFrame {
    let time: Double
    let pixels: [UInt8]
}

enum MotionAnalyzer {
    static func analyze(
        asset: AVAsset,
        track: AVAssetTrack,
        context: CIContext,
        sourceDuration: Double,
        actionTimes: [Double] = [],
        timingProbes: [InteractionTimingProbe] = [],
        relocationActionIDs: Set<Int> = [],
        samplesPerSecond: Double = 12,
        channelThreshold: Int = 20,
        changedPixelFraction: Double = 0.00004
    ) throws -> MotionAnalysis {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw Failure("cannot add motion-analysis reader output") }
        reader.add(output)
        guard reader.startReading() else { throw Failure(reader.error?.localizedDescription ?? "motion analysis could not start") }

        let analysisWidth = 320
        let analysisHeight = 234
        let rowBytes = analysisWidth * 4
        let bounds = CGRect(x: 0, y: 0, width: analysisWidth, height: analysisHeight)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sampleInterval = 1 / samplesPerSecond
        var nextSampleTime = 0.0
        var previous: [UInt8]?
        var motionTimes: [Double] = []
        var observations: [VisualMotionObservation] = []
        var sampledFrames = 0
        var beforeSnapshots: [Int: [UInt8]] = [:]
        var baselineSnapshots: [Int: [UInt8]] = [:]
        var afterSnapshots: [Int: [UInt8]] = [:]
        var localPrevious: [Int: [UInt8]] = [:]
        var localActivity: [Int: [InteractionActivitySample]] = [:]
        var responseFrames: [Int: [ResponseFrame]] = [:]
        var nextProgressTime = 10.0

        while autoreleasepool(invoking: {
            guard let sample = output.copyNextSampleBuffer() else { return false }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return true }
            let source = CIImage(cvPixelBuffer: buffer)

            for probe in timingProbes where
                time >= min(probe.toolStart, probe.rawEstimate) - 0.30 &&
                time <= max(probe.toolEnd, probe.rawEstimate) + 1.0 {
                let pixels = renderTimingTarget(
                    source: source,
                    normalizedTarget: probe.normalizedTarget,
                    context: context
                )
                if let previous = localPrevious[probe.actionID] {
                    localActivity[probe.actionID, default: []].append(
                        InteractionActivitySample(
                            time: time,
                            magnitude: meanAbsoluteDifference(previous, pixels)
                        )
                    )
                }
                localPrevious[probe.actionID] = pixels
            }

            if time + 0.0001 < nextSampleTime { return true }
            nextSampleTime = time + sampleInterval
            let scaled = source.transformed(by: CGAffineTransform(
                scaleX: CGFloat(analysisWidth) / source.extent.width,
                y: CGFloat(analysisHeight) / source.extent.height
            )).cropped(to: bounds)
            var pixels = [UInt8](repeating: 0, count: rowBytes * analysisHeight)
            context.render(
                scaled,
                toBitmap: &pixels,
                rowBytes: rowBytes,
                bounds: bounds,
                format: .RGBA8,
                colorSpace: colorSpace
            )
            sampledFrames += 1
            let activeResponseProbes = timingProbes.filter {
                time >= min($0.toolStart, $0.rawEstimate) - 0.30 &&
                time <= max($0.toolEnd, $0.rawEstimate) + 1.0
            }
            if !activeResponseProbes.isEmpty {
                // The interaction windows are short, but retaining every
                // analysis frame at 320x234 for every click scales poorly on
                // longer recordings. A half-resolution copy preserves the
                // regional motion needed for framing while bounding memory.
                let responsePixels = halfScaleRGBA(
                    pixels, sourceWidth: analysisWidth, sourceHeight: analysisHeight
                )
                for probe in activeResponseProbes {
                    responseFrames[probe.actionID, default: []].append(
                        ResponseFrame(time: time, pixels: responsePixels)
                    )
                }
            }
            if time >= nextProgressTime {
                let percent = sourceDuration > 0 ? min(100, Int(time / sourceDuration * 100)) : 0
                print("motion analysis \(percent)% source=\(Int(time))s/\(Int(sourceDuration))s samples=\(sampledFrames)")
                nextProgressTime += 10
            }
            for (index, actionTime) in actionTimes.enumerated() {
                if time <= actionTime - 0.85 { baselineSnapshots[index] = pixels }
                if time <= actionTime - 0.1 { beforeSnapshots[index] = pixels }
                if afterSnapshots[index] == nil, time >= actionTime + 0.75 { afterSnapshots[index] = pixels }
            }
            if let previous {
                let components = SpatialMotion.components(
                    previous: previous, current: pixels, width: analysisWidth, height: analysisHeight,
                    channelThreshold: channelThreshold, changedPixelFraction: changedPixelFraction,
                    classifyTranslations: false
                )
                if !components.isEmpty { motionTimes.append(time) }
            }
            previous = pixels
            return true
        }) {}
        guard reader.status == .completed else {
            throw Failure(reader.error?.localizedDescription ?? "motion analysis failed")
        }
        for (index, actionTime) in actionTimes.enumerated() {
            guard let before = beforeSnapshots[index], let after = afterSnapshots[index] else { continue }
            let response = SpatialMotion.components(
                previous: before, current: after, width: analysisWidth, height: analysisHeight,
                channelThreshold: channelThreshold, changedPixelFraction: changedPixelFraction
            )
            let baseline = baselineSnapshots[index].map {
                SpatialMotion.components(
                    previous: $0, current: before, width: analysisWidth, height: analysisHeight,
                    channelThreshold: channelThreshold, changedPixelFraction: changedPixelFraction
                )
            } ?? []
            observations += SpatialMotion.causalComponents(baseline: baseline, response: response).map {
                VisualMotionObservation(time: actionTime + 0.75, normalizedBounds: $0.normalizedBounds, changedFraction: $0.changedFraction, magnitude: $0.magnitude, kind: $0.kind)
            }
        }
        let interactionPhases = Dictionary(uniqueKeysWithValues: timingProbes.map { probe in
            let phases = InteractionPhaseDetector.detect(
                samples: localActivity[probe.actionID] ?? [],
                rawEstimate: probe.rawEstimate,
                toolStart: probe.toolStart,
                toolEnd: probe.toolEnd,
                finalActionInToolCall: probe.finalActionInToolCall
            )
            return (probe.actionID, phases)
        })
        // Measure click responses around the observed activation rather than
        // a fixed offset from the tool envelope. This captures the complete
        // region affected by controls such as animated charts and expanding
        // disclosures. For a factual viewport relocation, both frames are
        // deliberately taken after the new viewport is established; comparing
        // against the old viewport would make the scroll overlap and erase the
        // real response during ambient-motion rejection.
        let responseWidth = analysisWidth / 2
        let responseHeight = analysisHeight / 2
        for probe in timingProbes {
            guard let phase = interactionPhases[probe.actionID],
                  let frames = responseFrames[probe.actionID], frames.count >= 2,
                  let before = frames.last(where: { $0.time <= phase.activation + 0.02 })
            else { continue }
            let desiredResponseTime = phase.activation + 0.68
            let after = frames.first(where: { $0.time >= desiredResponseTime })
                ?? frames.last(where: { $0.time >= phase.activation + 0.30 })
            guard let after, after.time > before.time else { continue }
            let rawResponse = SpatialMotion.components(
                previous: before.pixels, current: after.pixels,
                width: responseWidth, height: responseHeight,
                channelThreshold: channelThreshold, changedPixelFraction: changedPixelFraction
            )
            let classifiedResponse = SpatialMotion.postActivationResponseComponents(rawResponse)
            let response: [DetectedMotionComponent]
            if relocationActionIDs.contains(probe.actionID) {
                response = classifiedResponse
            } else {
                let baselineEnd = frames.last(where: { $0.time <= phase.activation - 0.10 })
                let baselineStart = baselineEnd.flatMap { end in
                    frames.last(where: { $0.time <= end.time - 0.35 })
                }
                let baseline: [DetectedMotionComponent] = if let baselineStart, let baselineEnd {
                    SpatialMotion.postActivationResponseComponents(SpatialMotion.components(
                        previous: baselineStart.pixels, current: baselineEnd.pixels,
                        width: responseWidth, height: responseHeight,
                        channelThreshold: channelThreshold, changedPixelFraction: changedPixelFraction
                    ))
                } else {
                    []
                }
                response = SpatialMotion.causalComponents(
                    baseline: baseline, response: classifiedResponse
                )
            }
            observations += response.map {
                VisualMotionObservation(
                    time: after.time,
                    normalizedBounds: $0.normalizedBounds,
                    changedFraction: $0.changedFraction,
                    magnitude: $0.magnitude,
                    kind: $0.kind
                )
            }
        }
        return MotionAnalysis(
            ranges: MotionDetection.ranges(forMotionTimes: motionTimes),
            sampledFrames: sampledFrames,
            motionFrames: motionTimes.count,
            observations: observations,
            interactionPhases: interactionPhases
        )
    }

    private static func renderTimingTarget(
        source: CIImage,
        normalizedTarget: CGRect,
        context: CIContext
    ) -> [UInt8] {
        let sourceBounds = source.extent
        var target = CGRect(
            x: sourceBounds.minX + normalizedTarget.minX * sourceBounds.width,
            y: sourceBounds.minY + (1 - normalizedTarget.maxY) * sourceBounds.height,
            width: normalizedTarget.width * sourceBounds.width,
            height: normalizedTarget.height * sourceBounds.height
        )
        target = target.insetBy(dx: -8, dy: -8).intersection(sourceBounds)
        let width = 96, height = 64, rowBytes = width * 4
        let outputBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let image = source.cropped(to: target)
            .transformed(by: CGAffineTransform(
                translationX: -target.minX,
                y: -target.minY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(width) / target.width,
                y: CGFloat(height) / target.height
            ))
            .cropped(to: outputBounds)
        var pixels = [UInt8](repeating: 0, count: rowBytes * height)
        context.render(
            image, toBitmap: &pixels, rowBytes: rowBytes, bounds: outputBounds,
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!
        )
        return pixels
    }

    private static func meanAbsoluteDifference(_ previous: [UInt8], _ current: [UInt8]) -> Double {
        guard previous.count == current.count, !current.isEmpty else { return 0 }
        var total = 0
        var channels = 0
        for offset in stride(from: 0, to: current.count, by: 4) {
            total += abs(Int(current[offset]) - Int(previous[offset]))
            total += abs(Int(current[offset + 1]) - Int(previous[offset + 1]))
            total += abs(Int(current[offset + 2]) - Int(previous[offset + 2]))
            channels += 3
        }
        return channels == 0 ? 0 : Double(total) / Double(channels)
    }

    private static func halfScaleRGBA(
        _ source: [UInt8], sourceWidth: Int, sourceHeight: Int
    ) -> [UInt8] {
        let width = sourceWidth / 2
        let height = sourceHeight / 2
        var result = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let sourceOffset = ((y * 2) * sourceWidth + x * 2) * 4
                let destinationOffset = (y * width + x) * 4
                result[destinationOffset] = source[sourceOffset]
                result[destinationOffset + 1] = source[sourceOffset + 1]
                result[destinationOffset + 2] = source[sourceOffset + 2]
                result[destinationOffset + 3] = source[sourceOffset + 3]
            }
        }
        return result
    }

}
