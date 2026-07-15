import Foundation
import CoreGraphics

public enum InteractionTimingTarget {
    /// Resolves the region whose pixels are allowed to establish factual
    /// interaction timing. Accessibility containers can cover most of a
    /// native window; treating those as a local target allows unrelated edits
    /// to move the click. Prefer a precise semantic control, otherwise use the
    /// logged point as a small app-independent timing aperture.
    public static func resolve(
        semanticBounds: CGRect?,
        normalizedPoint: CGPoint?,
        pointAperture: CGFloat = 0.08
    ) -> CGRect? {
        let viewport = CGRect(x: 0, y: 0, width: 1, height: 1)
        let semantic = semanticBounds?.standardized.intersection(viewport)
        let semanticIsLocal = semantic.map {
            !$0.isNull && $0.width > 0 && $0.height > 0
                && $0.width <= 0.55 && $0.height <= 0.55
                && $0.width * $0.height <= 0.18
        } ?? false
        if semanticIsLocal { return semantic }

        if let point = normalizedPoint,
           point.x.isFinite, point.y.isFinite,
           viewport.insetBy(dx: -0.001, dy: -0.001).contains(point) {
            let half = pointAperture / 2
            return CGRect(
                x: point.x - half, y: point.y - half,
                width: pointAperture, height: pointAperture
            ).intersection(viewport)
        }
        if let semantic, !semantic.isNull, semantic.width > 0, semantic.height > 0 {
            return semantic
        }
        return nil
    }
}

public struct InteractionActivitySample: Sendable {
    public let time: Double
    public let magnitude: Double

    public init(time: Double, magnitude: Double) {
        self.time = time
        self.magnitude = magnitude
    }
}

public struct InteractionActivityCluster: Sendable, Codable {
    public let start: Double
    public let end: Double
    public let peak: Double
    public let peakTime: Double
    public let count: Int
}

public struct InteractionPhases: Sendable, Codable {
    public let rawEstimate: Double
    public let toolStart: Double
    public let toolEnd: Double
    public let pointerArrival: Double
    public let pointerArrivalSource: String
    public let activation: Double
    /// The last target-local activity cluster before the cluster identified as
    /// pointer arrival. For an action whose target entered the viewport, this
    /// is the causal fence after which pointer travel may begin. It is kept
    /// separate from `preActivationActivityEnd`, which is the hover/arrival
    /// cluster itself and therefore must never delay the cursor until after
    /// its own observed arrival.
    public let prePointerActivityEnd: Double?
    public let preActivationActivityEnd: Double?
    public let responseOnset: Double?
    public let source: String
    public let activityThreshold: Double?
    public let activityClusters: [InteractionActivityCluster]

    public init(
        rawEstimate: Double,
        toolStart: Double,
        toolEnd: Double,
        pointerArrival: Double,
        activation: Double,
        responseOnset: Double?,
        source: String,
        activityThreshold: Double? = nil,
        prePointerActivityEnd: Double? = nil,
        preActivationActivityEnd: Double? = nil,
        pointerArrivalSource: String = "provided",
        activityClusters: [InteractionActivityCluster] = []
    ) {
        self.rawEstimate = rawEstimate
        self.toolStart = toolStart
        self.toolEnd = toolEnd
        self.pointerArrival = pointerArrival
        self.pointerArrivalSource = pointerArrivalSource
        self.activation = activation
        self.prePointerActivityEnd = prePointerActivityEnd
        self.preActivationActivityEnd = preActivationActivityEnd
        self.responseOnset = responseOnset
        self.source = source
        self.activityThreshold = activityThreshold
        self.activityClusters = activityClusters
    }
}

