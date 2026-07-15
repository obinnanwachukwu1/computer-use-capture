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
