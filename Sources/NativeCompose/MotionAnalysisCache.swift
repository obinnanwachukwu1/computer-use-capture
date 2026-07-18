import CryptoKit
import Foundation
import NativeDirector

private struct MotionAnalysisCacheFile: Codable {
    struct Range: Codable {
        let start: Double
        let end: Double
    }

    let version: Int
    let fingerprint: String
    let ranges: [Range]
    let sampledFrames: Int
    let motionFrames: Int
    let observations: [VisualMotionObservation]
    let interactionPhases: [Int: InteractionPhases]
    let episodeVisualEvidence: [EpisodeVisualEvidence]
}

private struct MotionAnalysisFingerprint: Codable {
    struct ActionTime: Codable {
        let actionID: Int
        let time: Double
    }

    struct Probe: Codable {
        let actionID: Int
        let rawEstimate: Double
        let toolStart: Double
        let toolEnd: Double
        let finalActionInToolCall: Bool
        let targetX: Double
        let targetY: Double
        let targetWidth: Double
        let targetHeight: Double
        let hasSpatialTarget: Bool
        let focusIntent: String
    }

    let analyzerRevision: Int
    let fallbackActionTimes: [ActionTime]
    let timingProbes: [Probe]
    let relocationActionIDs: [Int]
}

enum MotionAnalysisCache {
    // Increment whenever detector semantics or default analyzer parameters
    // change. The source digest alone cannot invalidate derived evidence when
    // the implementation evolves.
    private static let formatVersion = 1
    // Revision 15 makes the pre-activation sample the causal baseline. The
    // sampled frame carrying activation belongs to the response; using it as
    // the baseline erased instantaneous births and releases.
    private static let analyzerRevision = 15

    static func resolve(
        source: URL,
        fallbackActionTimes: [Int: Double],
        timingProbes: [InteractionTimingProbe],
        relocationActionIDs: Set<Int>,
        enabled: Bool,
        collectMotionFields: Bool,
        compute: () throws -> MotionAnalysis
    ) throws -> (analysis: MotionAnalysis, hit: Bool) {
        guard enabled, !collectMotionFields else {
            return (try compute(), false)
        }
        let fingerprint = try makeFingerprint(
            source: source,
            fallbackActionTimes: fallbackActionTimes,
            timingProbes: timingProbes,
            relocationActionIDs: relocationActionIDs
        )
        let url = cacheURL(for: source)
        if let data = try? Data(contentsOf: url),
           let cached = try? JSONDecoder().decode(MotionAnalysisCacheFile.self, from: data),
           cached.version == formatVersion,
           cached.fingerprint == fingerprint {
            print("motion analysis cache=hit path=\(url.path)")
            return (MotionAnalysis(
                ranges: cached.ranges.map { $0.start...$0.end },
                sampledFrames: cached.sampledFrames,
                motionFrames: cached.motionFrames,
                observations: cached.observations,
                interactionPhases: cached.interactionPhases,
                motionFields: [],
                episodeVisualEvidence: cached.episodeVisualEvidence
            ), true)
        }

        print("motion analysis cache=miss path=\(url.path)")
        let analysis = try compute()
        let file = MotionAnalysisCacheFile(
            version: formatVersion,
            fingerprint: fingerprint,
            ranges: analysis.ranges.map { .init(start: $0.lowerBound, end: $0.upperBound) },
            sampledFrames: analysis.sampledFrames,
            motionFrames: analysis.motionFrames,
            observations: analysis.observations,
            interactionPhases: analysis.interactionPhases,
            episodeVisualEvidence: analysis.episodeVisualEvidence
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: url, options: .atomic)
        } catch {
            // Cache persistence is an optimization. Read-only sources and
            // transient disk errors must not make composition unavailable.
            print("motion analysis cache=write-failed error=\(error.localizedDescription)")
        }
        return (analysis, false)
    }

    static func cacheURL(for source: URL) -> URL {
        URL(fileURLWithPath: source.path + ".motion-analysis.cache.json")
    }

    private static func makeFingerprint(
        source: URL,
        fallbackActionTimes: [Int: Double],
        timingProbes: [InteractionTimingProbe],
        relocationActionIDs: Set<Int>
    ) throws -> String {
        let input = MotionAnalysisFingerprint(
            analyzerRevision: analyzerRevision,
            fallbackActionTimes: fallbackActionTimes.sorted(by: { $0.key < $1.key }).map {
                .init(actionID: $0.key, time: $0.value)
            },
            timingProbes: timingProbes.sorted(by: { $0.actionID < $1.actionID }).map {
                .init(
                    actionID: $0.actionID,
                    rawEstimate: $0.rawEstimate,
                    toolStart: $0.toolStart,
                    toolEnd: $0.toolEnd,
                    finalActionInToolCall: $0.finalActionInToolCall,
                    targetX: $0.normalizedTarget.minX,
                    targetY: $0.normalizedTarget.minY,
                    targetWidth: $0.normalizedTarget.width,
                    targetHeight: $0.normalizedTarget.height,
                    hasSpatialTarget: $0.hasSpatialTarget,
                    focusIntent: $0.focusIntent == .dismissal ? "dismissal" : "automatic"
                )
            },
            relocationActionIDs: relocationActionIDs.sorted()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = SHA256()
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 4 * 1024 * 1024), !data.isEmpty {
            hasher.update(data: data)
        }
        hasher.update(data: try encoder.encode(input))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
