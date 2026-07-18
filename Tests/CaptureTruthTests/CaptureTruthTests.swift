import Foundation
import Testing
@testable import CaptureTruth

private func sample(
    _ time: Double,
    _ status: CapturedFrameStatus,
    dirty: [CaptureDamageRect] = [],
    disposition: FrameWriterDisposition? = nil,
    pixels: CapturedPixelComparison? = nil
) -> CapturedFrameSample {
    CapturedFrameSample(
        sourceTime: time,
        status: status,
        dirtyRects: dirty,
        writerDisposition: disposition ?? (status == .complete ? .appended : .notApplicable),
        pixelComparison: pixels
    )
}

private func ledger(
    _ samples: [CapturedFrameSample],
    integrity: CaptureIntegrity = CaptureIntegrity()
) -> CaptureFrameLedger {
    CaptureFrameLedger(expectedFrameInterval: 1 / 60, samples: samples, integrity: integrity)
}

private let scroll = FactualActionWindow(
    id: 4, actionID: "scroll-4", kind: "scroll", start: 0.10, end: 0.20
)

private func geometry(
    bufferWidth: Int = 1200,
    bufferHeight: Int = 800,
    content: CaptureFrameRect? = CaptureFrameRect(x: 0, y: 0, width: 1200, height: 800),
    bounds: CaptureFrameRect? = CaptureFrameRect(x: 100, y: 80, width: 600, height: 400),
    scaleFactor: Double? = 2,
    contentScale: Double? = 1
) -> CaptureFrameGeometry {
    CaptureFrameGeometry(
        bufferWidth: bufferWidth,
        bufferHeight: bufferHeight,
        contentRect: content,
        boundingRect: bounds,
        scaleFactor: scaleFactor,
        contentScale: contentScale
    )
}

@Test func captureGeometryMonitorUsesFirstFrameAsAnImmutableBaseline() {
    var monitor = CaptureGeometryMonitor()
    #expect(monitor.inspect(geometry()).isEmpty)
    #expect(monitor.inspect(geometry()).isEmpty)

    let shrunk = geometry(
        content: CaptureFrameRect(x: 34, y: 0, width: 1132, height: 754),
        contentScale: 0.944
    )
    let discontinuities = monitor.inspect(shrunk)
    let kinds = Set(discontinuities.map(\.kind))
    #expect(kinds.contains(.contentRectX))
    #expect(kinds.contains(.contentRectWidth))
    #expect(kinds.contains(.contentRectHeight))
    #expect(kinds.contains(.contentScale))
    #expect(kinds.contains(.effectivePixelsPerPointX))
    #expect(kinds.contains(.effectivePixelsPerPointY))

    // Persistent drift remains visible instead of silently becoming the new normal.
    #expect(Set(monitor.inspect(shrunk).map(\.kind)) == kinds)
    #expect(monitor.inspect(geometry()).isEmpty)
}

@Test func subpixelGeometryJitterDoesNotCreateAQualityDiscontinuity() {
    var monitor = CaptureGeometryMonitor(baseline: geometry())
    let jittered = geometry(
        content: CaptureFrameRect(x: 0.4, y: 0.4, width: 1200.4, height: 799.6),
        bounds: CaptureFrameRect(x: 100, y: 80, width: 600.2, height: 399.8),
        scaleFactor: 2.0005,
        contentScale: 0.9995
    )
    #expect(monitor.inspect(jittered).isEmpty)
}

@Test func missingPreviouslyAvailableGeometryIsAReportedDiscontinuity() {
    var monitor = CaptureGeometryMonitor(baseline: geometry())
    let missing = geometry(content: nil, bounds: nil, scaleFactor: nil, contentScale: nil)
    let kinds = Set(monitor.inspect(missing).map(\.kind))
    #expect(kinds.contains(.contentRectUnavailable))
    #expect(kinds.contains(.boundingRectUnavailable))
    #expect(kinds.contains(.scaleFactorUnavailable))
    #expect(kinds.contains(.contentScaleUnavailable))
}

@Test func legacyCaptureLedgerRemainsDecodableAfterGeometryInstrumentation() throws {
    let legacy = Data("""
    {
      "version": 1,
      "sourceTimebase": "first-complete-frame-presentation-time",
      "expectedFrameInterval": 0.016666666666666666,
      "samples": [{
        "sourceTime": 0,
        "status": "complete",
        "dirtyRects": [],
        "writerDisposition": "appended",
        "pixelComparison": "unavailable"
      }],
      "integrity": {
        "invalidMetadataSamples": 0,
        "preRollSamples": 0,
        "droppedBackpressureFrames": 0,
        "droppedNonMonotonicFrames": 0,
        "appendFailedFrames": 0
      }
    }
    """.utf8)
    let decoded = try JSONDecoder().decode(CaptureFrameLedger.self, from: legacy)
    #expect(decoded.version == 1)
    #expect(decoded.samples[0].geometry == nil)
    #expect(decoded.geometryContract == nil)
}

