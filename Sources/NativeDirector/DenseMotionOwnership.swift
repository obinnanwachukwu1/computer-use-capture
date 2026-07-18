import CoreGraphics
import Foundation

/// A conservative, pixel-derived foreground-support hypothesis.
///
/// This is deliberately not a semantic object. It describes visible support
/// that survived the independent before/held/after lifecycle test. Motion and
/// transport evidence may be associated with it only after the complete clip
/// is available; the seed's birth and release times are never rewritten by
/// that association.
public struct ForegroundSupportSeed: Sendable {
    public let id: Int
    public let normalizedBounds: CGRect
    public let tileIndices: [Int]
    public let birthTime: Double
    public let heldTime: Double
    public let releaseTime: Double
    public let supportConfidence: Double
    public let provenanceMotionTrackIDs: [Int]

    public init(
        id: Int,
        normalizedBounds: CGRect,
        tileIndices: [Int],
        birthTime: Double,
        heldTime: Double,
        releaseTime: Double,
        supportConfidence: Double,
        provenanceMotionTrackIDs: [Int]
    ) {
        self.id = id
        self.normalizedBounds = normalizedBounds
        self.tileIndices = tileIndices.sorted()
        self.birthTime = birthTime
        self.heldTime = heldTime
        self.releaseTime = releaseTime
        self.supportConfidence = supportConfidence
        self.provenanceMotionTrackIDs = provenanceMotionTrackIDs.sorted()
    }
}

/// Clip-global evidence ownership for accepted foreground support.
///
/// Every track is compared with every lifecycle plus an explicit unowned
/// alternative. Close competing scores abstain as ambiguous. This layer does
/// not create support from motion, does not impose a depth order, and is not a
/// camera decision. It exists to audit how much measured motion has unique
/// support ownership before any director integration is considered.
public struct DenseMotionOwnershipGraph: Sendable {
    public enum Status: String, Sendable {
        case provenance
        case inferred
        case ambiguous
        case unowned
    }

    public struct Candidate: Sendable {
        public let lifecycleID: Int
        public let score: Double
    }

    public struct Assignment: Sendable {
        public let trackID: Int
        public let lifecycleID: Int?
        public let status: Status
        public let score: Double
        public let candidates: [Candidate]
    }

    public struct Lifecycle: Sendable {
        public let id: Int
        public let normalizedBounds: CGRect
        public let tileIndices: [Int]
        public let birthTime: Double
        public let heldTime: Double
        public let releaseTime: Double
        public let supportConfidence: Double
        /// Earliest and latest associated evidence. These are diagnostic
        /// support ranges, not inferred replacements for birth/release.
        public let supportingEvidenceStart: Double
        public let supportingEvidenceEnd: Double
        public let motionTrackIDs: [Int]
        public let transportTrackIDs: [Int]
    }

    public let lifecycles: [Lifecycle]
    public let motionAssignments: [Assignment]
    public let transportAssignments: [Assignment]

    public static func make(
        seeds: [ForegroundSupportSeed],
        motion: DenseMotionTrackGraph,
        transport: DenseMotionTransportGraph
    ) -> DenseMotionOwnershipGraph {
        let orderedSeeds = seeds.sorted { $0.id < $1.id }
        guard !orderedSeeds.isEmpty else {
            return DenseMotionOwnershipGraph(
                lifecycles: [],
                motionAssignments: motion.tracks.map {
                    Assignment(trackID: $0.id, lifecycleID: nil, status: .unowned, score: 0, candidates: [])
                },
                transportAssignments: transport.tracks.map {
                    Assignment(trackID: $0.id, lifecycleID: nil, status: .unowned, score: 0, candidates: [])
                }
            )
        }

        let motionComponents = Dictionary(uniqueKeysWithValues: motion.components.map { ($0.id, $0) })
        let transportComponents = Dictionary(uniqueKeysWithValues: transport.components.map { ($0.id, $0) })
        let motionAssignments = motion.tracks.map { track -> Assignment in
            let provenance = orderedSeeds.filter { $0.provenanceMotionTrackIDs.contains(track.id) }
            if provenance.count == 1 {
                return Assignment(
                    trackID: track.id,
                    lifecycleID: provenance[0].id,
                    status: .provenance,
                    score: 1,
                    candidates: [Candidate(lifecycleID: provenance[0].id, score: 1)]
                )
            }
            if provenance.count > 1 {
                return Assignment(
                    trackID: track.id,
                    lifecycleID: nil,
                    status: .ambiguous,
                    score: 1,
                    candidates: provenance.map { Candidate(lifecycleID: $0.id, score: 1) }
                )
            }
            let members = track.componentIDs.compactMap { motionComponents[$0] }
            let candidates = orderedSeeds.compactMap { seed -> Candidate? in
                guard let score = motionOwnershipScore(track: track, components: members, seed: seed) else {
                    return nil
                }
                return Candidate(lifecycleID: seed.id, score: score)
            }
            return resolve(trackID: track.id, candidates: candidates)
        }.sorted { $0.trackID < $1.trackID }

        let transportAssignments = transport.tracks.map { track -> Assignment in
            let members = track.componentIDs.compactMap { transportComponents[$0] }
            let candidates = orderedSeeds.compactMap { seed -> Candidate? in
                guard let score = transportOwnershipScore(track: track, components: members, seed: seed) else {
                    return nil
                }
                return Candidate(lifecycleID: seed.id, score: score)
            }
            return resolve(trackID: track.id, candidates: candidates)
        }.sorted { $0.trackID < $1.trackID }

        let lifecycles = orderedSeeds.map { seed -> Lifecycle in
            let ownedMotion = motionAssignments.filter { $0.lifecycleID == seed.id }
            let ownedTransport = transportAssignments.filter { $0.lifecycleID == seed.id }
            let motionByID = Dictionary(uniqueKeysWithValues: motion.tracks.map { ($0.id, $0) })
            let transportByID = Dictionary(uniqueKeysWithValues: transport.tracks.map { ($0.id, $0) })
            let starts = ownedMotion.compactMap { motionByID[$0.trackID]?.startTime }
                + ownedTransport.compactMap { transportByID[$0.trackID]?.startTime }
            let ends = ownedMotion.compactMap { motionByID[$0.trackID]?.endTime }
                + ownedTransport.compactMap { transportByID[$0.trackID]?.endTime }
            return Lifecycle(
                id: seed.id,
                normalizedBounds: seed.normalizedBounds,
                tileIndices: seed.tileIndices,
                birthTime: seed.birthTime,
                heldTime: seed.heldTime,
                releaseTime: seed.releaseTime,
                supportConfidence: seed.supportConfidence,
                supportingEvidenceStart: min(seed.birthTime, starts.min() ?? seed.birthTime),
                supportingEvidenceEnd: max(seed.releaseTime, ends.max() ?? seed.releaseTime),
                motionTrackIDs: ownedMotion.map(\.trackID).sorted(),
                transportTrackIDs: ownedTransport.map(\.trackID).sorted()
            )
        }
        return DenseMotionOwnershipGraph(
            lifecycles: lifecycles,
            motionAssignments: motionAssignments,
            transportAssignments: transportAssignments
        )
    }
}

