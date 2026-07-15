import Foundation

public enum CapturedFrameStatus: String, Codable, Equatable, Sendable {
    case complete
    case idle
    case blank
    case suspended
    case started
    case stopped
    case unknown
}

public enum FrameWriterDisposition: String, Codable, Equatable, Sendable {
    case appended
    case notApplicable
    case droppedBackpressure
    case droppedNonMonotonic
    case appendFailed
}

public enum CapturedPixelComparison: String, Codable, Equatable, Sendable {
    case changed
    case identical
    case unavailable
}

public struct CaptureDamageRect: Codable, Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct CapturedFrameSample: Codable, Equatable, Sendable {
    public let sourceTime: Double
    public let displayTime: UInt64?
    public let status: CapturedFrameStatus
    public let dirtyRects: [CaptureDamageRect]
    public let writerDisposition: FrameWriterDisposition
    public let pixelComparison: CapturedPixelComparison?

    public init(
        sourceTime: Double,
        displayTime: UInt64? = nil,
        status: CapturedFrameStatus,
        dirtyRects: [CaptureDamageRect] = [],
        writerDisposition: FrameWriterDisposition = .notApplicable,
        pixelComparison: CapturedPixelComparison? = nil
    ) {
        self.sourceTime = sourceTime
        self.displayTime = displayTime
        self.status = status
        self.dirtyRects = dirtyRects
        self.writerDisposition = writerDisposition
        self.pixelComparison = pixelComparison
    }
}

public struct CaptureIntegrity: Codable, Equatable, Sendable {
    public let invalidMetadataSamples: Int
    public let preRollSamples: Int
    public let droppedBackpressureFrames: Int
    public let droppedNonMonotonicFrames: Int
    public let appendFailedFrames: Int

    public init(
        invalidMetadataSamples: Int = 0,
        preRollSamples: Int = 0,
        droppedBackpressureFrames: Int = 0,
        droppedNonMonotonicFrames: Int = 0,
        appendFailedFrames: Int = 0
    ) {
        self.invalidMetadataSamples = invalidMetadataSamples
        self.preRollSamples = preRollSamples
        self.droppedBackpressureFrames = droppedBackpressureFrames
        self.droppedNonMonotonicFrames = droppedNonMonotonicFrames
        self.appendFailedFrames = appendFailedFrames
    }
}

public struct CaptureFrameLedger: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceTimebase: String
    public let expectedFrameInterval: Double
    public let samples: [CapturedFrameSample]
    public let integrity: CaptureIntegrity

    public init(
        version: Int = 1,
        sourceTimebase: String = "first-complete-frame-presentation-time",
        expectedFrameInterval: Double,
        samples: [CapturedFrameSample],
        integrity: CaptureIntegrity = CaptureIntegrity()
    ) {
        self.version = version
        self.sourceTimebase = sourceTimebase
        self.expectedFrameInterval = expectedFrameInterval
        self.samples = samples
        self.integrity = integrity
    }
}

public enum VisibleChangeState: String, Codable, Equatable, Sendable {
    case visibleChange
    case provenIdle
    case unknown
}

public struct VisibilityInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let state: VisibleChangeState

    public init(start: Double, end: Double, state: VisibleChangeState) {
        self.start = start
        self.end = end
        self.state = state
    }
}

public struct FactualActionWindow: Equatable, Sendable {
    public let id: Int
    public let actionID: String
    public let kind: String
    public let start: Double
    public let end: Double

    public init(id: Int, actionID: String, kind: String, start: Double, end: Double) {
        self.id = id
        self.actionID = actionID
        self.kind = kind
        self.start = start
        self.end = end
    }
}

public struct CaptureTruthAnalysis: Sendable {
    public let intervals: [VisibilityInterval]
    public let actionStates: [Int: VisibleChangeState]

    public var provenIdleRanges: [ClosedRange<Double>] {
        intervals.compactMap { interval in
            interval.state == .provenIdle && interval.end > interval.start
                ? interval.start...interval.end : nil
        }
    }

    public init(intervals: [VisibilityInterval], actionStates: [Int: VisibleChangeState]) {
        self.intervals = intervals
        self.actionStates = actionStates
    }
}