@Test func geometryDiscontinuityCannotBeReducedAsWaiting() {
    let changedGeometry = CapturedFrameSample(
        sourceTime: 0.05,
        status: .complete,
        writerDisposition: .appended,
        pixelComparison: .identical,
        geometry: geometry(contentScale: 0.94),
        geometryDiscontinuities: [CaptureGeometryDiscontinuity(
            kind: .contentScale, baseline: 1, observed: 0.94
        )]
    )
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .complete, pixels: .unavailable), changedGeometry,
            sample(0.10, .complete, pixels: .identical)
        ]),
        sourceDuration: 0.10
    )
    #expect(analysis.intervals.contains { $0.state == .visibleChange })
}

@Test func consecutiveIdleSamplesProveAnEmptyAction() {
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .idle), sample(0.05, .idle), sample(0.10, .idle),
            sample(0.15, .idle), sample(0.20, .idle), sample(0.25, .idle)
        ]),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .provenIdle)
    #expect(analysis.provenIdleRanges == [0...0.25])
}

@Test func idleCallbacksBetweenIdenticalFramesFormOneWaitingEpisode() {
    let capture = ledger([
        sample(0, .complete, pixels: .unavailable),
        sample(0.016, .complete, pixels: .identical),
        sample(0.033, .idle),
        sample(0.050, .complete, pixels: .identical),
        sample(0.067, .idle),
        sample(0.084, .complete, pixels: .identical)
    ])
    let analysis = CaptureTruthAnalyzer.analyze(ledger: capture, sourceDuration: 0.084)
    #expect(analysis.provenIdleRanges == [0...0.084])
}

@Test func oneCompleteFrameMakesTheActionVisible() {
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .idle), sample(0.05, .idle), sample(0.10, .idle),
            sample(0.15, .complete, pixels: .changed), sample(0.20, .idle), sample(0.25, .idle)
        ]),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .visibleChange)
}

@Test func evenContradictoryOnePixelDamageIsVisible() {
    let damage = CaptureDamageRect(x: 12, y: 8, width: 1, height: 1)
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .idle), sample(0.05, .idle), sample(0.10, .idle),
            sample(0.15, .idle, dirty: [damage]), sample(0.20, .idle), sample(0.25, .idle)
        ]),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .visibleChange)
}

@Test func exactRawPixelIdentityCanProveIdleWhenScreenCaptureKitAlwaysSaysComplete() {
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .complete, pixels: .unavailable),
            sample(0.05, .complete, pixels: .identical),
            sample(0.10, .complete, pixels: .identical),
            sample(0.15, .complete, pixels: .identical),
            sample(0.20, .complete, pixels: .identical),
            sample(0.25, .complete, pixels: .identical)
        ]),
        sourceDuration: 0.25,
        actions: [FactualActionWindow(
            id: 5, actionID: "scroll-5", kind: "scroll", start: 0.05, end: 0.20
        )]
    )

    #expect(analysis.actionStates[5] == .provenIdle)
}

@Test func finalEncodedFrameDurationInheritsExactIdentityWithinOneCadenceWindow() {
    let finalAction = FactualActionWindow(
        id: 6, actionID: "scroll-6", kind: "scroll", start: 0.05, end: 0.27
    )
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .complete, pixels: .unavailable),
            sample(0.05, .complete, pixels: .identical),
            sample(0.10, .complete, pixels: .identical),
            sample(0.15, .complete, pixels: .identical),
            sample(0.20, .complete, pixels: .identical),
            sample(0.25, .complete, pixels: .identical)
        ]),
        sourceDuration: 0.27,
        actions: [finalAction]
    )

    #expect(analysis.actionStates[6] == .provenIdle)
}

@Test func deliveryGapCannotBeCalledIdle() {
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger([
            sample(0, .idle), sample(0.05, .idle), sample(0.10, .idle),
            sample(0.20, .idle), sample(0.25, .idle)
        ]),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .unknown)
}

@Test func droppedFrameCannotBeCalledIdle() {
    let dropped = sample(0.15, .complete, disposition: .droppedBackpressure)
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger(
            [sample(0.10, .idle), dropped, sample(0.20, .idle)],
            integrity: CaptureIntegrity(droppedBackpressureFrames: 1)
        ),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .unknown)
}

@Test func missingMetadataInvalidatesAbsenceProofGlobally() {
    let analysis = CaptureTruthAnalyzer.analyze(
        ledger: ledger(
            [sample(0, .idle), sample(0.05, .idle), sample(0.10, .idle),
             sample(0.15, .idle), sample(0.20, .idle), sample(0.25, .idle)],
            integrity: CaptureIntegrity(invalidMetadataSamples: 1)
        ),
        sourceDuration: 0.25,
        actions: [scroll]
    )

    #expect(analysis.actionStates[4] == .unknown)
    #expect(analysis.provenIdleRanges.isEmpty)
}

@Test func suspendedAndBlankCaptureRemainUnknown() {
    for status in [CapturedFrameStatus.suspended, .blank] {
        let analysis = CaptureTruthAnalyzer.analyze(
            ledger: ledger([
                sample(0.05, .idle), sample(0.10, .idle), sample(0.15, status),
                sample(0.20, .idle), sample(0.25, .idle)
            ]),
            sourceDuration: 0.25,
            actions: [scroll]
        )
        #expect(analysis.actionStates[4] == .unknown)
    }
}
