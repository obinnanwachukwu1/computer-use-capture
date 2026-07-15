import Foundation

struct PipelineProfilePhase: Codable {
    let name: String
    let seconds: Double
}

struct PipelineProfileReport: Codable {
    let version: Int
    let mode: String
    let planner: String
    let source: String
    let timeline: String
    let output: String
    let sourceDurationSeconds: Double
    let outputDurationSeconds: Double
    let sourceWidth: Int
    let sourceHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let fps: Int32
    let temporalSamples: Int
    let analysisCacheHit: Bool
    let analyzedFrames: Int
    let motionFrames: Int
    let actionCount: Int
    let shotCount: Int
    let outputFrameCount: Int
    let phases: [PipelineProfilePhase]
    let totalSeconds: Double
}

/// Records mutually exclusive wall-clock phases from the real export path.
/// Keeping this in-process avoids attributing Swift startup or benchmark
/// harness overhead to motion analysis, planning, or rendering.
final class PipelineProfiler {
    private let started = DispatchTime.now().uptimeNanoseconds
    private var phaseStarted: UInt64
    private(set) var phases: [PipelineProfilePhase] = []

    init() {
        phaseStarted = started
    }

    func complete(_ name: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        phases.append(PipelineProfilePhase(
            name: name,
            seconds: Double(now - phaseStarted) / 1_000_000_000
        ))
        phaseStarted = now
    }

    func write(
        to url: URL,
        mode: String,
        planner: String,
        source: URL,
        timeline: URL,
        output: URL,
        sourceDuration: Double,
        outputDuration: Double,
        sourceSize: CGSize,
        outputSize: CGSize,
        fps: Int32,
        samples: Int,
        analysisCacheHit: Bool,
        analyzedFrames: Int,
        motionFrames: Int,
        actionCount: Int,
        shotCount: Int,
        outputFrameCount: Int
    ) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        let report = PipelineProfileReport(
            version: 1,
            mode: mode,
            planner: planner,
            source: source.path,
            timeline: timeline.path,
            output: output.path,
            sourceDurationSeconds: sourceDuration,
            outputDurationSeconds: outputDuration,
            sourceWidth: Int(sourceSize.width.rounded()),
            sourceHeight: Int(sourceSize.height.rounded()),
            outputWidth: Int(outputSize.width.rounded()),
            outputHeight: Int(outputSize.height.rounded()),
            fps: fps,
            temporalSamples: samples,
            analysisCacheHit: analysisCacheHit,
            analyzedFrames: analyzedFrames,
            motionFrames: motionFrames,
            actionCount: actionCount,
            shotCount: shotCount,
            outputFrameCount: outputFrameCount,
            phases: phases,
            totalSeconds: Double(now - started) / 1_000_000_000
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: url, options: .atomic)
        print("native profile=\(url.path) total=\(String(format: "%.3f", report.totalSeconds))s")
    }
}