/// Converts WindowServer frame provenance into an asymmetric truth model.
/// Only consecutive, on-cadence exact pixel identity (or explicit idle
/// samples) proves absence. Every changed frame and integrity ambiguity stays.
public enum CaptureTruthAnalyzer {
    public static func analyze(
        ledger: CaptureFrameLedger,
        sourceDuration: Double,
        actions: [FactualActionWindow] = []
    ) -> CaptureTruthAnalysis {
        guard ledger.version == 1, sourceDuration > 0 else {
            return CaptureTruthAnalysis(
                intervals: sourceDuration > 0
                    ? [VisibilityInterval(start: 0, end: sourceDuration, state: .unknown)] : [],
                actionStates: Dictionary(uniqueKeysWithValues: actions.map { ($0.id, .unknown) })
            )
        }
        let recordedDrops = ledger.samples.filter { isDropped($0) }.count
        let declaredDrops = ledger.integrity.droppedBackpressureFrames
            + ledger.integrity.droppedNonMonotonicFrames
            + ledger.integrity.appendFailedFrames
        guard ledger.integrity.invalidMetadataSamples == 0,
              recordedDrops == declaredDrops
        else {
            return CaptureTruthAnalysis(
                intervals: [VisibilityInterval(start: 0, end: sourceDuration, state: .unknown)],
                actionStates: Dictionary(uniqueKeysWithValues: actions.map { ($0.id, .unknown) })
            )
        }
        let samples = ledger.samples
            .filter { $0.sourceTime.isFinite && $0.sourceTime >= 0 && $0.sourceTime <= sourceDuration }
            .sorted { $0.sourceTime < $1.sourceTime }
        guard samples.count >= 2 else {
            return CaptureTruthAnalysis(
                intervals: [VisibilityInterval(start: 0, end: sourceDuration, state: .unknown)],
                actionStates: Dictionary(uniqueKeysWithValues: actions.map { ($0.id, .unknown) })
            )
        }

        // More than four missed delivery opportunities is not proof of idle.
        // The floor accommodates small scheduling jitter without turning long
        // callback gaps into trusted evidence.
        let maximumGap = max(ledger.expectedFrameInterval * 4.5, 0.075)
        var intervals: [VisibilityInterval] = []
        if samples[0].sourceTime > 0 {
            append(
                VisibilityInterval(start: 0, end: samples[0].sourceTime, state: .unknown),
                to: &intervals
            )
        }
        for pair in zip(samples, samples.dropFirst()) {
            let start = max(0, pair.0.sourceTime)
            let end = min(sourceDuration, pair.1.sourceTime)
            guard end > start else { continue }
            let state: VisibleChangeState
            if end - start > maximumGap {
                state = .unknown
            } else if isDropped(pair.0) || isDropped(pair.1) {
                state = .unknown
            } else if pair.1.pixelComparison == .changed {
                state = .visibleChange
            } else if pair.1.pixelComparison == .identical {
                state = .provenIdle
            } else if pair.1.status == .complete || !pair.1.dirtyRects.isEmpty {
                // A complete frame without an exact raw-pixel comparison may
                // contain a change. Preserve it even when dirtyRects is empty.
                state = .visibleChange
            } else if pair.0.status == .idle && pair.1.status == .idle {
                state = .provenIdle
            } else {
                state = .unknown
            }
            append(VisibilityInterval(start: start, end: end, state: state), to: &intervals)
        }
        if let last = samples.last, last.sourceTime < sourceDuration {
            let tailState: VisibleChangeState = sourceDuration - last.sourceTime <= maximumGap
                && (last.pixelComparison == .identical || last.status == .idle)
                ? .provenIdle : .unknown
            append(
                VisibilityInterval(start: last.sourceTime, end: sourceDuration, state: tailState),
                to: &intervals
            )
        }

        let actionStates = Dictionary(uniqueKeysWithValues: actions.map { action in
            (action.id, classify(action: action, intervals: intervals))
        })
        return CaptureTruthAnalysis(intervals: intervals, actionStates: actionStates)
    }

    private static func isDropped(_ sample: CapturedFrameSample) -> Bool {
        switch sample.writerDisposition {
        case .droppedBackpressure, .droppedNonMonotonic, .appendFailed: true
        case .appended, .notApplicable: false
        }
    }

    private static func classify(
        action: FactualActionWindow,
        intervals: [VisibilityInterval]
    ) -> VisibleChangeState {
        guard action.start.isFinite, action.end.isFinite, action.end > action.start else {
            return .unknown
        }
        let overlapping = intervals.filter { $0.end > action.start && $0.start < action.end }
        if overlapping.contains(where: { $0.state == .visibleChange }) { return .visibleChange }
        guard !overlapping.isEmpty else { return .unknown }
        var cursor = action.start
        for interval in overlapping.sorted(by: { $0.start < $1.start }) {
            if interval.start > cursor + 0.000_001 || interval.state != .provenIdle {
                return .unknown
            }
            cursor = max(cursor, min(action.end, interval.end))
            if cursor >= action.end - 0.000_001 { return .provenIdle }
        }
        return .unknown
    }

    private static func append(_ interval: VisibilityInterval, to intervals: inout [VisibilityInterval]) {
        guard interval.end > interval.start else { return }
        if let last = intervals.last,
           last.state == interval.state,
           abs(last.end - interval.start) < 0.000_001 {
            intervals[intervals.count - 1] = VisibilityInterval(
                start: last.start, end: interval.end, state: last.state
            )
        } else {
            intervals.append(interval)
        }
    }
}
