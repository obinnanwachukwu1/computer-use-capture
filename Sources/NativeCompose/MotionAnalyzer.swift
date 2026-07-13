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

enum MotionAnalyzer {
    static func analyze(
        asset: AVAsset,
        track: AVAssetTrack,
        context: CIContext,
        sourceDuration: Double,
        actionTimes: [Double] = [],
        timingProbes: [InteractionTimingProbe] = [],
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
        var nextProgressTime = 10.0

        while let sample = output.copyNextSampleBuffer() {
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { continue }
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

            if time + 0.0001 < nextSampleTime { continue }
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
        }
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

}