private func resolve(
    trackID: Int,
    candidates: [DenseMotionOwnershipGraph.Candidate]
) -> DenseMotionOwnershipGraph.Assignment {
    let ranked = candidates.sorted {
        if abs($0.score - $1.score) > 0.000_000_1 { return $0.score > $1.score }
        return $0.lifecycleID < $1.lifecycleID
    }
    guard let first = ranked.first, first.score >= 0.62 else {
        return DenseMotionOwnershipGraph.Assignment(
            trackID: trackID,
            lifecycleID: nil,
            status: .unowned,
            score: ranked.first?.score ?? 0,
            candidates: ranked
        )
    }
    if let second = ranked.dropFirst().first, first.score - second.score < 0.14 {
        return DenseMotionOwnershipGraph.Assignment(
            trackID: trackID,
            lifecycleID: nil,
            status: .ambiguous,
            score: first.score,
            candidates: ranked
        )
    }
    return DenseMotionOwnershipGraph.Assignment(
        trackID: trackID,
        lifecycleID: first.lifecycleID,
        status: .inferred,
        score: first.score,
        candidates: ranked
    )
}

private func motionOwnershipScore(
    track: DenseMotionTrackGraph.Track,
    components: [DenseMotionTrackGraph.Component],
    seed: ForegroundSupportSeed
) -> Double? {
    guard !components.isEmpty, !track.isBroadContext else { return nil }
    let supportTiles = Set(seed.tileIndices)
    let samples = components.map { component -> (support: Double, temporal: Double) in
        let geometric = overlapFraction(component.normalizedBounds, seed.normalizedBounds)
        let tile = component.tileIndices.isEmpty ? 0 : Double(component.tileIndices.filter {
            supportTiles.contains($0)
        }.count) / Double(component.tileIndices.count)
        let support = geometric * 0.58 + tile * 0.42
        return (support, lifecycleTemporalAffinity(component.time, seed: seed))
    }
    let supported = samples.filter { $0.support >= 0.20 && $0.temporal >= 0.20 }
    guard let strongest = supported.map(\.support).max() else { return nil }
    let ranked = supported.map(\.support).sorted(by: >)
    let repeated = ranked.prefix(3).reduce(0, +) / Double(min(3, ranked.count))
    let temporal = supported.map(\.temporal).max() ?? 0
    guard strongest >= 0.30, temporal >= 0.28 else { return nil }
    return min(1,
        strongest * 0.46
            + repeated * 0.22
            + temporal * 0.17
            + track.continuityConfidence * 0.10
            + seed.supportConfidence * 0.05
    )
}

private func transportOwnershipScore(
    track: DenseMotionTransportGraph.Track,
    components: [DenseMotionTransportGraph.Component],
    seed: ForegroundSupportSeed
) -> Double? {
    let samples = components.map {
        (support: overlapFraction($0.normalizedBounds, seed.normalizedBounds),
         temporal: lifecycleTemporalAffinity($0.time, seed: seed))
    }.filter { $0.support >= 0.22 && $0.temporal >= 0.18 }
    guard samples.count >= 3,
          let strongest = samples.map(\.support).max(),
          strongest >= 0.38
    else { return nil }
    let ranked = samples.map(\.support).sorted(by: >)
    let repeated = ranked.prefix(5).reduce(0, +) / Double(min(5, ranked.count))
    let temporal = samples.map(\.temporal).max() ?? 0
    return min(1,
        strongest * 0.44
            + repeated * 0.24
            + temporal * 0.14
            + track.confidence * 0.13
            + seed.supportConfidence * 0.05
    )
}

private func lifecycleTemporalAffinity(_ time: Double, seed: ForegroundSupportSeed) -> Double {
    if time >= seed.birthTime && time <= seed.releaseTime { return 0.72 }
    let distance = min(abs(time - seed.birthTime), abs(time - seed.releaseTime))
    return exp(-distance / 0.45)
}

private func overlapFraction(_ left: CGRect, _ right: CGRect) -> Double {
    let intersection = left.intersection(right)
    guard !intersection.isNull else { return 0 }
    let shared = intersection.width * intersection.height
    let reference = min(left.width * left.height, right.width * right.height)
    return shared / max(0.000_001, reference)
}