public enum InteractionPhaseDetector {
    public static func detect(
        samples: [InteractionActivitySample],
        rawEstimate: Double,
        toolStart: Double,
        toolEnd: Double,
        finalActionInToolCall: Bool
    ) -> InteractionPhases {
        let ordered = samples.sorted { $0.time < $1.time }
        let baseline = ordered.filter { $0.time < toolStart }.map(\.magnitude)
        let baselineMedian = median(baseline)
        let deviation = median(baseline.map { abs($0 - baselineMedian) })
        // The floor suppresses ordinary H.264 noise. The adaptive term keeps
        // the detector useful for recordings with a noisier source codec.
        let threshold = max(0.55, baselineMedian + max(0.25, deviation * 8))
        let active = ordered.filter { $0.time >= toolStart - 0.05 && $0.magnitude >= threshold }
        let clusters = activityClusters(active, threshold: threshold)

        let activationWindow = (toolStart - 0.05)...(toolEnd + 0.18)
        let rawSpanningCandidate = clusters
            .filter { $0.start <= rawEstimate + 0.03 && $0.end >= rawEstimate - 0.03 }
            .max { $0.peak < $1.peak }
        let candidate = rawSpanningCandidate ?? clusters
            .filter { activationWindow.contains($0.start) }
            .min { abs($0.start - toolEnd) < abs($1.start - toolEnd) }

        let activation: Double
        let source: String
        if let candidate {
            let decisivePeak = candidate.peak >= threshold * 4
            activation = rawSpanningCandidate != nil && decisivePeak
                ? candidate.peakTime
                : candidate.start
            source = rawSpanningCandidate == nil ? "target-visual" : "target-visual-raw-span"
        } else if finalActionInToolCall {
            activation = toolEnd
            source = "tool-completion"
        } else {
            activation = rawEstimate
            source = "telemetry-estimate"
        }

        let hover = clusters
            .filter { cluster in
                cluster.end < (candidate?.start ?? activation) - 0.03
                    && cluster.start >= toolStart - 0.05
            }
            .last
        let prePointerActivity = hover.flatMap { hover in
            clusters
                .filter { $0.end < hover.start - 0.03 && $0.start >= toolStart - 0.05 }
                .last
        }
        let pointerArrival: Double
        let pointerArrivalSource: String
        if let hover {
            pointerArrival = min(activation, hover.start)
            pointerArrivalSource = "target-visual-hover"
        } else if let candidate = rawSpanningCandidate, candidate.start < activation - 0.03 {
            pointerArrival = candidate.start
            pointerArrivalSource = "activation-cluster-onset"
        } else if source.hasPrefix("target-visual") {
            // A native control often has no hover animation at all. In that
            // case the tool-call midpoint is not evidence of pointer arrival
            // and can park the cursor hundreds of milliseconds before the
            // measured click. Derive a short, tool-duration-proportional lead
            // from the actual visual activation instead.
            let lead = min(0.12, max(0.05, (toolEnd - toolStart) * 0.12))
            pointerArrival = max(toolStart, activation - lead)
            pointerArrivalSource = "activation-relative-fallback"
        } else {
            pointerArrival = min(activation, rawEstimate)
            pointerArrivalSource = "telemetry-estimate"
        }
        let response = clusters.first { $0.start >= activation + 0.10 }

        return InteractionPhases(
            rawEstimate: rawEstimate,
            toolStart: toolStart,
            toolEnd: toolEnd,
            pointerArrival: pointerArrival,
            activation: activation,
            responseOnset: response?.start,
            source: source,
            activityThreshold: threshold,
            prePointerActivityEnd: prePointerActivity?.end,
            preActivationActivityEnd: hover?.end,
            pointerArrivalSource: pointerArrivalSource,
            activityClusters: clusters
        )
    }

    private static func activityClusters(
        _ samples: [InteractionActivitySample],
        threshold: Double
    ) -> [InteractionActivityCluster] {
        var raw: [[InteractionActivitySample]] = []
        for sample in samples {
            if let previous = raw.last?.last, sample.time - previous.time <= 0.105 {
                raw[raw.count - 1].append(sample)
            } else {
                raw.append([sample])
            }
        }
        return raw.compactMap { values in
            let peak = values.map(\.magnitude).max() ?? 0
            // Require persistence unless the change is decisively above the
            // noise threshold; this rejects isolated compression artifacts.
            guard values.count >= 2 || peak >= threshold * 4 else { return nil }
            let peakSample = values.max { $0.magnitude < $1.magnitude }!
            return InteractionActivityCluster(
                start: values.first!.time,
                end: values.last!.time,
                peak: peak,
                peakTime: peakSample.time,
                count: values.count
            )
        }
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
