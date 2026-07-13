import Foundation

public struct InteractionActivitySample: Sendable {
    public let time: Double
    public let magnitude: Double

    public init(time: Double, magnitude: Double) {
        self.time = time
        self.magnitude = magnitude
    }
}

public struct InteractionPhases: Sendable {
    public let rawEstimate: Double
    public let toolStart: Double
    public let toolEnd: Double
    public let pointerArrival: Double
    public let activation: Double
    public let preActivationActivityEnd: Double?
    public let responseOnset: Double?
    public let source: String
    public let activityThreshold: Double?

    public init(
        rawEstimate: Double,
        toolStart: Double,
        toolEnd: Double,
        pointerArrival: Double,
        activation: Double,
        responseOnset: Double?,
        source: String,
        activityThreshold: Double? = nil,
        preActivationActivityEnd: Double? = nil
    ) {
        self.rawEstimate = rawEstimate
        self.toolStart = toolStart
        self.toolEnd = toolEnd
        self.pointerArrival = pointerArrival
        self.activation = activation
        self.preActivationActivityEnd = preActivationActivityEnd
        self.responseOnset = responseOnset
        self.source = source
        self.activityThreshold = activityThreshold
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
        let candidate = clusters
            .filter { activationWindow.contains($0.start) }
            .min { abs($0.start - toolEnd) < abs($1.start - toolEnd) }

        let activation: Double
        let source: String
        if let candidate {
            activation = candidate.start
            source = "target-visual"
        } else if finalActionInToolCall {
            activation = toolEnd
            source = "tool-completion"
        } else {
            activation = rawEstimate
            source = "telemetry-estimate"
        }

        let hover = clusters
            .filter { $0.start < activation - 0.10 && $0.start >= toolStart - 0.05 }
            .last
        let pointerArrival = min(activation, hover?.start ?? rawEstimate)
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
            preActivationActivityEnd: hover?.end
        )
    }

    private struct Cluster {
        let start: Double
        let end: Double
        let peak: Double
        let count: Int
    }

    private static func activityClusters(
        _ samples: [InteractionActivitySample],
        threshold: Double
    ) -> [Cluster] {
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
            return Cluster(
                start: values.first!.time,
                end: values.last!.time,
                peak: peak,
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
