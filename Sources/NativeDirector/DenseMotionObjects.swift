import CoreGraphics
import Foundation

/// Offline object hypotheses built from complete dense-motion lifecycles.
///
/// Tracks remain the atomic evidence. An ensemble only states that several
/// disconnected tracks share one synchronized visual lifecycle; it never
/// erases their masks or claims that the camera should frame their union.
public struct DenseMotionObjectGraph: Sendable {
    public enum Kind: String, Sendable {
        case atomic
        case compactObject
        case correlatedChange
        case broadContext
    }

    public struct Ensemble: Sendable {
        public let id: Int
        public let trackIDs: [Int]
        public let startTime: Double
        public let endTime: Double
        public let normalizedBounds: CGRect
        public let lifecycleConfidence: Double
        public let spatialOccupancy: Double
        public let kind: Kind
    }

    public let ensembles: [Ensemble]

    /// Produces a deterministic, complete-link partition over whole track
    /// lifecycles. Unlike spatial connected components, a nearby box cannot
    /// pull another box into an object one frame at a time: every pair in an
    /// ensemble must independently agree about birth and release timing.
    public static func make(
        tracks: DenseMotionTrackGraph,
        synchronizationTolerance: Double = 0.24,
        minimumLifecycleAffinity: Double = 0.78
    ) -> DenseMotionObjectGraph {
        guard !tracks.tracks.isEmpty else { return DenseMotionObjectGraph(ensembles: []) }
        let ordered = tracks.tracks.sorted { $0.id < $1.id }
        var clusters = ordered.indices.map { [$0] }

        while true {
            var best: (left: Int, right: Int, score: Double)?
            for left in clusters.indices {
                for right in clusters.indices where right > left {
                    guard let score = completeLinkAffinity(
                        clusters[left],
                        clusters[right],
                        tracks: ordered,
                        tolerance: synchronizationTolerance,
                        minimumAffinity: minimumLifecycleAffinity
                    ) else { continue }
                    if best == nil
                        || score > best!.score + 0.000_000_1
                        || (abs(score - best!.score) <= 0.000_000_1
                            && clusterKey(clusters[left], tracks: ordered)
                                < clusterKey(clusters[best!.left], tracks: ordered))
                    {
                        best = (left, right, score)
                    }
                }
            }
            guard let best else { break }
            clusters[best.left] = (clusters[best.left] + clusters[best.right]).sorted()
            clusters.remove(at: best.right)
        }

        let unresolved = clusters.map { members -> Ensemble in
            let memberTracks = members.map { ordered[$0] }
            let bounds = memberTracks.dropFirst().reduce(memberTracks[0].normalizedBounds) {
                $0.union($1.normalizedBounds)
            }
            let boundsArea = max(0.000_001, bounds.width * bounds.height)
            let memberArea = memberTracks.reduce(0.0) {
                $0 + $1.normalizedBounds.width * $1.normalizedBounds.height
            }
            let occupancy = min(1, memberArea / boundsArea)
            let affinities = pairwiseAffinities(memberTracks, tolerance: synchronizationTolerance)
            let confidence = affinities.isEmpty ? 1 : affinities.reduce(0, +) / Double(affinities.count)
            let kind: Kind
            if memberTracks.count == 1 {
                let track = memberTracks[0]
                // A coherent lifecycle does not become less object-like merely
                // because its changed pixels happened to stay connected. A
                // measured static hold provides the missing persistence proof.
                kind = track.componentIDs.count >= 3
                    && track.maximumGap >= 1.0
                    && !track.isBroadContext
                    ? .compactObject
                    : .atomic
            } else if isBroadEnvelope(bounds, occupancy: occupancy) {
                kind = .broadContext
            } else if occupancy < 0.25 {
                // Shared timing alone is enough to establish a common event,
                // but not enough to invent a filled object between sparse
                // fragments (for example two scrollbar updates).
                kind = .correlatedChange
            } else {
                kind = .compactObject
            }
            return Ensemble(
                id: 0,
                trackIDs: memberTracks.map(\.id).sorted(),
                startTime: memberTracks.map(\.startTime).min()!,
                endTime: memberTracks.map(\.endTime).max()!,
                normalizedBounds: bounds,
                lifecycleConfidence: confidence,
                spatialOccupancy: occupancy,
                kind: kind
            )
        }.sorted {
            if $0.startTime != $1.startTime { return $0.startTime < $1.startTime }
            if $0.normalizedBounds.minY != $1.normalizedBounds.minY {
                return $0.normalizedBounds.minY < $1.normalizedBounds.minY
            }
            return $0.normalizedBounds.minX < $1.normalizedBounds.minX
        }

        return DenseMotionObjectGraph(ensembles: unresolved.enumerated().map { id, ensemble in
            Ensemble(
                id: id,
                trackIDs: ensemble.trackIDs,
                startTime: ensemble.startTime,
                endTime: ensemble.endTime,
                normalizedBounds: ensemble.normalizedBounds,
                lifecycleConfidence: ensemble.lifecycleConfidence,
                spatialOccupancy: ensemble.spatialOccupancy,
                kind: ensemble.kind
            )
        })
    }
}

