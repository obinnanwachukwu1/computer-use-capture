import CoreGraphics
import Foundation

/// Evaluation-only conditions for the foreground-support factorial.
///
/// Production remains byte-for-byte equivalent to the historical objective.
/// These conditions are selected only by an explicit native-compose flag and
/// are deliberately absent from the MCP contract.
public enum ProductionEvaluationCondition: String, Codable, Sendable, CaseIterable {
    case production
    case aCurrent = "a-current"
    case bOptionalMotion = "b-optional-motion"
    case cOracleCurrent = "c-oracle-current"
    case dOracleGated = "d-oracle-gated"

    public var usesOracleSupport: Bool {
        self == .cOracleCurrent || self == .dOracleGated
    }

    public var gatesMotionWithOracleSupport: Bool {
        self == .dOracleGated
    }

    public var plannerVersion: String {
        self == .production ? "normal" : "normal-eval-\(rawValue)"
    }
}

/// The planner's ownership contract for visual observations. Factual Computer
/// Use and Accessibility evidence is not represented here; it remains a hard
/// camera-feasibility constraint in ProductionPlanner.
public enum PlannerObservationClass: String, Codable, Sendable {
    case requiredContext
    case foregroundEditorial
    case motionEditorial
    case oracleForegroundSupport
}

public struct OracleForegroundSupportLifecycle: Sendable {
    public let bounds: CGRect
    public let gainedAt: Double
    public let releasedAt: Double
    public let gainedObservationID: Int
    public let releasedObservationID: Int
}

public struct OracleForegroundSupportEvidence: Sendable {
    public let observations: [VisualMotionObservation]
    public let lifecycles: [OracleForegroundSupportLifecycle]
}

/// Manually authored visible foreground support used to test whether perfect
/// geometry improves final camera decisions before a detector is built.
///
/// This fixture is intentionally bounds-based. It is not the proposed
/// production estimator contract and makes no claim about occluded pixels.
public struct OracleForegroundSupportFixture: Codable, Sendable {
    public struct Bounds: Codable, Sendable {
        public let x: Double
        public let y: Double
        public let width: Double
        public let height: Double

        public var rect: CGRect {
            CGRect(x: x, y: y, width: width, height: height)
        }
    }

    public struct Span: Codable, Sendable {
        public let id: String
        public let lifecycleId: String
        public let startTime: Double
        public let endTime: Double
        public let bounds: Bounds
        public let confidence: Double
        public let abstained: Bool
        public let note: String?
    }

    public let version: Int
    public let coordinateSpace: String
    public let observations: [Span]

    public init(version: Int, coordinateSpace: String, observations: [Span]) {
        self.version = version
        self.coordinateSpace = coordinateSpace
        self.observations = observations
    }

    public func validated(sourceDuration: Double) throws -> OracleForegroundSupportFixture {
        guard version == 1 else {
            throw OracleForegroundSupportError.invalid("unsupported oracle support version \(version)")
        }
        guard coordinateSpace == "source-window-normalized-top-left" else {
            throw OracleForegroundSupportError.invalid("oracle support coordinateSpace must be source-window-normalized-top-left")
        }
        var ids = Set<String>()
        for span in observations {
            guard ids.insert(span.id).inserted else {
                throw OracleForegroundSupportError.invalid("duplicate oracle support id \(span.id)")
            }
            guard span.startTime >= 0, span.endTime > span.startTime,
                  span.endTime <= sourceDuration + 0.001 else {
                throw OracleForegroundSupportError.invalid("oracle support \(span.id) has an invalid time range")
            }
            let rect = span.bounds.rect
            guard rect.width > 0, rect.height > 0,
                  rect.minX >= 0, rect.minY >= 0,
                  rect.maxX <= 1, rect.maxY <= 1 else {
                throw OracleForegroundSupportError.invalid("oracle support \(span.id) has non-normalized bounds")
            }
            guard span.confidence >= 0, span.confidence <= 1 else {
                throw OracleForegroundSupportError.invalid("oracle support \(span.id) confidence must be between 0 and 1")
            }
        }
        return self
    }

    /// Emits only observable lifecycle endpoints. The global graph reconstructs
    /// the held interval using the same deterministic lifecycle machinery used
    /// for pixel-derived focus observations.
    public func visualObservations() -> [VisualMotionObservation] {
        plannerEvidence(startingObservationID: 0).observations
    }

    public func plannerEvidence(startingObservationID: Int) -> OracleForegroundSupportEvidence {
        var visual: [VisualMotionObservation] = []
        var lifecycles: [OracleForegroundSupportLifecycle] = []
        for span in observations.filter({ !$0.abstained }).sorted(by: {
            $0.startTime == $1.startTime ? $0.id < $1.id : $0.startTime < $1.startTime
        }) {
            let confidence = min(1, max(0, span.confidence))
            let area = Double(span.bounds.rect.width * span.bounds.rect.height)
            let changed = min(0.35, max(0.01, area * 0.35))
            let gainedObservationID = startingObservationID + visual.count
            visual.append(
                VisualMotionObservation(
                    time: span.startTime,
                    normalizedBounds: span.bounds.rect,
                    changedFraction: changed,
                    magnitude: confidence,
                    kind: .focus,
                    focusTransition: .gained,
                    startTime: span.startTime
                )
            )
            let releasedObservationID = startingObservationID + visual.count
            visual.append(
                VisualMotionObservation(
                    time: span.endTime,
                    normalizedBounds: span.bounds.rect,
                    changedFraction: changed,
                    magnitude: confidence,
                    kind: .focus,
                    focusTransition: .released,
                    startTime: span.endTime
                )
            )
            lifecycles.append(OracleForegroundSupportLifecycle(
                bounds: span.bounds.rect,
                gainedAt: span.startTime,
                releasedAt: span.endTime,
                gainedObservationID: gainedObservationID,
                releasedObservationID: releasedObservationID
            ))
        }
        return OracleForegroundSupportEvidence(observations: visual, lifecycles: lifecycles)
    }
}

public enum OracleForegroundSupportError: Error, CustomStringConvertible {
    case invalid(String)

    public var description: String {
        switch self {
        case .invalid(let message): message
        }
    }
}
