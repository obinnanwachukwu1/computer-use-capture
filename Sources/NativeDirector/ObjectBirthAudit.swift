import CoreGraphics
import Foundation

/// A declarative certificate for every object-candidate birth.
///
/// This does not decide whether an object is editorially interesting. It only
/// answers whether a visually sourced candidate has temporally and spatially
/// overlapping detector evidence at the moment it first becomes visible.
public struct ObjectBirthAudit: Sendable {
    public enum Status: String, Sendable {
        case supported
        case unsupported
        case nonVisualEvidence
    }

    public struct Support: Sendable {
        public let startTime: Double
        public let endTime: Double
        public let normalizedBounds: CGRect
        public let overlap: Double
        public let changedFraction: Double
        public let localChangedDensity: Double
        public let confidence: Double
    }

    public struct Entry: Sendable {
        public let candidateID: Int
        public let source: InteractionObjectGraph.Source
        public let birthTime: Double
        public let deathTime: Double
        public let bounds: CGRect
        public let normalizedBounds: CGRect
        public let actionIDs: [Int]
        public let status: Status
        public let birthLagMilliseconds: Double?
        public let support: [Support]
    }

    public let entries: [Entry]

    public var unsupportedVisualBirths: [Entry] {
        entries.filter { $0.status == .unsupported }
    }

    public static func make(
        objects: InteractionObjectGraph,
        evidence: [EpisodeVisualEvidence],
        contentRect: CGRect,
        temporalTolerance: Double = 0.06,
        spatialOverlapThreshold: Double = 0.20
    ) -> ObjectBirthAudit {
        var entries: [Entry] = []
        for candidate in objects.candidates {
            let candidateBounds = normalized(candidate.bounds, in: contentRect)
            let birth = candidate.sourceRange.lowerBound
            let death = candidate.sourceRange.upperBound
            if candidate.source != .visualResidual && candidate.source != .visualLifecycle {
                entries.append(Entry(
                    candidateID: candidate.id,
                    source: candidate.source,
                    birthTime: birth,
                    deathTime: death,
                    bounds: candidate.bounds,
                    normalizedBounds: candidateBounds,
                    actionIDs: candidate.actionIDs,
                    status: .nonVisualEvidence,
                    birthLagMilliseconds: nil,
                    support: []
                ))
                continue
            }

            let compatibleActionIDs = Set(candidate.actionIDs)
            var supports: [Support] = []
            for sample in evidence {
                let actionCompatible = compatibleActionIDs.isEmpty
                    ? sample.actionID < 0
                    : compatibleActionIDs.contains(sample.actionID)
                guard actionCompatible else { continue }
                let temporallyAtBirth = sample.startTime <= birth + temporalTolerance
                    && sample.endTime >= birth - temporalTolerance
                guard temporallyAtBirth else { continue }
                let spatial = overlap(candidateBounds, sample.normalizedBounds)
                guard spatial >= spatialOverlapThreshold else { continue }
                let sampleArea = max(
                    Double.leastNonzeroMagnitude,
                    Double(sample.normalizedBounds.width * sample.normalizedBounds.height)
                )
                supports.append(Support(
                    startTime: sample.startTime,
                    endTime: sample.endTime,
                    normalizedBounds: sample.normalizedBounds,
                    overlap: Double(spatial),
                    changedFraction: sample.changedFraction,
                    localChangedDensity: min(1, sample.changedFraction / sampleArea),
                    confidence: sample.confidence
                ))
            }
            supports.sort { left, right in
                left.startTime == right.startTime
                    ? left.endTime < right.endTime
                    : left.startTime < right.startTime
            }
            let firstSupport = supports.first
            let status: Status = supports.isEmpty ? .unsupported : .supported
            let birthLagMilliseconds: Double?
            if let firstSupport {
                birthLagMilliseconds = (birth - firstSupport.startTime) * 1_000
            } else {
                birthLagMilliseconds = nil
            }
            entries.append(Entry(
                candidateID: candidate.id,
                source: candidate.source,
                birthTime: birth,
                deathTime: death,
                bounds: candidate.bounds,
                normalizedBounds: candidateBounds,
                actionIDs: candidate.actionIDs,
                status: status,
                birthLagMilliseconds: birthLagMilliseconds,
                support: supports
            ))
        }
        entries.sort { left, right in
            left.birthTime == right.birthTime
                ? left.candidateID < right.candidateID
                : left.birthTime < right.birthTime
        }
        return ObjectBirthAudit(entries: entries)
    }
}

private func normalized(_ bounds: CGRect, in contentRect: CGRect) -> CGRect {
    guard contentRect.width > 0, contentRect.height > 0 else { return .null }
    return CGRect(
        x: (bounds.minX - contentRect.minX) / contentRect.width,
        y: (contentRect.maxY - bounds.maxY) / contentRect.height,
        width: bounds.width / contentRect.width,
        height: bounds.height / contentRect.height
    )
}

private func overlap(_ left: CGRect, _ right: CGRect) -> CGFloat {
    let shared = left.intersection(right)
    guard !shared.isNull else { return 0 }
    let smaller = min(left.width * left.height, right.width * right.height)
    guard smaller > .leastNonzeroMagnitude else { return 0 }
    return shared.width * shared.height / smaller
}