private func completeLinkAffinity(
    _ left: [Int],
    _ right: [Int],
    tracks: [DenseMotionTrackGraph.Track],
    tolerance: Double,
    minimumAffinity: Double
) -> Double? {
    var scores: [Double] = []
    for leftIndex in left {
        for rightIndex in right {
            let score = lifecycleAffinity(tracks[leftIndex], tracks[rightIndex], tolerance: tolerance)
            guard score >= minimumAffinity else { return nil }
            scores.append(score)
        }
    }
    guard !scores.isEmpty else { return nil }
    return scores.reduce(0, +) / Double(scores.count)
}

private func pairwiseAffinities(
    _ tracks: [DenseMotionTrackGraph.Track],
    tolerance: Double
) -> [Double] {
    guard tracks.count > 1 else { return [] }
    var result: [Double] = []
    for left in tracks.indices {
        for right in tracks.indices where right > left {
            result.append(lifecycleAffinity(tracks[left], tracks[right], tolerance: tolerance))
        }
    }
    return result
}

private func lifecycleAffinity(
    _ left: DenseMotionTrackGraph.Track,
    _ right: DenseMotionTrackGraph.Track,
    tolerance: Double
) -> Double {
    let leftDuration = left.endTime - left.startTime
    let rightDuration = right.endTime - right.startTime
    let bothImpulses = leftDuration <= tolerance && rightDuration <= tolerance
    if bothImpulses {
        let leftMidpoint = (left.startTime + left.endTime) * 0.5
        let rightMidpoint = (right.startTime + right.endTime) * 0.5
        return max(0, 1 - abs(leftMidpoint - rightMidpoint) / tolerance)
    }
    guard leftDuration > tolerance, rightDuration > tolerance else { return 0 }
    let birth = max(0, 1 - abs(left.startTime - right.startTime) / tolerance)
    let release = max(0, 1 - abs(left.endTime - right.endTime) / tolerance)
    let duration = min(leftDuration, rightDuration) / max(leftDuration, rightDuration)
    // Birth and release are factual lifecycle boundaries. Duration prevents a
    // brief nested animation from being mistaken for the containing surface.
    return birth * 0.42 + release * 0.42 + duration * 0.16
}

private func isBroadEnvelope(_ bounds: CGRect, occupancy: Double) -> Bool {
    let area = bounds.width * bounds.height
    return area >= 0.48
        || (bounds.width >= 0.78 && bounds.height >= 0.40)
        || (bounds.height >= 0.74 && bounds.width >= 0.36)
        || (area >= 0.30 && occupancy < 0.28)
}

private func clusterKey(
    _ cluster: [Int],
    tracks: [DenseMotionTrackGraph.Track]
) -> Int {
    cluster.map { tracks[$0].id }.min() ?? .max
}
