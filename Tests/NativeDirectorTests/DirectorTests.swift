import CoreGraphics
import Foundation
import Testing
@testable import NativeDirector

private let size = CGSize(width: 1000, height: 800)
private let rect = CGRect(origin: .zero, size: size)

private struct ScenarioSuite: Decodable {
    struct Scenario: Decodable {
        struct Motion: Decodable {
            let time: Double, x: Double, y: Double, width: Double, height: Double, changedFraction: Double
            let kind: VisualMotionKind
        }
        let name: String
        let duration: Double
        let events: [Timeline.Event]
        let motion: [Motion]
        let expectedEpisodes: Int
        let expectedEpisodeActions: Int
        let expectedShots: Int
    }
    let scenarios: [Scenario]
}

private func composition(
    _ events: String,
    duration: Double = 12,
    reduceWaiting: Bool = false,
    waitingTime: Double = 0.1,
    motion: [VisualMotionObservation] = [],
    interactionPhases: [Int: InteractionPhases] = [:],
    allowInferredTargets: Bool = false,
    verifiedIdleRanges: [ClosedRange<Double>]? = nil,
    provenIdleActionIDs: Set<Int> = []
) throws -> NativeComposition {
    let json = """
    {
      "composition": {"cursorScale": 3, "director": {"deadTimeRate": 6, "cursorCompression": 0.1, "zoomStrength": 1, "allowInferredTargets": \(allowInferredTargets)}},
      "events": \(events)
    }
    """
    return NativeComposition(
        timeline: try JSONDecoder().decode(Timeline.self, from: Data(json.utf8)),
        size: size,
        contentRect: rect,
        sourceDuration: duration,
        reduceWaiting: reduceWaiting,
        waitingTime: waitingTime,
        motionObservations: motion,
        interactionPhases: interactionPhases,
        verifiedIdleRanges: verifiedIdleRanges,
        provenIdleActionIDs: provenIdleActionIDs
    )
}

@Test func productDemoDefaultsWaitingMotionToTwoTimes() throws {
    let timeline = try JSONDecoder().decode(
        Timeline.self,
        from: Data("{\"composition\":{\"director\":{}},\"events\":[]}".utf8)
    )
    let directed = NativeComposition(
        timeline: timeline, size: size, contentRect: rect, sourceDuration: 4
    )
    #expect(directed.recipe.deadTimeRate == 2)
}

@Test func cinematicMotionUsesMinimumJerkEndpointEasing() {
    #expect(cinematicMotionProgress(-1) == 0)
    #expect(cinematicMotionProgress(0) == 0)
    #expect(abs(cinematicMotionProgress(0.5) - 0.5) < 0.000_001)
    #expect(cinematicMotionProgress(1) == 1)
    #expect(cinematicMotionProgress(2) == 1)

    let firstTenth = cinematicMotionProgress(0.1)
    let middleTenth = cinematicMotionProgress(0.55) - cinematicMotionProgress(0.45)
    let lastTenth = 1 - cinematicMotionProgress(0.9)
    #expect(firstTenth < middleTenth / 4)
    #expect(abs(firstTenth - lastTenth) < 0.000_001)
}

@Test func cinematicCameraReservesAVisibleSettlingPhase() {
    #expect(cinematicCameraProgress(-1) == 0)
    #expect(cinematicCameraProgress(0) == 0)
    #expect(cinematicCameraProgress(1) == 1)
    #expect(cinematicCameraProgress(2) == 1)

    // The camera covers ground earlier than the symmetric cursor curve, while
    // retaining eased motion through the final fifth of the move.
    #expect(cinematicCameraProgress(0.5) > cinematicMotionProgress(0.5) + 0.25)
    #expect(cinematicCameraProgress(0.8) < 0.99)
    #expect(cinematicCameraProgress(0.9) < 0.999)
}

@Test func largeCausalVisualResponseWidensPointerShot() throws {
    let events = """
    [{"action":"click","time":3,"coordinates":{"xNorm":0.82,"yNorm":0.2}}]
    """
    let pointerOnly = try composition(events)
    let responsive = try composition(events, motion: [
        VisualMotionObservation(
            time: 3.25,
            normalizedBounds: CGRect(x: 0.12, y: 0.15, width: 0.72, height: 0.55),
            changedFraction: 0.08,
            magnitude: 0.7
        )
    ])
    #expect(pointerOnly.actions[0].attention?.behavior == .point)
    #expect(responsive.actions[0].attention?.behavior == .wideResponse)
    #expect(responsive.shots[0].scale < pointerOnly.shots[0].scale)
    #expect(responsive.actions[0].attention!.bounds.contains(CGPoint(x: 820, y: 640)))
}

@Test func distributedContextTransitionPreservesViewportOverview() throws {
    let directed = try composition("""
    [{"action":"click","time":3,"coordinates":{"xNorm":0.12,"yNorm":0.62}}]
    """, motion: [
        VisualMotionObservation(
            time: 3.7,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.26,
            magnitude: 0.95,
            kind: .contextTransition
        )
    ])

    let action = try #require(directed.actions.first)
    #expect(action.attention?.behavior == .overview)
    #expect(action.attention?.evidence.contains { $0.source == .contextTransition } == true)
    let camera = try #require(directed.settledCamera(forActionID: action.id))
    #expect(abs(camera.x - size.width / 2) < 0.001)
    #expect(abs(camera.y - size.height / 2) < 0.001)
    #expect(abs(exp(camera.logScale) - 1) < 0.000_001)
}

@Test func overlappingWideResponsesShareOneTightShotPose() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.82,"yNorm":0.28}},
      {"action":"click","time":5,"coordinates":{"xNorm":0.76,"yNorm":0.28}}
    ]
    """, motion: [
        VisualMotionObservation(
            time: 3.7,
            normalizedBounds: CGRect(x: 0.12, y: 0.20, width: 0.74, height: 0.48),
            changedFraction: 0.14,
            magnitude: 0.9
        ),
        VisualMotionObservation(
            time: 5.7,
            normalizedBounds: CGRect(x: 0.15, y: 0.22, width: 0.68, height: 0.44),
            changedFraction: 0.12,
            magnitude: 0.85
        )
    ])
    #expect(directed.shots.count == 1)
    #expect(directed.actions.allSatisfy { $0.attention?.behavior == .wideResponse })
    let first = try #require(directed.settledCamera(forActionID: 0))
    let second = try #require(directed.settledCamera(forActionID: 1))
    #expect(abs(first.x - second.x) < 0.001)
    #expect(abs(first.y - second.y) < 0.001)
    #expect(abs(first.logScale - second.logScale) < 0.000_001)
    #expect(exp(first.logScale) > directed.shots[0].scale + 0.02)
}

@Test func tinyCaretMotionPreservesPointerFraming() throws {
    let directed = try composition("""
    [{"action":"click","time":3,"coordinates":{"xNorm":0.5,"yNorm":0.5}}]
    """, motion: [
        VisualMotionObservation(
            time: 3.2,
            normalizedBounds: CGRect(x: 0.49, y: 0.45, width: 0.006, height: 0.04),
            changedFraction: 0.0002,
            magnitude: 0.1
        )
    ])
    #expect(directed.actions[0].attention?.behavior == .point)
    #expect(directed.actions[0].attention?.evidence.count == 1)
}

@Test func translatedExistingContentDoesNotWidenPointerShot() throws {
    let directed = try composition("""
    [{"action":"click","time":3,"coordinates":{"xNorm":0.8,"yNorm":0.25}}]
    """, motion: [
        VisualMotionObservation(
            time: 3.7,
            normalizedBounds: CGRect(x: 0.1, y: 0.45, width: 0.8, height: 0.35),
            changedFraction: 0.2,
            magnitude: 1,
            kind: .translation
        )
    ])
    #expect(directed.actions[0].attention?.behavior == .point)
    #expect(directed.actions[0].attention?.evidence.count == 1)
}

@Test func offscreenSemanticTargetRelocationStartsANewEstablishingShot() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.76,"yNorm":0.48}},
      {"action":"click","time":4.3,"coordinates":{"xNorm":0.82,"yNorm":0.52},"semanticTarget":{"bounds":{"xNorm":0.79,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.05},"viewportRelocation":{"kind":"target-entered-viewport","displacementNorm":0.62,"fromVisibleFraction":0,"toVisibleFraction":1,"postActionOffsetMs":450}}}
    ]
    """, duration: 8)
    #expect(directed.shots.count == 2)
    #expect(directed.actions[1].requiresEstablishingTransition)
    #expect(abs(directed.actions[1].relocationSettleDelay - 0.45) < 0.001)
}

@Test func revealedRegionCreatesTwoLevelAttentionEpisode() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.75,"yNorm":0.25}},
      {"action":"type_text","time":8},
      {"action":"click","time":12,"coordinates":{"xNorm":0.68,"yNorm":0.55}},
      {"action":"click","time":16,"coordinates":{"xNorm":0.78,"yNorm":0.62}}
    ]
    """, duration: 20, motion: [
        VisualMotionObservation(time: 3.75, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.65, height: 0.55), changedFraction: 0.18, magnitude: 1, kind: .appearance)
    ])
    #expect(directed.shots.count == 1)
    #expect(directed.shots[0].actions.count == 4)
    #expect(Set(directed.actions.compactMap(\.episodeID)).count == 1)
    #expect(directed.actions[1].attention?.behavior == .region)
    let establishingScale = exp(try #require(directed.settledCamera(forActionID: 0)).logScale)
    let workingScale = exp(try #require(directed.settledCamera(forActionID: 1)).logScale)
    #expect(workingScale > establishingScale + 0.05)
}

@Test func trackedFocusHoldsCameraAcrossInternalScrollUntilDismissal() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.50,"yNorm":0.52}},
      {"action":"scroll","time":8},
      {"action":"click","time":12,"coordinates":{"xNorm":0.62,"yNorm":0.70}}
    ]
    """, duration: 16, motion: [
        VisualMotionObservation(
            time: 3.7,
            normalizedBounds: CGRect(x: 0.30, y: 0.25, width: 0.40, height: 0.50),
            changedFraction: 0.12,
            magnitude: 0.8,
            kind: .focus,
            focusTransition: .gained
        ),
        VisualMotionObservation(
            time: 12.7,
            normalizedBounds: CGRect(x: 0.30, y: 0.25, width: 0.40, height: 0.50),
            changedFraction: 0.12,
            magnitude: 0.8,
            kind: .focus,
            focusTransition: .released
        )
    ])
    let episodeIDs = directed.actions.map(\.episodeID)
    let scrollCamera = try #require(directed.settledCamera(forActionID: 1))

    #expect(episodeIDs.allSatisfy { $0 != nil && $0 == episodeIDs[0] })
    #expect(directed.shots.count == 1)
    #expect(directed.actions[1].attention?.behavior == .region)
    #expect(exp(scrollCamera.logScale) > 1.15)
}

@Test func distinctForegroundLifecyclesRemainDistinctShotsDespiteSpatialOverlap() throws {
    let focus = CGRect(x: 0.30, y: 0.25, width: 0.40, height: 0.50)
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.50,"yNorm":0.52}},
      {"action":"scroll","time":6},
      {"action":"click","time":8,"coordinates":{"xNorm":0.62,"yNorm":0.70}},
      {"action":"click","time":10,"coordinates":{"xNorm":0.51,"yNorm":0.53}},
      {"action":"scroll","time":13},
      {"action":"click","time":15,"coordinates":{"xNorm":0.63,"yNorm":0.71}}
    ]
    """, duration: 18, motion: [
        VisualMotionObservation(time: 3.7, normalizedBounds: focus, changedFraction: 0.12, magnitude: 0.8, kind: .focus, focusTransition: .gained),
        VisualMotionObservation(time: 8.7, normalizedBounds: focus, changedFraction: 0.12, magnitude: 0.8, kind: .focus, focusTransition: .released),
        VisualMotionObservation(time: 10.7, normalizedBounds: focus, changedFraction: 0.12, magnitude: 0.8, kind: .focus, focusTransition: .gained),
        VisualMotionObservation(time: 15.7, normalizedBounds: focus, changedFraction: 0.12, magnitude: 0.8, kind: .focus, focusTransition: .released)
    ])

    let firstLifecycle = Set(directed.actions.prefix(3).compactMap(\.episodeID))
    let secondLifecycle = Set(directed.actions.suffix(3).compactMap(\.episodeID))
    #expect(firstLifecycle.count == 1)
    #expect(secondLifecycle.count == 1)
    #expect(firstLifecycle != secondLifecycle)
    #expect(directed.shots.count == 2)
}

@Test func episodeGroupingPreservesPreciseModelTargets() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.75,"yNorm":0.25}},
      {"action":"type_text","time":8,"semanticTarget":{"bounds":{"xNorm":0.28,"yNorm":0.72,"widthNorm":0.38,"heightNorm":0.07}}},
      {"action":"click","time":12,"coordinates":{"xNorm":0.68,"yNorm":0.55}},
      {"action":"click","time":16,"coordinates":{"xNorm":0.78,"yNorm":0.62}}
    ]
    """, duration: 20, motion: [
        VisualMotionObservation(time: 3.75, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.65, height: 0.65), changedFraction: 0.18, magnitude: 1, kind: .appearance)
    ])
    let semantic = try #require(directed.actions[1].semanticBounds)
    let attention = try #require(directed.actions[1].attention)
    #expect(directed.actions[1].episodeID != nil)
    #expect(attention.bounds.midX == semantic.midX)
    #expect(attention.bounds.midY == semantic.midY)
    #expect(attention.bounds.width < size.width * 0.5)
}

@Test func scatteredActionsDoNotCreateAttentionEpisode() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.7,"yNorm":0.2}},
      {"action":"click","time":8,"coordinates":{"xNorm":0.05,"yNorm":0.9}},
      {"action":"click","time":12,"coordinates":{"xNorm":0.95,"yNorm":0.9}}
    ]
    """, duration: 16, motion: [
        VisualMotionObservation(time: 3.75, normalizedBounds: CGRect(x: 0.45, y: 0.1, width: 0.45, height: 0.45), changedFraction: 0.12, magnitude: 1, kind: .appearance)
    ])
    #expect(directed.actions.allSatisfy { $0.episodeID == nil })
}

@Test func deterministicDirectorScenarioContracts() throws {
    let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/DirectorScenarios/scenarios.json")
    let suite = try JSONDecoder().decode(ScenarioSuite.self, from: Data(contentsOf: fixtures))
    #expect(suite.scenarios.count >= 6)
    for scenario in suite.scenarios {
        let timelineData = try JSONEncoder().encode(TimelineFixture(events: scenario.events))
        let timeline = try JSONDecoder().decode(Timeline.self, from: timelineData)
        let directed = NativeComposition(
            timeline: timeline,
            size: size,
            contentRect: rect,
            sourceDuration: scenario.duration,
            motionObservations: scenario.motion.map {
                VisualMotionObservation(
                    time: $0.time,
                    normalizedBounds: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height),
                    changedFraction: $0.changedFraction,
                    magnitude: 1,
                    kind: $0.kind
                )
            }
        )
        let episodeIDs = Set(directed.actions.compactMap(\.episodeID))
        #expect(episodeIDs.count == scenario.expectedEpisodes, "\(scenario.name): episode count")
        #expect(directed.actions.filter { $0.episodeID != nil }.count == scenario.expectedEpisodeActions, "\(scenario.name): episode members")
        #expect(directed.shots.count == scenario.expectedShots, "\(scenario.name): shot count")
    }
}

private struct TimelineFixture: Encodable {
    let events: [Timeline.Event]
}

@Test func scrollMotionDoesNotInventAttentionTarget() throws {
    let directed = try composition("""
    [{"action":"scroll","time":3,"timing":{"toolCallDurationMs":700}}]
    """, motion: [
        VisualMotionObservation(time: 3.2, normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1), changedFraction: 0.7, magnitude: 1)
    ])
    #expect(directed.actions[0].attention == nil)
    #expect(directed.shots.isEmpty)
}

@Test func systemUIOcclusionIsEvidenceFreeForPointerAndMotion() throws {
    let timeline = try JSONDecoder().decode(Timeline.self, from: Data("""
    {
      "occlusionSpans": [{"startTime": 2.5, "endTime": 3.1}],
      "events": [{"actionId":"act_0123456789abcdef","action":"click","time":3,"coordinates":{"xNorm":0.8,"yNorm":0.2},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    }
    """.utf8))
    let directed = NativeComposition(
        timeline: timeline,
        size: size,
        contentRect: rect,
        sourceDuration: 8,
        motionObservations: [
            VisualMotionObservation(
                time: 3.3,
                normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.7),
                changedFraction: 0.4,
                magnitude: 1,
                kind: .appearance
            )
        ]
    )
    #expect(directed.actions[0].rendersCursor == false)
    #expect(directed.actions[0].attention == nil)
    #expect(directed.shots.isEmpty)
}

@Test func semanticBoundsAreFirstClassAttentionEvidence() throws {
    let directed = try composition("""
    [{"action":"type_text","time":4,"semanticTarget":{"bounds":{"xNorm":0.2,"yNorm":0.25,"widthNorm":0.4,"heightNorm":0.08}}}]
    """)
    #expect(directed.actions[0].attention?.behavior == .region)
    #expect(directed.actions[0].attention?.evidence.contains { $0.source == .accessibility } == true)
}

@Test func detectedMotionIsSpedUpInsteadOfCut() throws {
    let timeline = try JSONDecoder().decode(Timeline.self, from: Data("{\"events\":[]}".utf8))
    let directed = NativeComposition(
        timeline: timeline,
        size: size,
        contentRect: rect,
        sourceDuration: 10,
        reduceWaiting: true,
        waitingTime: 0.1,
        motionRanges: [3...7]
    )
    #expect(directed.retime.contains { $0.sourceStart <= 3 && $0.sourceEnd >= 7 && $0.rate == 2 })
}

@Test func localizedMotionAndPeriodicBlinkingAreDetected() {
    let still = [UInt8](repeating: 100, count: 100 * 4)
    var changed = still
    for pixel in 0..<4 { changed[pixel * 4] = 180 }
    #expect(MotionDetection.hasMotion(
        previous: still,
        current: changed,
        channelThreshold: 20,
        changedPixelFraction: 0.02
    ))
    #expect(!MotionDetection.hasMotion(
        previous: still,
        current: still,
        channelThreshold: 20,
        changedPixelFraction: 0.02
    ))
    let blinkRanges = MotionDetection.ranges(forMotionTimes: [2.0, 2.5, 3.0, 3.5])
    #expect(blinkRanges.count == 1)
    #expect(blinkRanges[0].lowerBound < 2)
    #expect(blinkRanges[0].upperBound > 3.5)
}

@Test func periodicCaretInsideKnownTextInputIsEditoriallyIncidental() {
    let input = TextInputEvidence(
        time: 1.2,
        normalizedBounds: CGRect(x: 0.2, y: 0.3, width: 0.45, height: 0.10),
        validFrom: 1.0
    )
    let samples = [1.0, 1.5, 2.0, 2.5, 3.0].map { time in
        TimedMotionSample(time: time, components: [DetectedMotionComponent(
            normalizedBounds: CGRect(x: 0.42, y: 0.32, width: 0.006, height: 0.05),
            changedFraction: 0.0002,
            magnitude: 0.8,
            kind: .appearance
        )])
    }

    let ranges = CaretBlinkDetection.ranges(samples: samples, textInputs: [input])
    #expect(ranges.count == 1)
    #expect(ranges[0].lowerBound == 1.0)
    #expect(ranges[0].upperBound == 3.0)
}

@Test func smallPeriodicSpinnerRemainsApplicationMotion() {
    let input = TextInputEvidence(
        time: 1.2,
        normalizedBounds: CGRect(x: 0.2, y: 0.3, width: 0.45, height: 0.10),
        validFrom: 1.0
    )
    let samples = [1.0, 1.5, 2.0, 2.5, 3.0].map { time in
        TimedMotionSample(time: time, components: [DetectedMotionComponent(
            normalizedBounds: CGRect(x: 0.42, y: 0.33, width: 0.03, height: 0.03),
            changedFraction: 0.0004,
            magnitude: 0.8,
            kind: .transformation
        )])
    }

    #expect(CaretBlinkDetection.ranges(samples: samples, textInputs: [input]).isEmpty)
}

@Test func caretShapeWithoutTextEvidenceOrStableCadenceIsNotRemoved() {
    let bounds = CGRect(x: 0.42, y: 0.32, width: 0.006, height: 0.05)
    let component = DetectedMotionComponent(
        normalizedBounds: bounds,
        changedFraction: 0.0002,
        magnitude: 0.8,
        kind: .appearance
    )
    let irregular = [1.0, 1.31, 1.92, 2.29, 3.0].map {
        TimedMotionSample(time: $0, components: [component])
    }
    let input = TextInputEvidence(
        time: 1.2,
        normalizedBounds: CGRect(x: 0.2, y: 0.3, width: 0.45, height: 0.10),
        validFrom: 1.0
    )

    #expect(CaretBlinkDetection.ranges(samples: irregular, textInputs: [input]).isEmpty)
    #expect(CaretBlinkDetection.ranges(samples: irregular, textInputs: []).isEmpty)
}

@Test func nonCaretChangeSplitsCaretProofWithoutBeingSwallowedByHandles() {
    let input = TextInputEvidence(
        time: 1.2,
        normalizedBounds: CGRect(x: 0.2, y: 0.3, width: 0.45, height: 0.10),
        validFrom: 1.0
    )
    let caret = DetectedMotionComponent(
        normalizedBounds: CGRect(x: 0.42, y: 0.32, width: 0.006, height: 0.05),
        changedFraction: 0.0002,
        magnitude: 0.8,
        kind: .appearance
    )
    let applicationChange = DetectedMotionComponent(
        normalizedBounds: CGRect(x: 0.72, y: 0.15, width: 0.08, height: 0.08),
        changedFraction: 0.004,
        magnitude: 0.8,
        kind: .transformation
    )
    var samples = [1.0, 1.5, 2.0, 2.5].map {
        TimedMotionSample(time: $0, components: [caret])
    }
    samples.append(TimedMotionSample(time: 2.7, components: [applicationChange]))
    samples += [3.0, 3.5, 4.0, 4.5].map {
        TimedMotionSample(time: $0, components: [caret])
    }

    let ranges = CaretBlinkDetection.ranges(samples: samples, textInputs: [input])
    #expect(ranges == [1.0...2.5, 3.0...4.5])
    #expect(!ranges.contains { $0.contains(2.7) })
}

@Test func periodicCaretShapeCannotReuseExpiredTextInputEvidence() {
    let input = TextInputEvidence(
        time: 1.0,
        normalizedBounds: CGRect(x: 0.2, y: 0.3, width: 0.45, height: 0.10),
        validFrom: 1.0,
        validThrough: 3.0
    )
    let component = DetectedMotionComponent(
        normalizedBounds: CGRect(x: 0.42, y: 0.32, width: 0.006, height: 0.05),
        changedFraction: 0.0002,
        magnitude: 0.8,
        kind: .appearance
    )
    let samples = [4.0, 4.5, 5.0, 5.5, 6.0].map {
        TimedMotionSample(time: $0, components: [component])
    }

    #expect(CaretBlinkDetection.ranges(samples: samples, textInputs: [input]).isEmpty)
}

@Test func globalRetimeCutsProvenCaretBlinkButPreservesGenericSpinner() {
    let caret = GlobalRetimePlanner.plan(
        actions: [],
        sourceDuration: 10,
        motionRanges: [2...8],
        caretBlinkRanges: [2...8],
        verifiedIdleRanges: [],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 2
    )
    let spinner = GlobalRetimePlanner.plan(
        actions: [],
        sourceDuration: 10,
        motionRanges: [2...8],
        verifiedIdleRanges: [],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 2
    )

    #expect(!caret.contains { $0.sourceStart < 5 && $0.sourceEnd > 5 })
    #expect(spinner.contains { $0.sourceStart <= 2 && $0.sourceEnd >= 8 && $0.rate == 2 })
}

@Test func factualActionStillOutranksCaretAndBroadResponseProtectionDoesNot() throws {
    let directed = try composition(
        "[{\"action\":\"click\",\"time\":5.0,\"coordinates\":{\"xNorm\":0.5,\"yNorm\":0.5},\"targetResolution\":{\"provenance\":\"direct\",\"confidence\":0.99}}]",
        duration: 10
    )
    let retime = GlobalRetimePlanner.plan(
        actions: directed.actions,
        sourceDuration: 10,
        motionRanges: [2...8],
        caretBlinkRanges: [2...8],
        protectedResponseRanges: [2...8],
        verifiedIdleRanges: [],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 2
    )

    #expect(retime.contains { $0.sourceStart <= 5 && $0.sourceEnd >= 5 && $0.rate == 1 })
    #expect(!retime.contains { $0.sourceStart < 3 && $0.sourceEnd > 3 })
}

@Test func spatialMotionSeparatesTranslationFromAppearance() {
    let width = 80, height = 60
    var before = [UInt8](repeating: 245, count: width * height * 4)
    var after = before
    func paint(_ pixels: inout [UInt8], x: Int, y: Int, width boxWidth: Int, height boxHeight: Int, value: UInt8) {
        for py in y..<(y + boxHeight) { for px in x..<(x + boxWidth) {
            let offset = (py * width + px) * 4
            pixels[offset] = value; pixels[offset + 1] = value; pixels[offset + 2] = value
        }}
    }
    paint(&before, x: 12, y: 30, width: 24, height: 10, value: 40)
    paint(&after, x: 12, y: 30, width: 24, height: 10, value: 245)
    paint(&after, x: 12, y: 40, width: 24, height: 10, value: 40)
    paint(&after, x: 48, y: 10, width: 18, height: 12, value: 80)
    let components = SpatialMotion.components(previous: before, current: after, width: width, height: height, tileSize: 4)
    #expect(components.contains { $0.kind == .translation })
    #expect(components.contains { $0.kind == .appearance })
}

@Test func motionFieldSeparatesGlobalPhotometryFromLocalizedStructure() throws {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = before
    applyAffineLuminance(to: &after, gain: 0.62, offset: 4)
    paintRGBA(&after, imageWidth: width, x: 56, y: 38, width: 48, height: 42, value: 238)
    paintRGBA(&after, imageWidth: width, x: 65, y: 48, width: 30, height: 4, value: 32)

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height
    )

    let context = try #require(field.backdrop)
    #expect(context.coveredFraction > 0.45)
    #expect(context.direction == .focusGained)
    let subject = try #require(field.structural.max { $0.changedFraction < $1.changedFraction })
    let expected = CGRect(x: 56.0 / 160, y: 38.0 / 120, width: 48.0 / 160, height: 42.0 / 120)
    #expect(rectArea(subject.normalizedBounds.intersection(expected)) / rectArea(expected) > 0.75)
    #expect(rectArea(subject.normalizedBounds) < 0.20)
}

@Test func motionFieldPreservesSeparatedStructuralSubjects() {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = before
    paintRGBA(&after, imageWidth: width, x: 12, y: 18, width: 24, height: 20, value: 245)
    paintRGBA(&after, imageWidth: width, x: 118, y: 78, width: 28, height: 22, value: 20)

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height
    )
    #expect(field.denseEvidence == nil)
    let material = field.structural.filter { $0.changedFraction > 0.01 }
    #expect(material.count == 2)
    #expect(material.allSatisfy { rectArea($0.normalizedBounds) < 0.10 })
}

@Test func motionFieldDenseEvidencePreservesPixelsBeforeObjectGrouping() throws {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = before
    paintRGBA(&after, imageWidth: width, x: 12, y: 18, width: 24, height: 20, value: 245)
    paintRGBA(&after, imageWidth: width, x: 118, y: 78, width: 28, height: 22, value: 20)

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height,
        configuration: MotionFieldConfiguration(tileSize: 4, retainDenseEvidence: true)
    )
    let evidence = try #require(field.denseEvidence)
    #expect(evidence.rawDelta.count == width * height)
    #expect(evidence.tiles.count == evidence.tileColumns * evidence.tileRows)

    for pixel in 0..<(width * height) {
        let offset = pixel * 4
        let red = abs(Int(after[offset]) - Int(before[offset]))
        let green = abs(Int(after[offset + 1]) - Int(before[offset + 1]))
        let blue = abs(Int(after[offset + 2]) - Int(before[offset + 2]))
        let expected = UInt8(max(red, max(green, blue)))
        #expect(evidence.rawDelta[pixel] == expected)
    }

    let structural = evidence.tiles.filter { $0.channel == .structural }
    #expect(structural.contains { $0.normalizedBounds.maxX < 0.30 })
    #expect(structural.contains { $0.normalizedBounds.minX > 0.65 })
    #expect(!structural.contains { $0.normalizedBounds.midX > 0.35 && $0.normalizedBounds.midX < 0.65 })
}

@Test func motionFieldDenseEvidenceKeepsBackdropAndForegroundSeparate() throws {
    let width = 180, height = 140
    let before = texturedFrame(width: width, height: height)
    var after = blurAndTransform(before, width: width, height: height, radius: 3, gain: 0.58, offset: 3)
    paintRGBA(&after, imageWidth: width, x: 52, y: 30, width: 78, height: 76, value: 224)
    paintRGBA(&after, imageWidth: width, x: 62, y: 46, width: 56, height: 5, value: 34)

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height,
        configuration: MotionFieldConfiguration(retainDenseEvidence: true)
    )
    let tiles = try #require(field.denseEvidence).tiles
    #expect(tiles.contains { $0.channel == .backdrop || $0.channel == .photometric })
    #expect(tiles.contains {
        $0.channel == .structural
            && $0.normalizedBounds.midX > 0.25 && $0.normalizedBounds.midX < 0.75
            && $0.normalizedBounds.midY > 0.15 && $0.normalizedBounds.midY < 0.85
    })
}

@Test func denseMotionTracksReconnectHeldObjectToLaterExitMotion() throws {
    let columns = 20, rows = 12
    let samples = [
        denseSample(time: 1.0, columns: columns, rows: rows, indices: [34, 35, 54, 55]),
        denseSample(time: 1.2, columns: columns, rows: rows, indices: [35, 36, 55, 56]),
        // The object is visually static for several seconds, so there is no
        // intervening change evidence. Its exit animation occupies the same
        // region and should extend the original lifecycle globally.
        denseSample(time: 5.4, columns: columns, rows: rows, indices: [34, 35, 54, 55]),
    ]
    let graph = DenseMotionTrackGraph.make(samples: samples)
    let lifecycle = try #require(graph.tracks.first { $0.componentIDs.count == 3 })
    #expect(lifecycle.startTime == 1.0)
    #expect(lifecycle.endTime == 5.4)
    #expect(lifecycle.maximumGap > 4.0)
    #expect(lifecycle.continuityConfidence > 0.45)
}

@Test func denseMotionTracksDoNotMergeRemoteConcurrentChanges() {
    let columns = 20, rows = 12
    let samples = [
        denseSample(time: 1.0, columns: columns, rows: rows, indices: [21, 22, 41, 42]),
        denseSample(time: 1.2, columns: columns, rows: rows, indices: [22, 23, 42, 43]),
        denseSample(time: 1.2, columns: columns, rows: rows, indices: [176, 177, 196, 197]),
        denseSample(time: 1.4, columns: columns, rows: rows, indices: [175, 176, 195, 196]),
    ]
    let graph = DenseMotionTrackGraph.make(samples: samples)
    let persistent = graph.tracks.filter { $0.componentIDs.count >= 2 }
    #expect(persistent.count == 2)
    #expect(persistent.contains { $0.normalizedBounds.maxX < 0.35 })
    #expect(persistent.contains { $0.normalizedBounds.minX > 0.65 })
}

@Test func denseMotionTracksAreDeterministicAndPreserveTileMasks() {
    let columns = 20, rows = 12
    let samples = [
        denseSample(time: 2.0, columns: columns, rows: rows, indices: [63, 64, 83, 84]),
        denseSample(time: 2.2, columns: columns, rows: rows, indices: [64, 65, 84, 85]),
        denseSample(time: 2.4, columns: columns, rows: rows, indices: [65, 66, 85, 86]),
    ]
    let first = DenseMotionTrackGraph.make(samples: samples)
    let second = DenseMotionTrackGraph.make(samples: samples.reversed())
    #expect(first.tracks.map(\.componentIDs) == second.tracks.map(\.componentIDs))
    #expect(first.components.flatMap(\.tileIndices).sorted() == samples.flatMap { $0.tiles.map(\.index) }.sorted())
}

@Test func denseMotionObjectsGroupSynchronizedDisconnectedToastPieces() throws {
    let columns = 40, rows = 24
    let samples = [1.0, 1.2, 4.8, 5.0].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [84, 85, 124, 125, 94, 95, 134, 135]
        )
    }
    let tracks = DenseMotionTrackGraph.make(samples: samples)
    #expect(tracks.tracks.count == 2)
    let objects = DenseMotionObjectGraph.make(tracks: tracks)
    let toast = try #require(objects.ensembles.first { $0.trackIDs.count == 2 })
    #expect(toast.kind == .compactObject)
    #expect(toast.lifecycleConfidence > 0.95)
}

@Test func denseMotionObjectsClassifySynchronizedRemoteChangesAsBroadContext() throws {
    let columns = 40, rows = 24
    let samples = [2.0, 2.2].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [41, 42, 81, 82, 878, 879, 918, 919]
        )
    }
    let tracks = DenseMotionTrackGraph.make(samples: samples)
    let objects = DenseMotionObjectGraph.make(tracks: tracks)
    let transition = try #require(objects.ensembles.first { $0.trackIDs.count == 2 })
    #expect(transition.kind == .broadContext)
    #expect(!objects.ensembles.contains { $0.kind == .compactObject })
}

@Test func denseMotionObjectsDoNotCallSparseSynchronizedFragmentsAnObject() throws {
    let columns = 40, rows = 24
    let samples = [2.0, 2.2].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [82, 83, 122, 123, 258, 259, 298, 299]
        )
    }
    let tracks = DenseMotionTrackGraph.make(samples: samples)
    let objects = DenseMotionObjectGraph.make(tracks: tracks)
    let event = try #require(objects.ensembles.first { $0.trackIDs.count == 2 })
    #expect(event.kind == .correlatedChange)
    #expect(event.spatialOccupancy < 0.25)
}

@Test func denseMotionObjectsDoNotMergeNestedAnimationWithContainingLifecycle() {
    let columns = 40, rows = 24
    let samples = [
        denseSample(time: 1.0, columns: columns, rows: rows, indices: [84, 85, 124, 125]),
        denseSample(time: 1.2, columns: columns, rows: rows, indices: [84, 85, 124, 125]),
        denseSample(time: 2.0, columns: columns, rows: rows, indices: [94, 95, 134, 135]),
        denseSample(time: 2.2, columns: columns, rows: rows, indices: [94, 95, 134, 135]),
        denseSample(time: 4.8, columns: columns, rows: rows, indices: [84, 85, 124, 125]),
        denseSample(time: 5.0, columns: columns, rows: rows, indices: [84, 85, 124, 125]),
    ]
    let tracks = DenseMotionTrackGraph.make(samples: samples)
    let objects = DenseMotionObjectGraph.make(tracks: tracks)
    #expect(objects.ensembles.allSatisfy { $0.trackIDs.count == 1 })
}

@Test func denseMotionObjectPartitionIsDeterministic() {
    let columns = 40, rows = 24
    let samples = [1.0, 1.2, 4.8, 5.0].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [84, 85, 124, 125, 94, 95, 134, 135]
        )
    }
    let firstTracks = DenseMotionTrackGraph.make(samples: samples)
    let secondTracks = DenseMotionTrackGraph.make(samples: samples.reversed())
    let first = DenseMotionObjectGraph.make(tracks: firstTracks)
    let second = DenseMotionObjectGraph.make(tracks: secondTracks)
    #expect(first.ensembles.map(\.trackIDs) == second.ensembles.map(\.trackIDs))
    #expect(firstTracks.components.flatMap(\.tileIndices).sorted()
        == secondTracks.components.flatMap(\.tileIndices).sorted())
}

@Test func denseMotionSurfaceUsesBothLifecycleBoundariesAndRejectsOneSidedChange() throws {
    let width = 80, height = 60, columns = 20, rows = 12
    let samples = [1.0, 1.2, 4.8, 5.0].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [105, 106, 125, 126]
        )
    }
    let tracks = DenseMotionTrackGraph.make(samples: samples)
    let objects = DenseMotionObjectGraph.make(tracks: tracks)
    let object = try #require(objects.ensembles.first { $0.kind == .compactObject })

    let before = solidRGBA(width: width, height: height, value: 20)
    var held = before
    var after = before
    paintRGBA(&held, imageWidth: width, x: 20, y: 14, width: 34, height: 20, value: 92)
    // This unrelated lower-right update exists only across the birth side.
    // A one-way diff would absorb it; the release-side intersection must not.
    paintRGBA(&held, imageWidth: width, x: 62, y: 44, width: 12, height: 10, value: 150)
    paintRGBA(&after, imageWidth: width, x: 62, y: 44, width: 12, height: 10, value: 150)
    let frames = [
        DenseMotionRasterFrame(time: 0.8, width: width, height: height, pixels: before),
        DenseMotionRasterFrame(time: 3.0, width: width, height: height, pixels: held),
        DenseMotionRasterFrame(time: 5.2, width: width, height: height, pixels: after),
    ]
    let surfaces = DenseMotionSurfaceGraph.make(
        tracks: tracks,
        objects: objects,
        frames: frames,
        tileColumns: columns,
        tileRows: rows
    )
    let surface = try #require(surfaces.surfaces.first { $0.objectID == object.id })
    #expect(abs(surface.normalizedBounds.minX - 0.25) < 0.03)
    #expect(abs(surface.normalizedBounds.minY - (14.0 / 60.0)) < 0.03)
    #expect(abs(surface.normalizedBounds.width - (34.0 / 80.0)) < 0.04)
    #expect(surface.normalizedBounds.maxX < 0.72)
    #expect(surface.confidence > 0.6)
}

@Test func denseMotionTransportRecoversLowContrastCardDespiteChangingLabel() throws {
    let width = 96, height = 64
    let frames = (0..<7).map { index -> DenseTransportFrame in
        var pixels = solidRGBA(width: width, height: height, value: 10)
        // A same-colored stationary lookalike must not be reported as moving.
        paintRGBA(&pixels, imageWidth: width, x: 4, y: 4, width: 20, height: 10, value: 22)
        let x = 12 + index * 4
        paintRGBA(&pixels, imageWidth: width, x: x, y: 22, width: 26, height: 28, value: 22)
        // Interior content mutates while the enclosing low-contrast surface
        // translates. Transport must treat this as an outlier, not identity.
        paintRGBA(
            &pixels,
            imageWidth: width,
            x: x + 10 + index % 3,
            y: 32,
            width: 4,
            height: 7,
            value: 238
        )
        return DenseTransportFrame(
            time: Double(index) / 24,
            width: width,
            height: height,
            pixels: pixels
        )
    }
    let graph = DenseMotionTransportGraph.make(frames: frames)
    let track = try #require(graph.tracks.max { $0.normalizedTravel < $1.normalizedTravel })
    #expect(track.dominantAxis == .horizontal)
    #expect(track.componentIDs.count == frames.count)
    #expect(track.directionalCoherence > 0.95)
    #expect(track.confidence > 0.75)
    let byID = Dictionary(uniqueKeysWithValues: graph.components.map { ($0.id, $0) })
    let samples = track.componentIDs.compactMap { byID[$0] }
    #expect(samples.allSatisfy { abs($0.normalizedBounds.width - 26.0 / 96.0) < 0.03 })
    #expect(zip(samples, samples.dropFirst()).allSatisfy {
        $1.normalizedBounds.midX > $0.normalizedBounds.midX
    })
}

@Test func denseMotionTransportRejectsStationaryAppearanceSurface() {
    let width = 80, height = 60
    let frames = (0..<6).map { index -> DenseTransportFrame in
        var pixels = solidRGBA(width: width, height: height, value: 10)
        paintRGBA(&pixels, imageWidth: width, x: 20, y: 16, width: 30, height: 24, value: 22)
        return DenseTransportFrame(
            time: Double(index) / 24,
            width: width,
            height: height,
            pixels: pixels
        )
    }
    #expect(DenseMotionTransportGraph.make(frames: frames).tracks.isEmpty)
}

@Test func denseMotionTransportIsDeterministicUnderInputOrdering() {
    let width = 80, height = 60
    let frames = (0..<6).map { index -> DenseTransportFrame in
        var pixels = solidRGBA(width: width, height: height, value: 10)
        paintRGBA(&pixels, imageWidth: width, x: 8 + index * 4, y: 18, width: 24, height: 22, value: 22)
        return DenseTransportFrame(
            time: Double(index) / 24,
            width: width,
            height: height,
            pixels: pixels
        )
    }
    let first = DenseMotionTransportGraph.make(frames: frames)
    let second = DenseMotionTransportGraph.make(frames: frames.reversed())
    #expect(first.tracks.map(\.componentIDs) == second.tracks.map(\.componentIDs))
    #expect(first.tracks.map(\.normalizedTravel) == second.tracks.map(\.normalizedTravel))
}

@Test func foregroundOwnershipPreservesProvenanceAndAbstainsFromUnrelatedMotion() throws {
    let columns = 40, rows = 24
    let samples = [1.0, 1.2, 4.8, 5.0].map { time in
        denseSample(
            time: time,
            columns: columns,
            rows: rows,
            indices: [84, 85, 124, 125, 670, 671, 710, 711]
        )
    }
    let motion = DenseMotionTrackGraph.make(samples: samples)
    let owned = try #require(motion.tracks.first { $0.normalizedBounds.minX < 0.2 })
    let unrelated = try #require(motion.tracks.first { $0.normalizedBounds.minX > 0.6 })
    let seed = ForegroundSupportSeed(
        id: 7,
        normalizedBounds: owned.normalizedBounds,
        tileIndices: owned.componentIDs.flatMap { id in
            motion.components.first { $0.id == id }?.tileIndices ?? []
        },
        birthTime: 1.0,
        heldTime: 3.0,
        releaseTime: 5.0,
        supportConfidence: 0.9,
        provenanceMotionTrackIDs: [owned.id]
    )
    let graph = DenseMotionOwnershipGraph.make(
        seeds: [seed],
        motion: motion,
        transport: DenseMotionTransportGraph.make(frames: [])
    )
    let direct = try #require(graph.motionAssignments.first { $0.trackID == owned.id })
    let rejected = try #require(graph.motionAssignments.first { $0.trackID == unrelated.id })
    #expect(direct.status == .provenance)
    #expect(direct.lifecycleID == seed.id)
    #expect(rejected.status == .unowned)
    #expect(rejected.lifecycleID == nil)
}

@Test func foregroundOwnershipAbstainsWhenTwoSupportsExplainTheSameEvidence() throws {
    let columns = 40, rows = 24
    let motion = DenseMotionTrackGraph.make(samples: [1.0, 1.2, 4.8, 5.0].map { time in
        denseSample(time: time, columns: columns, rows: rows, indices: [84, 85, 124, 125])
    })
    let track = try #require(motion.tracks.first)
    let tiles = track.componentIDs.flatMap { id in
        motion.components.first { $0.id == id }?.tileIndices ?? []
    }
    let seeds = [10, 11].map { id in
        ForegroundSupportSeed(
            id: id,
            normalizedBounds: track.normalizedBounds,
            tileIndices: tiles,
            birthTime: 1.0,
            heldTime: 3.0,
            releaseTime: 5.0,
            supportConfidence: 0.9,
            provenanceMotionTrackIDs: []
        )
    }
    let graph = DenseMotionOwnershipGraph.make(
        seeds: seeds,
        motion: motion,
        transport: DenseMotionTransportGraph.make(frames: [])
    )
    let assignment = try #require(graph.motionAssignments.first)
    #expect(assignment.status == .ambiguous)
    #expect(assignment.lifecycleID == nil)
    #expect(assignment.candidates.map(\.lifecycleID) == [10, 11])
}

@Test func foregroundOwnershipCanAssociateTransportWithoutRewritingLifecycleBirth() throws {
    let width = 96, height = 64
    let frames = (0..<8).map { index -> DenseTransportFrame in
        var pixels = solidRGBA(width: width, height: height, value: 10)
        paintRGBA(&pixels, imageWidth: width, x: 12 + index * 3, y: 22, width: 28, height: 24, value: 22)
        return DenseTransportFrame(
            time: 0.7 + Double(index) / 24,
            width: width,
            height: height,
            pixels: pixels
        )
    }
    let transport = DenseMotionTransportGraph.make(frames: frames)
    let track = try #require(transport.tracks.first)
    let seed = ForegroundSupportSeed(
        id: 4,
        normalizedBounds: CGRect(x: 0.24, y: 0.32, width: 0.42, height: 0.45),
        tileIndices: [],
        birthTime: 1.0,
        heldTime: 2.0,
        releaseTime: 4.0,
        supportConfidence: 0.85,
        provenanceMotionTrackIDs: []
    )
    let graph = DenseMotionOwnershipGraph.make(
        seeds: [seed],
        motion: DenseMotionTrackGraph.make(samples: []),
        transport: transport
    )
    let assignment = try #require(graph.transportAssignments.first { $0.trackID == track.id })
    #expect(assignment.status == .inferred)
    #expect(assignment.lifecycleID == seed.id)
    let lifecycle = try #require(graph.lifecycles.first)
    #expect(lifecycle.birthTime == seed.birthTime)
    #expect(lifecycle.supportingEvidenceStart < lifecycle.birthTime)
}

private func solidRGBA(width: Int, height: Int, value: UInt8) -> [UInt8] {
    var pixels = [UInt8](repeating: value, count: width * height * 4)
    for pixel in 0..<(width * height) { pixels[pixel * 4 + 3] = 255 }
    return pixels
}

private func denseSample(
    time: Double,
    columns: Int,
    rows: Int,
    indices: [Int],
    channel: MotionEvidenceChannel = .structural
) -> DenseMotionSample {
    DenseMotionSample(
        time: time,
        tileColumns: columns,
        tileRows: rows,
        tiles: indices.map { index in
            let x = index % columns, y = index / columns
            return MotionEvidenceTile(
                index: index,
                normalizedBounds: CGRect(
                    x: Double(x) / Double(columns),
                    y: Double(y) / Double(rows),
                    width: 1 / Double(columns),
                    height: 1 / Double(rows)
                ),
                channel: channel,
                changedFraction: 0.7,
                energy: 0.8,
                meanLuminanceDelta: 20,
                beforeDetail: 2,
                afterDetail: 12,
                confidence: 0.9,
                normalizedVector: .zero
            )
        }
    )
}

@Test func motionFieldIsSymmetricUnderFrameReversal() throws {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = before
    paintRGBA(&after, imageWidth: width, x: 48, y: 30, width: 58, height: 52, value: 232)
    paintRGBA(&after, imageWidth: width, x: 60, y: 44, width: 34, height: 5, value: 26)

    let forward = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    let reverse = SpatialMotion.motionField(previous: after, current: before, width: width, height: height)
    let appeared = try #require(forward.structural.max { $0.changedFraction < $1.changedFraction })
    let vanished = try #require(reverse.structural.max { $0.changedFraction < $1.changedFraction })
    let intersection = appeared.normalizedBounds.intersection(vanished.normalizedBounds)
    let union = appeared.normalizedBounds.union(vanished.normalizedBounds)
    #expect(rectArea(intersection) / rectArea(union) > 0.90)
    #expect(abs(appeared.changedFraction - vanished.changedFraction) < 0.000_001)
}

@Test func motionFieldExplainsCoherentViewportShiftWithoutOneStructuralBox() {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = [UInt8](repeating: 245, count: width * height * 4)
    for y in 0..<(height - 4) {
        for x in 0..<(width - 8) {
            let source = ((y + 4) * width + x + 8) * 4
            let destination = (y * width + x) * 4
            after[destination..<(destination + 4)] = before[source..<(source + 4)]
        }
    }

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height,
        configuration: MotionFieldConfiguration(maximumShift: 16, shiftStep: 4)
    )
    #expect(field.shifts.reduce(0) { $0 + $1.supportFraction } > 0.45)
    #expect(!field.structural.contains { rectArea($0.normalizedBounds) > 0.35 })
}

@Test func motionFieldRegistersLargeViewportScrollBeyondLocalTileSearch() throws {
    let width = 160, height = 120
    let shift = 42
    let before = texturedFrame(width: width, height: height)
    var after = texturedFrame(width: width, height: height)
    for y in 0..<(height - shift) {
        for x in 0..<width {
            let source = ((y + shift) * width + x) * 4
            let destination = (y * width + x) * 4
            after[destination..<(destination + 4)] = before[source..<(source + 4)]
        }
    }

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height,
        // The local matcher cannot reach the displacement. Whole-viewport
        // registration must preserve its scene-level meaning independently.
        configuration: MotionFieldConfiguration(maximumShift: 16, shiftStep: 4)
    )
    let viewport = try #require(field.viewportTranslation)
    #expect(abs(viewport.normalizedVector.dy) > 0.30)
    #expect(viewport.supportFraction > 0.45)
}

@Test func motionFieldKeepsFlyoutAppearanceTightWithoutDimming() throws {
    let width = 160, height = 120
    let before = texturedFrame(width: width, height: height)
    var after = before
    paintRGBA(&after, imageWidth: width, x: 102, y: 18, width: 50, height: 92, value: 242)
    for y in [32, 48, 64, 80, 96] {
        paintRGBA(&after, imageWidth: width, x: 110, y: y, width: 32, height: 3, value: 42)
    }

    let field = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    let subject = try #require(field.structural.max { $0.changedFraction < $1.changedFraction })
    let expected = CGRect(x: 102.0 / 160, y: 18.0 / 120, width: 50.0 / 160, height: 92.0 / 120)
    #expect(rectArea(subject.normalizedBounds.intersection(expected)) / rectArea(expected) > 0.88)
    #expect(rectArea(subject.normalizedBounds) < 0.30)
}

@Test func motionFieldSeparatesLocalReflowFromInsertedContent() throws {
    let width = 180, height = 140
    var before = [UInt8](repeating: 245, count: width * height * 4)
    var after = before
    paintTexture(&before, imageWidth: width, x: 24, y: 58, width: 132, height: 48)
    paintTexture(&after, imageWidth: width, x: 24, y: 82, width: 132, height: 48)
    paintRGBA(&after, imageWidth: width, x: 36, y: 16, width: 108, height: 52, value: 212)
    paintRGBA(&after, imageWidth: width, x: 48, y: 28, width: 72, height: 5, value: 30)

    let field = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    #expect(field.shifts.contains { $0.supportFraction > 0.08 && abs($0.normalizedVector.dy) > 0.08 })
    let inserted = try #require(field.structural.max { $0.changedFraction < $1.changedFraction })
    let expected = CGRect(x: 36.0 / 180, y: 16.0 / 140, width: 108.0 / 180, height: 52.0 / 140)
    #expect(rectArea(inserted.normalizedBounds.intersection(expected)) / rectArea(expected) > 0.70)
    #expect(inserted.normalizedBounds.midY < 0.55)
}

@Test func motionFieldDetectsGraphAnimationAsOneLocalizedSubject() throws {
    let width = 180, height = 120
    var before = [UInt8](repeating: 244, count: width * height * 4)
    var after = before
    for (x, oldHeight, newHeight) in [(30, 22, 48), (64, 36, 62), (98, 28, 54), (132, 42, 72)] {
        paintRGBA(&before, imageWidth: width, x: x, y: 102 - oldHeight, width: 20, height: oldHeight, value: 90)
        paintRGBA(&after, imageWidth: width, x: x, y: 102 - newHeight, width: 20, height: newHeight, value: 44)
    }

    let field = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    let subjects = field.structural.filter { $0.changedFraction > 0.005 }
    let graph = try #require(subjects.map(\.normalizedBounds).reduce(nil as CGRect?) { union, bounds in
        union.map { $0.union(bounds) } ?? bounds
    })
    #expect(subjects.count >= 3)
    #expect(graph.minX > 0.10)
    #expect(graph.maxX < 0.92)
    #expect(graph.minY > 0.15)
    #expect(graph.maxY < 0.92)
    #expect(rectArea(graph) > 0.20)
}

@Test func backdropBlurAndDimmingIsContextWhileDialogIsFocus() throws {
    let width = 180, height = 140
    let before = texturedFrame(width: width, height: height)
    var after = blurAndTransform(before, width: width, height: height, radius: 3, gain: 0.58, offset: 3)
    paintRGBA(&after, imageWidth: width, x: 52, y: 30, width: 78, height: 76, value: 224)
    for y in [44, 58, 72, 86] {
        paintRGBA(&after, imageWidth: width, x: 62, y: y, width: 56, height: 4, value: 34)
    }

    let field = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    let backdrop = try #require(field.backdrop)
    #expect(backdrop.direction == .focusGained)
    #expect(backdrop.blurRadius >= 2)
    #expect(backdrop.explainedChangeFraction > 0.45)
    let focus = try #require(backdrop.focusedBounds)
    let expected = CGRect(x: 52.0 / 180, y: 30.0 / 140, width: 78.0 / 180, height: 76.0 / 140)
    #expect(rectArea(focus.intersection(expected)) / rectArea(expected) > 0.82)
    #expect(field.focusedStructural.count == 1)
}

@Test func animatedBackdropCannotStealDialogFocus() throws {
    let width = 180, height = 140
    var before = texturedFrame(width: width, height: height)
    paintRGBA(&before, imageWidth: width, x: 10, y: 96, width: 38, height: 18, value: 245)
    var moved = texturedFrame(width: width, height: height)
    paintRGBA(&moved, imageWidth: width, x: 132, y: 96, width: 38, height: 18, value: 245)
    var after = blurAndTransform(moved, width: width, height: height, radius: 3, gain: 0.55, offset: 4)
    paintRGBA(&after, imageWidth: width, x: 52, y: 26, width: 78, height: 80, value: 226)
    paintRGBA(&after, imageWidth: width, x: 62, y: 42, width: 55, height: 5, value: 30)
    paintRGBA(&after, imageWidth: width, x: 62, y: 58, width: 48, height: 5, value: 30)

    let field = SpatialMotion.motionField(
        previous: before,
        current: after,
        width: width,
        height: height
    )
    let focus = try #require(field.backdrop?.focusedBounds)
    #expect(focus.midX > 0.40 && focus.midX < 0.60)
    #expect(focus.midY > 0.35 && focus.midY < 0.60)
    #expect(field.structural.contains { $0.normalizedBounds.maxX > 0.90 })
    #expect(field.focusedStructural.allSatisfy { $0.normalizedBounds.maxX <= 0.82 })
}

@Test func backdropFocusIsSymmetricWhenDialogCloses() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    var focused = blurAndTransform(clear, width: width, height: height, radius: 3, gain: 0.58, offset: 3)
    paintRGBA(&focused, imageWidth: width, x: 52, y: 30, width: 78, height: 76, value: 224)
    paintRGBA(&focused, imageWidth: width, x: 62, y: 46, width: 56, height: 5, value: 34)

    let opening = SpatialMotion.motionField(previous: clear, current: focused, width: width, height: height)
    let closing = SpatialMotion.motionField(previous: focused, current: clear, width: width, height: height)
    let openingFocus = try #require(opening.backdrop?.focusedBounds)
    let closingFocus = try #require(closing.backdrop?.focusedBounds)
    #expect(opening.backdrop?.direction == .focusGained)
    #expect(closing.backdrop?.direction == .focusReleased)
    #expect(rectArea(openingFocus.intersection(closingFocus)) / rectArea(openingFocus.union(closingFocus)) > 0.88)
}

@Test func pointerEvidenceCanOverrideBackdropVisualFocus() throws {
    let width = 180, height = 140
    var before = texturedFrame(width: width, height: height)
    paintRGBA(&before, imageWidth: width, x: 10, y: 96, width: 38, height: 18, value: 245)
    var moved = texturedFrame(width: width, height: height)
    paintRGBA(&moved, imageWidth: width, x: 132, y: 96, width: 38, height: 18, value: 245)
    var after = blurAndTransform(moved, width: width, height: height, radius: 3, gain: 0.55, offset: 4)
    paintRGBA(&after, imageWidth: width, x: 52, y: 26, width: 78, height: 80, value: 226)
    paintRGBA(&after, imageWidth: width, x: 62, y: 42, width: 55, height: 5, value: 30)
    let field = SpatialMotion.motionField(previous: before, current: after, width: width, height: height)
    let observations = field.framingObservations(at: 3.3)

    let focused = try composition(
        "[{\"action\":\"click\",\"time\":3,\"coordinates\":{\"xNorm\":0.5,\"yNorm\":0.5}}]",
        motion: observations
    )
    let overridden = try composition(
        "[{\"action\":\"click\",\"time\":3,\"coordinates\":{\"xNorm\":0.95,\"yNorm\":0.95}}]",
        motion: observations
    )
    let focusBounds = try #require(focused.actions[0].attention?.bounds)
    let override = try #require(overridden.actions[0].attention)
    #expect(focusBounds.maxX < 850)
    #expect(override.bounds.contains(CGPoint(x: 950, y: 40)))
    #expect(override.evidence.contains { $0.source == .pointer })
    #expect(override.evidence.contains { $0.source == .visualResponse })
}

@Test func focusTrackerPersistsAcrossBackdropMotionAndReleasesOnClose() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    var focused = blurAndTransform(clear, width: width, height: height, radius: 3, gain: 0.56, offset: 4)
    paintRGBA(&focused, imageWidth: width, x: 52, y: 28, width: 78, height: 78, value: 224)
    paintRGBA(&focused, imageWidth: width, x: 62, y: 44, width: 54, height: 5, value: 30)

    var movingBackdrop = clear
    paintRGBA(&movingBackdrop, imageWidth: width, x: 136, y: 96, width: 34, height: 18, value: 245)
    var focusedWithMotion = blurAndTransform(movingBackdrop, width: width, height: height, radius: 3, gain: 0.56, offset: 4)
    paintRGBA(&focusedWithMotion, imageWidth: width, x: 52, y: 28, width: 78, height: 78, value: 224)
    paintRGBA(&focusedWithMotion, imageWidth: width, x: 62, y: 44, width: 54, height: 5, value: 30)

    let opening = SpatialMotion.motionField(previous: clear, current: focused, width: width, height: height)
    let ambient = SpatialMotion.motionField(previous: focused, current: focusedWithMotion, width: width, height: height)
    let closing = SpatialMotion.motionField(previous: focusedWithMotion, current: clear, width: width, height: height)
    var tracker = MotionFocusTracker()

    let openingObservations = tracker.observations(for: opening, at: 1)
    let heldFocus = try #require(tracker.activeFocus)
    #expect(tracker.lastTransition == .gained)
    let ambientObservations = tracker.observations(for: ambient, at: 2)
    #expect(openingObservations.count == 1 && openingObservations[0].kind == .focus)
    #expect(ambient.backdrop == nil)
    #expect(ambient.structural.contains { $0.normalizedBounds.maxX > 0.70 })
    #expect(ambientObservations.count == 1 && ambientObservations[0].kind == .focus)
    #expect(tracker.lastTransition == .held)
    #expect(rectArea(ambientObservations[0].normalizedBounds.intersection(heldFocus)) / rectArea(heldFocus) > 0.90)

    let closingObservations = tracker.observations(for: closing, at: 3)
    #expect(closingObservations.count == 1 && closingObservations[0].kind == .focus)
    #expect(tracker.activeFocus == nil)
    #expect(tracker.lastTransition == .released)
}

@Test func focusTrackerUpdatesForDialogResizeAndClearsForPageReplacement() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    let backdrop = blurAndTransform(clear, width: width, height: height, radius: 3, gain: 0.56, offset: 4)
    var small = backdrop
    paintRGBA(&small, imageWidth: width, x: 70, y: 45, width: 40, height: 44, value: 224)
    paintRGBA(&small, imageWidth: width, x: 76, y: 56, width: 28, height: 5, value: 28)
    var large = backdrop
    paintRGBA(&large, imageWidth: width, x: 40, y: 18, width: 104, height: 100, value: 224)
    paintRGBA(&large, imageWidth: width, x: 54, y: 36, width: 76, height: 5, value: 28)

    let opening = SpatialMotion.motionField(previous: clear, current: small, width: width, height: height)
    let resize = SpatialMotion.motionField(previous: small, current: large, width: width, height: height)
    let replacement = SpatialMotion.motionField(
        previous: large,
        current: unrelatedFrame(width: width, height: height),
        width: width,
        height: height
    )
    var tracker = MotionFocusTracker()
    _ = tracker.observations(for: opening, at: 1)
    let initial = try #require(tracker.activeFocus)
    let resizeObservations = tracker.observations(for: resize, at: 2)
    let resized = try #require(tracker.activeFocus)
    #expect(resizeObservations.count == 1 && resizeObservations[0].kind == .focus)
    #expect(resized.width > initial.width * 1.08)
    #expect(resized.height > initial.height * 1.08)
    #expect(tracker.lastTransition == .updated)

    let replacementObservations = tracker.observations(for: replacement, at: 3)
    #expect(tracker.activeFocus == nil)
    #expect(!replacementObservations.contains { $0.kind == .focus })
    #expect(tracker.lastTransition == .invalidated)
}

@Test func focusTrackerDoesNotCollapseOntoAnimationInsideForeground() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    let backdrop = blurAndTransform(clear, width: width, height: height, radius: 3, gain: 0.56, offset: 4)
    var focused = backdrop
    paintRGBA(&focused, imageWidth: width, x: 42, y: 20, width: 98, height: 96, value: 224)
    paintRGBA(&focused, imageWidth: width, x: 54, y: 36, width: 72, height: 5, value: 28)
    var animated = focused
    paintTexture(&animated, imageWidth: width, x: 62, y: 56, width: 58, height: 42)

    let opening = SpatialMotion.motionField(previous: clear, current: focused, width: width, height: height)
    let internalAnimation = SpatialMotion.motionField(previous: focused, current: animated, width: width, height: height)
    var tracker = MotionFocusTracker()
    _ = tracker.observations(for: opening, at: 1)
    let established = try #require(tracker.activeFocus)
    _ = tracker.observations(for: internalAnimation, at: 2)

    #expect(tracker.activeFocus == established)
    #expect(tracker.lastTransition == .held)
}

@Test func semanticDismissalReleasesAmbiguousVisualFocus() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    var focused = blurAndTransform(clear, width: width, height: height, radius: 3, gain: 0.56, offset: 4)
    paintRGBA(&focused, imageWidth: width, x: 52, y: 28, width: 78, height: 78, value: 224)
    paintRGBA(&focused, imageWidth: width, x: 62, y: 44, width: 54, height: 5, value: 30)
    let opening = SpatialMotion.motionField(previous: clear, current: focused, width: width, height: height)
    var tracker = MotionFocusTracker()
    _ = tracker.observations(for: opening, at: 1)
    let established = try #require(tracker.activeFocus)

    let observations = tracker.observations(for: opening, at: 2, intent: .dismissal)
    #expect(tracker.activeFocus == nil)
    #expect(tracker.lastTransition == .released)
    #expect(observations.first?.normalizedBounds == established)
}

@Test func focusTrackerUsesLifecycleStateWhenRawBackdropPolarityIsAmbiguous() throws {
    let width = 180, height = 140
    let clear = texturedFrame(width: width, height: height)
    var focused = blurAndTransform(clear, width: width, height: height, radius: 1, gain: 0.56, offset: 4)
    paintRGBA(&focused, imageWidth: width, x: 52, y: 28, width: 78, height: 78, value: 224)
    paintRGBA(&focused, imageWidth: width, x: 62, y: 44, width: 54, height: 5, value: 30)
    let visuallyReversed = SpatialMotion.motionField(previous: focused, current: clear, width: width, height: height)
    var tracker = MotionFocusTracker()

    let observations = tracker.observations(for: visuallyReversed, at: 1)
    #expect(tracker.activeFocus != nil)
    #expect(tracker.lastTransition == .gained)
    #expect(observations.first?.focusTransition == .gained)

    tracker.reset()
    let dismissal = tracker.observations(for: visuallyReversed, at: 2, intent: .dismissal)
    #expect(tracker.activeFocus == nil)
    #expect(tracker.lastTransition == nil)
    #expect(!dismissal.contains { $0.kind == .focus })
}

@Test func responseTileSizePreservesNormalizedDetectorDensity() {
    let fullWidth = 320
    let halfWidth = fullWidth / 2
    let fullTile = MotionFieldConfiguration.normalizedTileSize(forRasterWidth: fullWidth)
    let halfTile = MotionFieldConfiguration.normalizedTileSize(forRasterWidth: halfWidth)

    #expect(fullTile == 6)
    #expect(halfTile == 3)
    #expect(abs(Double(fullTile) / Double(fullWidth) - Double(halfTile) / Double(halfWidth)) < 0.000_001)
}

private func texturedFrame(width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            let value = UInt8(36 + ((x * 31 + y * 17 + (x * y) % 47) % 185))
            pixels[offset] = value
            pixels[offset + 1] = UInt8(min(255, Int(value) + (x % 13)))
            pixels[offset + 2] = UInt8(max(0, Int(value) - (y % 11)))
            pixels[offset + 3] = 255
        }
    }
    return pixels
}

private func unrelatedFrame(width: Int, height: Int) -> [UInt8] {
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let offset = (y * width + x) * 4
            pixels[offset] = UInt8((x * 7 + y * 43 + (x * y) % 97) % 256)
            pixels[offset + 1] = UInt8((x * 29 + y * 11 + 71) % 256)
            pixels[offset + 2] = UInt8((x * 3 + y * 37 + 149) % 256)
            pixels[offset + 3] = 255
        }
    }
    return pixels
}

private func applyAffineLuminance(to pixels: inout [UInt8], gain: Double, offset: Double) {
    for index in stride(from: 0, to: pixels.count, by: 4) {
        for channel in 0..<3 {
            let transformed = gain * Double(pixels[index + channel]) + offset
            pixels[index + channel] = UInt8(clamping: Int(transformed.rounded()))
        }
    }
}

private func paintRGBA(
    _ pixels: inout [UInt8], imageWidth: Int,
    x: Int, y: Int, width: Int, height: Int, value: UInt8
) {
    for py in y..<(y + height) {
        for px in x..<(x + width) {
            let offset = (py * imageWidth + px) * 4
            pixels[offset] = value
            pixels[offset + 1] = value
            pixels[offset + 2] = value
            pixels[offset + 3] = 255
        }
    }
}

private func paintTexture(
    _ pixels: inout [UInt8], imageWidth: Int,
    x: Int, y: Int, width: Int, height: Int
) {
    for py in y..<(y + height) {
        for px in x..<(x + width) {
            let offset = (py * imageWidth + px) * 4
            let localX = px - x
            let localY = py - y
            let value = UInt8(38 + ((localX * 23 + localY * 19 + (localX * localY) % 41) % 180))
            pixels[offset] = value
            pixels[offset + 1] = UInt8(min(255, Int(value) + px % 9))
            pixels[offset + 2] = UInt8(max(0, Int(value) - py % 7))
            pixels[offset + 3] = 255
        }
    }
}

private func blurAndTransform(
    _ pixels: [UInt8],
    width: Int,
    height: Int,
    radius: Int,
    gain: Double,
    offset: Double
) -> [UInt8] {
    var result = pixels
    for y in 0..<height {
        for x in 0..<width {
            let x0 = max(0, x - radius), x1 = min(width, x + radius + 1)
            let y0 = max(0, y - radius), y1 = min(height, y + radius + 1)
            let count = (x1 - x0) * (y1 - y0)
            var sums = [Int](repeating: 0, count: 3)
            for sourceY in y0..<y1 {
                for sourceX in x0..<x1 {
                    let source = (sourceY * width + sourceX) * 4
                    for channel in 0..<3 { sums[channel] += Int(pixels[source + channel]) }
                }
            }
            let destination = (y * width + x) * 4
            for channel in 0..<3 {
                let transformed = gain * Double(sums[channel]) / Double(count) + offset
                result[destination + channel] = UInt8(clamping: Int(transformed.rounded()))
            }
            result[destination + 3] = 255
        }
    }
    return result
}

private func rectArea(_ rect: CGRect) -> CGFloat {
    rect.width * rect.height
}

@Test func motionFramingRejectsMicroDeltasAndViewportTranslation() {
    let tiny = VisualMotionObservation(
        time: 1, normalizedBounds: CGRect(x: 0.4, y: 0.4, width: 0.05, height: 0.05),
        changedFraction: 0.0009, magnitude: 1, kind: .appearance
    )
    let translated = VisualMotionObservation(
        time: 1, normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7),
        changedFraction: 0.2, magnitude: 1, kind: .translation
    )
    let reveal = VisualMotionObservation(
        time: 1, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.2),
        changedFraction: 0.02, magnitude: 1, kind: .appearance
    )
    #expect(!SpatialMotion.isFramingEligible(tiny))
    #expect(!SpatialMotion.isFramingEligible(translated))
    #expect(SpatialMotion.isFramingEligible(reveal))
    #expect(!SpatialMotion.hasWideFramingCandidate([reveal], minimumAreaFraction: 0.08))
    #expect(SpatialMotion.hasWideFramingCandidate([reveal], minimumAreaFraction: 0.05))
}

@Test func localizedPostActivationTranslationBecomesResponseWhileBroadScrollRemainsTranslation() {
    let local = SpatialMotion.postActivationResponseComponents([
        DetectedMotionComponent(
            normalizedBounds: CGRect(x: 0.20, y: 0.48, width: 0.43, height: 0.21),
            changedFraction: 0.014, magnitude: 1, kind: .translation
        ),
        DetectedMotionComponent(
            normalizedBounds: CGRect(x: 0.70, y: 0.48, width: 0.25, height: 0.24),
            changedFraction: 0.009, magnitude: 1, kind: .translation
        )
    ])
    #expect(local.allSatisfy { $0.kind == .transformation })

    let broad = SpatialMotion.postActivationResponseComponents([
        DetectedMotionComponent(
            normalizedBounds: CGRect(x: 0.05, y: 0.08, width: 0.90, height: 0.78),
            changedFraction: 0.35, magnitude: 1, kind: .translation
        )
    ])
    #expect(broad[0].kind == .translation)
}

@Test func causalMotionRejectsAnimationAlreadyActiveBeforeAction() {
    let ambient = DetectedMotionComponent(
        normalizedBounds: CGRect(x: 0.05, y: 0.15, width: 0.3, height: 0.2),
        changedFraction: 0.05, magnitude: 1, kind: .appearance
    )
    let reveal = DetectedMotionComponent(
        normalizedBounds: CGRect(x: 0.58, y: 0.2, width: 0.3, height: 0.4),
        changedFraction: 0.12, magnitude: 1, kind: .appearance
    )
    let causal = SpatialMotion.causalComponents(baseline: [ambient], response: [ambient, reveal])
    #expect(causal.count == 1)
    #expect(causal[0].normalizedBounds == reveal.normalizedBounds)
}

@Test func interactionTimingSeparatesHoverActivationAndResponse() {
    let samples = [
        InteractionActivitySample(time: 9.80, magnitude: 0.03),
        InteractionActivitySample(time: 10.20, magnitude: 0.9),
        InteractionActivitySample(time: 10.24, magnitude: 0.8),
        InteractionActivitySample(time: 10.72, magnitude: 1.1),
        InteractionActivitySample(time: 10.75, magnitude: 1.8),
        InteractionActivitySample(time: 11.05, magnitude: 8),
        InteractionActivitySample(time: 11.08, magnitude: 6)
    ]
    let phases = InteractionPhaseDetector.detect(
        samples: samples, rawEstimate: 10.45, toolStart: 10, toolEnd: 10.70,
        finalActionInToolCall: true
    )
    #expect(abs(phases.pointerArrival - 10.20) < 0.001)
    #expect(abs(phases.activation - 10.72) < 0.001)
    #expect(phases.prePointerActivityEnd == nil)
    #expect(abs((phases.preActivationActivityEnd ?? 0) - 10.24) < 0.001)
    #expect(abs((phases.responseOnset ?? 0) - 11.05) < 0.001)
    #expect(phases.source == "target-visual")
    #expect(phases.pointerArrivalSource == "target-visual-hover")
}

@Test func activationFrameCannotBecomeItsOwnCausalBaseline() {
    let times = [36.266, 36.451, 36.535, 36.735]
    let index = CausalFrameOrdering.preActivationSampleIndex(
        in: times, activationBoundary: 36.535
    )

    #expect(index == 1)
    if let index { #expect(times[index] == 36.451) }
}

@Test func interactionTimingTargetUsesPointForBroadAccessibilityContainers() throws {
    let broadTextArea = CGRect(x: 0, y: 0.2, width: 0.97, height: 0.75)
    let point = CGPoint(x: 0.49, y: 0.58)
    let resolved = try #require(InteractionTimingTarget.resolve(
        semanticBounds: broadTextArea,
        normalizedPoint: point
    ))
    #expect(abs(resolved.midX - point.x) < 0.001)
    #expect(abs(resolved.midY - point.y) < 0.001)
    #expect(abs(resolved.width - 0.08) < 0.001)
    #expect(abs(resolved.height - 0.08) < 0.001)
}

@Test func interactionTimingTargetPreservesPreciseSemanticControls() throws {
    let control = CGRect(x: 0.52, y: 0.08, width: 0.09, height: 0.04)
    let resolved = try #require(InteractionTimingTarget.resolve(
        semanticBounds: control,
        normalizedPoint: CGPoint(x: 0.56, y: 0.10)
    ))
    #expect(abs(resolved.minX - control.minX) < 0.001)
    #expect(abs(resolved.minY - control.minY) < 0.001)
    #expect(abs(resolved.width - control.width) < 0.001)
    #expect(abs(resolved.height - control.height) < 0.001)
}

@Test func scrollAndViewportRelocationFinishBeforePointerTravel() throws {
    let afterExplicitScroll = try composition("""
    [
      {"action":"scroll","time":3,"timing":{"toolCallDurationMs":800}},
      {"action":"click","time":4.2,"coordinates":{"xNorm":0.78,"yNorm":0.35}}
    ]
    """, duration: 7)
    let scrollOrderedTrip = try #require(afterExplicitScroll.pointerTrip(forActionID: 1))
    #expect(scrollOrderedTrip.start >= 3.4)

    let relocationPhases = InteractionPhases(
        rawEstimate: 4.1,
        toolStart: 3.8,
        toolEnd: 4.9,
        pointerArrival: 4.05,
        activation: 4.72,
        responseOnset: 4.95,
        source: "target-visual",
        activityThreshold: 0.55,
        prePointerActivityEnd: 4.32,
        preActivationActivityEnd: 4.32
    )
    let afterInternalRelocation = try composition("""
    [{"action":"click","time":4.1,"coordinates":{"xNorm":0.82,"yNorm":0.52},"semanticTarget":{"bounds":{"xNorm":0.79,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.05},"viewportRelocation":{"kind":"target-entered-viewport","displacementNorm":0.62,"fromVisibleFraction":0,"toVisibleFraction":1,"postActionOffsetMs":450}}}]
    """, duration: 7, interactionPhases: [0: relocationPhases])
    let relocationOrderedTrip = try #require(afterInternalRelocation.pointerTrip(forActionID: 0))
    #expect(relocationOrderedTrip.start >= 4.37)
    #expect(relocationOrderedTrip.end <= relocationPhases.activation)
}

@Test func relocationHoverDoesNotCollapseLongPointerTravel() throws {
    let phases = InteractionPhaseDetector.detect(
        samples: [
            InteractionActivitySample(time: 32.765, magnitude: 16.2),
            InteractionActivitySample(time: 33.465, magnitude: 12.0),
            InteractionActivitySample(time: 33.665, magnitude: 11.3)
        ],
        rawEstimate: 33.426,
        toolStart: 32.691,
        toolEnd: 35.628,
        finalActionInToolCall: false
    )
    #expect(abs((phases.prePointerActivityEnd ?? 0) - 32.765) < 0.001)
    #expect(abs(phases.pointerArrival - 33.465) < 0.001)
    #expect(phases.pointerArrivalSource == "target-visual-hover")

    let directed = try composition("""
    [
      {"action":"click","time":19.337,"coordinates":{"xNorm":0.71,"yNorm":0.34}},
      {"action":"click","time":33.426,"coordinates":{"xNorm":0.16,"yNorm":0.47},"semanticTarget":{"bounds":{"xNorm":0.12,"yNorm":0.44,"widthNorm":0.08,"heightNorm":0.06},"viewportRelocation":{"kind":"target-entered-viewport","displacementNorm":0.72,"fromVisibleFraction":0,"toVisibleFraction":1,"postActionOffsetMs":1043}}}
    ]
    """, duration: 38, reduceWaiting: true, waitingTime: 1.5, interactionPhases: [1: phases])
    let trip = try #require(directed.pointerTrip(forActionID: 1))
    #expect(trip.start >= 32.815 - 0.001)
    #expect(trip.end <= phases.pointerArrival)
    #expect(trip.end - trip.start > 0.5)
    #expect(directed.retime.contains {
        $0.sourceStart <= trip.start && $0.sourceEnd >= trip.end && $0.rate == 1
    })
}

@Test func interactionTimingFallsBackToSemanticToolCompletionWithoutMagicOffset() {
    let phases = InteractionPhaseDetector.detect(
        samples: [], rawEstimate: 4.4, toolStart: 4, toolEnd: 4.8,
        finalActionInToolCall: true
    )
    #expect(phases.pointerArrival == 4.4)
    #expect(phases.activation == 4.8)
    #expect(phases.source == "tool-completion")
    #expect(phases.pointerArrivalSource == "telemetry-estimate")
}

@Test func nativeActivationWithoutHoverUsesProportionalArrivalLead() {
    let phases = InteractionPhaseDetector.detect(
        samples: [
            InteractionActivitySample(time: 10.72, magnitude: 1.1),
            InteractionActivitySample(time: 10.75, magnitude: 1.4)
        ],
        rawEstimate: 10.35, toolStart: 10, toolEnd: 10.70,
        finalActionInToolCall: true
    )
    #expect(phases.source == "target-visual")
    #expect(phases.pointerArrivalSource == "activation-relative-fallback")
    #expect(abs(phases.pointerArrival - (10.72 - 0.084)) < 0.001)
}

@Test func rawSpanningActivityIsActivationRatherThanHover() {
    let samples = [
        InteractionActivitySample(time: 55.46, magnitude: 0.7),
        InteractionActivitySample(time: 55.52, magnitude: 1.2),
        InteractionActivitySample(time: 55.58, magnitude: 6.0),
        InteractionActivitySample(time: 55.64, magnitude: 2.0),
        InteractionActivitySample(time: 55.70, magnitude: 1.0),
        InteractionActivitySample(time: 55.76, magnitude: 0.8),
        InteractionActivitySample(time: 55.82, magnitude: 0.7),
        InteractionActivitySample(time: 55.88, magnitude: 0.6),
        InteractionActivitySample(time: 56.03, magnitude: 5.0),
        InteractionActivitySample(time: 56.08, magnitude: 3.0)
    ]
    let phases = InteractionPhaseDetector.detect(
        samples: samples, rawEstimate: 55.60, toolStart: 55.10, toolEnd: 56.10,
        finalActionInToolCall: true
    )
    #expect(abs(phases.activation - 55.58) < 0.001)
    #expect(abs(phases.pointerArrival - 55.46) < 0.001)
    #expect(phases.source == "target-visual-raw-span")
    #expect(phases.pointerArrivalSource == "activation-cluster-onset")
    #expect(phases.preActivationActivityEnd == nil)
}

@Test func lowContrastRawSpanningActivityUsesItsOnset() {
    let phases = InteractionPhaseDetector.detect(
        samples: [
            InteractionActivitySample(time: 35.80, magnitude: 0.8),
            InteractionActivitySample(time: 35.90, magnitude: 1.1),
            InteractionActivitySample(time: 36.00, magnitude: 1.4),
            InteractionActivitySample(time: 36.10, magnitude: 1.6),
            InteractionActivitySample(time: 36.20, magnitude: 1.2)
        ],
        rawEstimate: 36.05, toolStart: 35.78, toolEnd: 36.41,
        finalActionInToolCall: true
    )
    #expect(abs(phases.activation - 35.80) < 0.001)
    #expect(phases.source == "target-visual-raw-span")
}

@Test func batchedActionsCannotReuseALaterActionsVisualActivation() {
    let samples = [
        InteractionActivitySample(time: 57.10, magnitude: 8.0),
        InteractionActivitySample(time: 57.16, magnitude: 7.0)
    ]
    let earlier = InteractionPhaseDetector.detect(
        samples: samples,
        rawEstimate: 53.49,
        toolStart: 53.05,
        toolEnd: 58.23,
        finalActionInToolCall: false,
        actionWindow: 53.00...54.35
    )
    let later = InteractionPhaseDetector.detect(
        samples: samples,
        rawEstimate: 56.94,
        toolStart: 53.05,
        toolEnd: 58.23,
        finalActionInToolCall: true,
        actionWindow: 56.08...58.41
    )

    #expect(abs(earlier.activation - 53.49) < 0.001)
    #expect(earlier.source == "telemetry-estimate")
    #expect(earlier.responseOnset == nil)
    #expect(abs(later.activation - 57.10) < 0.001)
    #expect(later.source == "target-visual")
}

@Test func cameraFollowsPointerDepartureBeforeMeasuredActivation() throws {
    let phases = InteractionPhases(
        rawEstimate: 4.3,
        toolStart: 3.9,
        toolEnd: 4.65,
        pointerArrival: 4.2,
        activation: 4.7,
        responseOnset: 5.05,
        source: "target-visual",
        activityThreshold: 0.1
    )
    let directed = try composition(
        """
        [{"action":"click","time":4.3,"coordinates":{"xNorm":0.82,"yNorm":0.2}}]
        """,
        duration: 8,
        interactionPhases: [0: phases]
    )

    let trip = try #require(directed.pointerTrip(forActionID: 0))
    // Camera follows the reconstructed departure 100 ms later rather than
    // waiting for the measured click activation at 4.70.
    #expect(abs(directed.shots[0].start - (trip.start + 0.1)) < 0.001)
    #expect(exp(try #require(directed.settledCamera(forActionID: 0)).logScale) > 1)
    #expect(directed.cursor(at: (trip.start + trip.end) / 2).point.x > size.width * 0.16)
    #expect(directed.retime.contains {
        $0.sourceStart <= trip.start && $0.sourceEnd >= 4.7 && $0.rate == 1
    })
}

@Test func everyNonDragCursorTripUsesOneSnappyDurationBand() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.85,"yNorm":0.85}},
      {"action":"click","time":6,"coordinates":{"xNorm":0.10,"yNorm":0.10}},
      {"action":"click","time":8,"coordinates":{"xNorm":0.12,"yNorm":0.12}}
    ]
    """, duration: 10)
    let trips = try (0...2).map { try #require(directed.pointerTrip(forActionID: $0)) }
    let durations = trips.map { $0.end - $0.start }

    #expect(durations.allSatisfy { $0 >= 0.32 - 0.001 && $0 <= 0.78 + 0.001 })
    #expect(durations[0] > durations[2])
    #expect(durations[1] > durations[2])
}

@Test func pageSizedNavigationResponseDoesNotForceZoom() throws {
    let directed = try composition("""
    [{"action":"click","time":3}]
    """, motion: [
        VisualMotionObservation(time: 3.4, normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1), changedFraction: 0.8, magnitude: 1)
    ])
    #expect(directed.shots.count == 1)
    #expect(directed.shots[0].scale == 1)
}

@Test func unresolvedClickUsesNonFactualVisualPointerFallback() throws {
    let directed = try composition("""
    [{"action":"click","time":3}]
    """, motion: [
        VisualMotionObservation(
            time: 3.2,
            normalizedBounds: CGRect(x: 0.72, y: 0.2, width: 0.12, height: 0.08),
            changedFraction: 0.02,
            magnitude: 0.7,
            kind: .appearance
        )
    ])
    #expect(directed.actions[0].point != nil)
    #expect(directed.actions[0].pointProvenance == "visual-inferred")
    #expect(directed.anchors.isEmpty)
    #expect(directed.actions[0].rendersCursor == false)
    #expect(directed.actions[0].attention?.evidence.contains { $0.source == .visualPointer } == true)

    // Inferred cursor motion is editorial evidence, not a factual camera
    // constraint. An arbitrary camera pose must not be corrected to contain it.
    let camera = CameraState(x: 500, y: 400, logScale: log(1.5))
    let adjusted = directed.enforcingFactualActionVisibility(camera, at: 3)
    #expect(adjusted.x == camera.x)
    #expect(adjusted.y == camera.y)
    #expect(adjusted.logScale == camera.logScale)
}

@Test func inferredCursorRequiresExplicitRecipeOptIn() throws {
    let directed = try composition("""
    [{"action":"click","time":3}]
    """, motion: [
        VisualMotionObservation(
            time: 3.2,
            normalizedBounds: CGRect(x: 0.72, y: 0.2, width: 0.12, height: 0.08),
            changedFraction: 0.02,
            magnitude: 0.7,
            kind: .appearance
        )
    ], allowInferredTargets: true)
    #expect(directed.actions[0].pointProvenance == "visual-inferred")
    #expect(directed.actions[0].rendersCursor)
    #expect(directed.anchors.count == 1)
}

@Test func noResponseClickRemainsUnresolvedWithoutInventingCameraAttention() throws {
    let directed = try composition("""
    [{"action":"click","time":3}]
    """)
    #expect(directed.actions[0].point == nil)
    #expect(directed.actions[0].pointProvenance == nil)
    #expect(directed.actions[0].attention == nil)
    #expect(directed.anchors.isEmpty)
    #expect(directed.shots.isEmpty)

    let camera = CameraState(x: 500, y: 400, logScale: log(1.5))
    let adjusted = directed.enforcingFactualActionVisibility(camera, at: 3)
    #expect(adjusted.x == camera.x)
    #expect(adjusted.y == camera.y)
    #expect(adjusted.logScale == camera.logScale)
}

@Test func elementIndexedActionsNeverBorrowCoordinatesFromOtherActions() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"args":{"element_index":31}},
      {"action":"set_value","time":10,"semanticTarget":{"bounds":{"xNorm":0.94,"yNorm":0.18,"widthNorm":0.04,"heightNorm":0.18}}},
      {"action":"drag","time":31,"coordinates":{"from":{"xNorm":0.96,"yNorm":0.24},"to":{"xNorm":0.96,"yNorm":0.2}}}
    ]
    """, duration: 36, motion: [
        // Playback animation in the graph is visible near the first attempt,
        // but it is not evidence for where the agent tried to click.
        VisualMotionObservation(
            time: 3.2,
            normalizedBounds: CGRect(x: 0.42, y: 0.35, width: 0.2, height: 0.18),
            changedFraction: 0.04,
            magnitude: 0.8,
            kind: .transformation
        )
    ])

    let unresolved = directed.actions[0]
    #expect(unresolved.requiresExactTarget)
    #expect(unresolved.point == nil)
    #expect(unresolved.pointProvenance == nil)
    #expect(unresolved.attention?.evidence.contains { $0.source == .visualPointer } == false)
    #expect(unresolved.attention?.evidence.contains { $0.source == .accessibility } == false)
}

@Test func nearbyControlsClusterUsingEditedTimeAndViewportOverlap() throws {
    let directed = try composition("""
    [
      {"action":"drag","time":3,"coordinates":{"from":{"xNorm":0.65,"yNorm":0.55},"to":{"xNorm":0.76,"yNorm":0.55}}},
      {"action":"click","time":11,"coordinates":{"xNorm":0.72,"yNorm":0.62}},
      {"action":"click","time":17,"coordinates":{"xNorm":0.79,"yNorm":0.68}}
    ]
    """, duration: 22)
    #expect(directed.shots.count == 1)
    #expect(directed.shots[0].actions.count == 3)
}

@Test func reduceWaitingCutsGapsWithoutSpeedingMotion() throws {
    let events = """
    [{"action":"click","time":10,"coordinates":{"xNorm":0.5,"yNorm":0.5}}]
    """
    let compressed = try composition(events, duration: 20)
    let cut = try composition(events, duration: 20, reduceWaiting: true, waitingTime: 0.1)
    #expect(cut.outputDuration < compressed.outputDuration)
    #expect(cut.retime.allSatisfy { $0.rate == 1 })
    let jumps = zip(cut.retime, cut.retime.dropFirst()).filter { left, right in
        abs(left.sourceEnd - right.sourceStart) > 0.001
    }
    #expect(!jumps.isEmpty)
    #expect(cut.retime.filter { $0.outputDuration < 0.051 }.count >= 2)
}

@Test func groupsShotsAndReconstructsPointerMotion() throws {
    let directed = try composition("""
    [
      {"action":"click","time":3,"coordinates":{"xNorm":0.2,"yNorm":0.3}},
      {"action":"click","time":4.4,"coordinates":{"xNorm":0.3,"yNorm":0.35}},
      {"action":"type_text","time":5,"timing":{"toolCallDurationMs":800}},
      {"action":"drag","time":9,"timing":{"toolCallDurationMs":1000},"coordinates":{"from":{"xNorm":0.7,"yNorm":0.3},"to":{"xNorm":0.82,"yNorm":0.7}}}
    ]
    """)
    #expect(directed.actions.count == 4)
    #expect(directed.shots.count == 2)
    let firstTrip = try #require(directed.pointerTrip(forActionID: 0))
    #expect(abs(directed.shots[0].start - (firstTrip.start + 0.1)) < 0.001)
    #expect(abs(directed.shots[0].focusStart - 3.12) < 0.001)
    #expect(directed.shots[0].focusEnd > 4.9)
    #expect(abs(directed.cursor(at: 3).point.x - 200) < 0.001)
    #expect(abs(directed.cursor(at: 3).point.y - 560) < 0.001)
    #expect(abs(directed.cursor(at: 3).scale - 0.9) < 0.001)
    #expect(abs(directed.cursor(at: 8.5).point.x - 700) < 0.001)
    #expect(abs(directed.cursor(at: 9.5).point.x - 820) < 0.001)
}

@Test func scrollAndLocationlessTypingDoNotInventCameraTargets() throws {
    let directed = try composition("""
    [
      {"action":"type_text","time":2,"timing":{"toolCallDurationMs":500}},
      {"action":"scroll","time":6,"timing":{"toolCallDurationMs":700}}
    ]
    """)
    #expect(directed.shots.isEmpty)
    #expect(directed.settledCamera(forActionID: 0) == nil)
    #expect(directed.settledCamera(forActionID: 1) == nil)
}

@Test func semanticTypingCreatesAFieldShotWithoutCursorAnchor() throws {
    let directed = try composition("""
    [{"action":"type_text","time":4,"semanticTarget":{"bounds":{"xNorm":0.2,"yNorm":0.25,"widthNorm":0.4,"heightNorm":0.08}}}]
    """)
    #expect(directed.shots.count == 1)
    #expect(directed.anchors.isEmpty)
    #expect(exp(try #require(directed.settledCamera(forActionID: 0)).logScale) > 1.2)
}

@Test func retimingIsMonotonicAndCompressesDeadAir() throws {
    let directed = try composition("""
    [{"action":"click","time":3,"coordinates":{"xNorm":0.5,"yNorm":0.5}}]
    """, duration: 20)
    #expect(directed.outputDuration < 10)
    let samples = stride(from: 0.0, through: directed.outputDuration, by: 0.1).map(directed.sourceTime)
    #expect(zip(samples, samples.dropFirst()).allSatisfy { $0 <= $1 })
}

@Test func convertsMacCursorHotspotToCoreImageCoordinates() {
    let hotspot = coreImageCursorHotspot(
        logicalSize: CGSize(width: 28, height: 40),
        hotspotFromTopLeft: CGPoint(x: 5, y: 5),
        scale: 3
    )
    #expect(hotspot == CGPoint(x: 15, y: 105))
}

@Test func cameraProjectionAllowsCursorToLeaveViewport() {
    let projected = projectPointThroughCamera(
        CGPoint(x: 900, y: 700),
        camera: CameraState(x: 250, y: 250, logScale: log(1.6)),
        outputSize: CGSize(width: 1000, height: 800)
    )
    #expect(projected.x > 1000)
    #expect(projected.y > 800)
}

@Test func factualVisibilityRecoveryPreservesHeldZoomDuringPan() {
    let heldScale = log(1.58)
    let planned = (0..<11).map { index in
        CameraState(x: 400 + CGFloat(index) * 20, y: 300, logScale: heldScale)
    }
    var adjusted = planned
    adjusted[5] = CameraState(x: planned[5].x + 45, y: planned[5].y, logScale: heldScale)
    let recovery = smoothedVisibilityCorrections(
        unconstrained: planned, adjusted: adjusted, samplesPerSecond: 10, shoulderSeconds: 0.3
    )
    #expect(recovery.ranges == [5...5])
    #expect(recovery.states.allSatisfy { abs($0.logScale - heldScale) < 0.000001 })
    #expect(recovery.states[5].x == adjusted[5].x)
    #expect(recovery.states[4].x > planned[4].x)
    #expect(recovery.states[6].x > planned[6].x)
}

@Test func activeClickCursorIsKeptVisibleButIdleCursorIsUnconstrained() throws {
    let directed = try composition("""
    [{"action":"click","time":4,"coordinates":{"xNorm":0.92,"yNorm":0.94}}]
    """, duration: 8)
    let laggingCamera = CameraState(x: 180, y: 150, logScale: log(1.6))

    let activeTime = 3.5
    let corrected = directed.enforcingFactualActionVisibility(laggingCamera, at: activeTime)
    let activeCursor = directed.cursor(at: activeTime).point
    let projected = projectPointThroughCamera(activeCursor, camera: corrected, outputSize: size)
    #expect(projected.x >= 0 && projected.x <= size.width)
    #expect(projected.y >= 0 && projected.y <= size.height)

    let idle = directed.enforcingFactualActionVisibility(laggingCamera, at: 6)
    #expect(idle.x == laggingCamera.x)
    #expect(idle.y == laggingCamera.y)
    #expect(idle.logScale == laggingCamera.logScale)
}

@Test func unresolvedPointerGapProtectsArrivalButNotInventedTravel() throws {
    let directed = try composition("""
    [
      {"action":"click","time":1,"coordinates":{"xNorm":0.90,"yNorm":0.50}},
      {"action":"click","time":2},
      {"action":"click","time":4,"coordinates":{"xNorm":0.10,"yNorm":0.50}}
    ]
    """, duration: 6)
    #expect(!directed.actions[1].rendersCursor)
    let trip = try #require(directed.pointerTrip(forActionID: 2))

    // The visual interpolation crosses an unresolved action and therefore is
    // not factual camera authority before the next measured arrival.
    let inventedTravelTime = (trip.start + trip.end) / 2
    let leftCamera = CameraState(x: 180, y: size.height / 2, logScale: log(1.6))
    let unchanged = directed.enforcingFactualActionVisibility(
        leftCamera, at: inventedTravelTime
    )
    #expect(unchanged == leftCamera)

    // The known destination and activation remain non-negotiable.
    let rightCamera = CameraState(
        x: size.width - 180, y: size.height / 2, logScale: log(1.6)
    )
    let arrival = directed.enforcingFactualActionVisibility(
        rightCamera, at: trip.end - 0.05
    )
    #expect(arrival != rightCamera)
}

@Test func semanticInputTargetCorrectsCameraLagTowardSafeFrame() throws {
    let directed = try composition("""
    [{"action":"type_text","time":4,"semanticTarget":{"bounds":{"xNorm":0.25,"yNorm":0.84,"widthNorm":0.5,"heightNorm":0.06}}}]
    """, duration: 8)
    let target = try #require(directed.actions[0].semanticBounds)
    let laggingCamera = CameraState(x: size.width / 2, y: size.height * 0.25, logScale: log(1.55))
    let corrected = directed.enforcingFactualActionVisibility(laggingCamera, at: 4)
    let projectedCenter = projectPointThroughCamera(
        CGPoint(x: target.midX, y: target.midY), camera: corrected, outputSize: size
    )
    #expect(projectedCenter.y >= 50)
    #expect(projectedCenter.y <= size.height - 50)
}

@Test func naturalCursorCurvesAndLeansIntoFastTravel() throws {
    let directed = try composition("""
    [{"action":"click","time":3,"coordinates":{"xNorm":0.82,"yNorm":0.2}}]
    """)
    let moving = directed.cursor(at: 2.45)
    let recentlyArrived = directed.cursor(at: 3.12)
    let settled = directed.cursor(at: 3.75)
    #expect(moving.rotation < -0.03)
    #expect(moving.rotation >= -.pi / 4)
    #expect(recentlyArrived.rotation < -0.01)
    #expect(abs(recentlyArrived.rotation) < abs(moving.rotation))
    #expect(abs(settled.rotation) < 0.001)
    #expect(stride(from: 1.8, through: 3.75, by: 0.04).allSatisfy {
        let rotation = directed.cursor(at: $0).rotation
        return rotation <= 0 && rotation >= -.pi / 4
    })

    let straightJSON = """
    {
      "composition":{"director":{"cursorPath":"straight"}},
      "events":[{"action":"click","time":3,"coordinates":{"xNorm":0.82,"yNorm":0.2}}]
    }
    """
    let straightTimeline = try JSONDecoder().decode(Timeline.self, from: Data(straightJSON.utf8))
    let straight = NativeComposition(
        timeline: straightTimeline, size: size, contentRect: rect, sourceDuration: 6
    )
    #expect(directed.cursor(at: 2.45).point != straight.cursor(at: 2.45).point)
    #expect(directed.cursor(at: 3).point == straight.cursor(at: 3).point)
}
@Test func contentRectPreservesWideSourceAspectAndProjectsSemanticTargetsInsideIt() throws {
    let rect = aspectFittedContentRect(
        canvas: CGSize(width: 1440, height: 1050), sourceAspect: 16.0 / 9.0, scale: 0.84
    )
    #expect(abs(rect.width / rect.height - 16.0 / 9.0) < 0.0001)
    #expect(abs(rect.midX - 720) < 0.001)
    #expect(abs(rect.midY - 525) < 0.001)
    #expect(rect.width <= 1440 * 0.84 + 0.001)
    #expect(rect.height <= 1050 * 0.84 + 0.001)
    let timeline = try JSONDecoder().decode(Timeline.self, from: Data("""
    {"events":[{"action":"type_text","time":1,"semanticTarget":{"bounds":{"xNorm":0.8,"yNorm":0.8,"widthNorm":0.1,"heightNorm":0.1}}}]}
    """.utf8))
    let directed = NativeComposition(
        timeline: timeline,
        size: CGSize(width: 1440, height: 1050),
        contentRect: rect,
        sourceDuration: 3
    )
    let target = try #require(directed.actions[0].semanticBounds)
    #expect(rect.contains(CGPoint(x: target.minX, y: target.minY)))
    #expect(rect.contains(CGPoint(x: target.maxX, y: target.maxY)))
    #expect(abs(target.midX - (rect.minX + rect.width * 0.85)) < 0.001)
}

@Test func productionGraphPreservesCompetingCausalAttributions() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.42,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}},
      {"action":"click","time":2.45,"coordinates":{"xNorm":0.48,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}}
    ]
    """, duration: 8)
    let observations = [VisualMotionObservation(
        time: 2.62,
        normalizedBounds: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.25),
        changedFraction: 0.25,
        magnitude: 0.9,
        kind: .appearance
    )]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2.5...2.8]
    )
    let possibleCauses = Set(graph.attributions.filter { $0.observationID == 0 }.compactMap(\.actionID))

    #expect(possibleCauses == [0, 1])
    #expect(graph.actions.allSatisfy { $0.attention.count >= 2 })
}

@Test func productionGraphTreatsPreexistingSustainedMotionAsContextNotActionResponse() throws {
    let directed = try composition("""
    [{"action":"click","time":2.0,"coordinates":{"xNorm":0.2,"yNorm":0.2},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    """, duration: 6)
    let observations = [VisualMotionObservation(
        time: 4.0,
        normalizedBounds: CGRect(x: 0.55, y: 0.15, width: 0.3, height: 0.5),
        changedFraction: 0.08, magnitude: 0.9, kind: .transformation,
        startTime: 1.0
    )]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: observations, motionRanges: [1.0...4.0]
    )

    #expect(graph.attributions.filter { $0.observationID == 0 }.allSatisfy { $0.actionID == nil })
    #expect(graph.actions[0].attention.contains {
        $0.evidence.contains(where: { $0.source == .visualResponse })
            && $0.observationIDs.isEmpty
    })
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)
    #expect(exp(decision.pose.logScale) < 1.3)
}

@Test func productionGraphTimingHypothesesHonorObservedActivityFence() throws {
    let phases = InteractionPhases(
        rawEstimate: 4.2,
        toolStart: 3.8,
        toolEnd: 4.7,
        pointerArrival: 4.0,
        activation: 4.55,
        responseOnset: 4.9,
        source: "target-visual",
        activityThreshold: 0.5,
        preActivationActivityEnd: 4.18,
        activityClusters: [
            InteractionActivityCluster(start: 4.0, end: 4.18, peak: 2, peakTime: 4.08, count: 3),
            InteractionActivityCluster(start: 4.3, end: 4.5, peak: 3, peakTime: 4.4, count: 3)
        ]
    )
    let directed = try composition(
        """
        [{"action":"click","time":4.2,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 7,
        interactionPhases: [0: phases]
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [], motionRanges: []
    )
    let timings = try #require(graph.actions.first).timings

    #expect(!timings.isEmpty)
    #expect(timings.allSatisfy { $0.activation >= 4.23 - 0.001 })
    #expect(timings.contains { abs($0.activation - 4.3) < 0.001 })
}

@Test func sustainedResponseOnsetMakesLaterToolCompletionCausallyInfeasible() throws {
    let phases = InteractionPhases(
        rawEstimate: 7.324,
        toolStart: 3.20,
        toolEnd: 19.695,
        pointerArrival: 7.324,
        activation: 7.324,
        responseOnset: nil,
        source: "telemetry-estimate",
        activityThreshold: 0.55,
        preActivationActivityEnd: 3.452,
        activityClusters: [
            InteractionActivityCluster(
                start: 3.302, end: 3.452, peak: 8.12, peakTime: 3.302, count: 3
            ),
            InteractionActivityCluster(
                start: 14.34, end: 14.34, peak: 7.21, peakTime: 14.34, count: 1
            ),
        ]
    )
    let directed = try composition(
        """
        [{"action":"click","time":7.324,"coordinates":{"xNorm":0.13,"yNorm":0.97},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 22.3,
        interactionPhases: [0: phases]
    )
    let response = VisualMotionObservation(
        time: 14.823,
        normalizedBounds: CGRect(x: 0.05, y: 0.10, width: 0.95, height: 0.90),
        changedFraction: 0.021,
        magnitude: 0.86,
        kind: .transformation,
        startTime: 2.952
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 22.3,
        observations: [response],
        motionRanges: [2.952...14.823]
    )
    let timings = try #require(graph.actions.first).timings

    #expect(timings.contains { $0.source == "causal-response-onset" })
    #expect(timings.allSatisfy { $0.activation <= 3.281 })
    #expect(timings.allSatisfy { abs(($0.responseOnset ?? 0) - 3.20) < 0.001 })

    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)
    #expect(decision.timingSource == "causal-response-onset")
    #expect(abs(decision.activation - 3.20) < 0.001)
}

@Test func factualTimingFallbackAbstainsFromAnImpossibleEarlierResponse() throws {
    let phase = InteractionPhases(
        rawEstimate: 5,
        toolStart: 4,
        toolEnd: 5.5,
        pointerArrival: 4.8,
        activation: 5,
        responseOnset: 4,
        source: "telemetry-order-fallback",
        activityThreshold: 0.5,
        activityClusters: []
    )
    let directed = try composition(
        """
        [{"action":"click","time":5,"coordinates":{"xNorm":0.5,"yNorm":0.5}}]
        """,
        duration: 8,
        interactionPhases: [0: phase]
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: [],
        motionRanges: [],
        freezeResolvedTiming: true
    )
    let plan = ProductionPlanner.plan(
        graph: graph,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let resolved = graph.resolvedInteractionPhases(
        from: plan.decisions,
        existing: directed.interactionPhases
    )

    #expect(plan.decisions.count == 1)
    #expect(resolved[0]?.activation == 5)
    #expect(resolved[0]?.responseOnset == nil)
}

@Test func batchedComputerUseActionsCannotShareOrReverseAVisualCluster() throws {
    let sharedStart = 53.057
    let sharedEnd = 58.232
    let phases: [Int: InteractionPhases] = [
        0: InteractionPhases(
            rawEstimate: 53.489, toolStart: sharedStart, toolEnd: sharedEnd,
            pointerArrival: 57.047, activation: 57.167, responseOnset: nil,
            source: "target-visual", activityThreshold: 0.55,
            activityClusters: [InteractionActivityCluster(
                start: 57.167, end: 57.167, peak: 8.2, peakTime: 57.167, count: 1
            )]
        ),
        1: InteractionPhases(
            rawEstimate: 55.214, toolStart: sharedStart, toolEnd: sharedEnd,
            pointerArrival: 57.047, activation: 57.167, responseOnset: nil,
            source: "target-visual", activityThreshold: 0.55,
            activityClusters: [InteractionActivityCluster(
                start: 57.167, end: 57.167, peak: 8.2, peakTime: 57.167, count: 1
            )]
        ),
        2: InteractionPhases(
            rawEstimate: 56.938, toolStart: sharedStart, toolEnd: sharedEnd,
            pointerArrival: 56.507, activation: 57.107, responseOnset: nil,
            source: "target-visual", activityThreshold: 0.55,
            activityClusters: [InteractionActivityCluster(
                start: 57.107, end: 57.167, peak: 16.0, peakTime: 57.167, count: 2
            )]
        ),
    ]
    let directed = try composition(
        """
        [
          {"action":"click","time":53.489,"coordinates":{"xNorm":0.63,"yNorm":0.63},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":55.214,"coordinates":{"xNorm":0.63,"yNorm":0.63},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":56.938,"coordinates":{"xNorm":0.04,"yNorm":0.54},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 60,
        interactionPhases: phases
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 60,
        observations: [], motionRanges: []
    )
    let timings = Dictionary(uniqueKeysWithValues: graph.actions.map {
        ($0.action.id, $0.timings.map(\.activation))
    })
    let firstUpper = try #require(timings[0]?.max())
    let secondLower = try #require(timings[1]?.min())
    let secondUpper = try #require(timings[1]?.max())
    let thirdLower = try #require(timings[2]?.min())

    #expect(firstUpper < secondLower)
    #expect(secondUpper < thirdLower)
    #expect(timings[0]?.contains(57.167) == false)
    #expect(timings[1]?.contains(57.167) == false)

    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    #expect(plan.camera.diagnostics.feasible)
    #expect(plan.decisions.count == 3)
}

@Test func visualTimingCannotReverseActionsAcrossToolEnvelopes() throws {
    let clickPhase = InteractionPhases(
        rawEstimate: 8.0,
        toolStart: 7.0,
        toolEnd: 9.0,
        pointerArrival: 7.8,
        activation: 8.0,
        responseOnset: nil,
        source: "target-visual",
        activityThreshold: 0.55
    )
    let directed = try composition(
        """
        [
          {"action":"select_text","time":7.5,"semanticTarget":{"bounds":{"xNorm":0.1,"yNorm":0.2,"widthNorm":0.8,"heightNorm":0.6}}},
          {"action":"click","time":8.0,"coordinates":{"xNorm":0.85,"yNorm":0.82},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 11,
        interactionPhases: [1: clickPhase]
    )
    // This is strong enough to become the click's causal-response candidate,
    // but its onset predates the preceding recorded action. It may inform the
    // response; it may not reverse the Computer Use total order.
    let response = VisualMotionObservation(
        time: 8.1,
        normalizedBounds: CGRect(x: 0.55, y: 0.2, width: 0.35, height: 0.5),
        changedFraction: 0.18,
        magnitude: 0.9,
        kind: .transformation,
        startTime: 7.0
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 11,
        observations: [response],
        motionRanges: [7.0...8.1]
    )
    let firstActivation = graph.actions[0].timings[0].activation
    let secondTimings = graph.actions[1].timings

    #expect(secondTimings.allSatisfy { $0.activation > firstActivation })
    #expect(secondTimings.contains { abs($0.activation - 8.0) < 0.001 })
    #expect(secondTimings.contains { $0.source == "causal-response-onset" } == false)
}

@Test func productionPlannerUsesSeparateActivationAndResponsePoses() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}},
      {"action":"click","time":5.0,"coordinates":{"xNorm":0.66,"yNorm":0.62},"targetResolution":{"provenance":"direct","confidence":0.99}}
    ]
    """, duration: 8)
    let observations = [
        VisualMotionObservation(
            time: 2.3,
            normalizedBounds: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5),
            changedFraction: 0.4, magnitude: 1, kind: .focus, focusTransition: .gained
        ),
        VisualMotionObservation(
            time: 5.3,
            normalizedBounds: CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5),
            changedFraction: 0.4, magnitude: 1, kind: .focus, focusTransition: .released
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2.2...2.5, 5.2...5.5]
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let close = try #require(plan.decisions.last)

    #expect(plan.camera.diagnostics.feasible)
    #expect(exp(close.arrivalPose.logScale) > 1.1)
    #expect(abs(close.pose.logScale) < 0.001)
    #expect(plan.camera.moves.contains { $0.label.contains("focus-release") })
}

@Test func productionPlannerRetainsStructuralAlternativesBeyondCheapPoseVariants() throws {
    let phases = InteractionPhases(
        rawEstimate: 2.0,
        toolStart: 1.6,
        toolEnd: 2.5,
        pointerArrival: 1.9,
        activation: 2.0,
        responseOnset: 2.35,
        source: "target-visual",
        activityThreshold: 0.5,
        activityClusters: (0..<8).map { index in
            let start = 1.7 + Double(index) * 0.1
            return InteractionActivityCluster(
                start: start, end: start + 0.04,
                peak: 1 + Double(index), peakTime: start + 0.02, count: 2
            )
        }
    )
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.5,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 6,
        interactionPhases: [0: phases]
    )
    let observations = [VisualMotionObservation(
        time: 2.38,
        normalizedBounds: CGRect(x: 0.22, y: 0.62, width: 0.5, height: 0.34),
        changedFraction: 0.14, magnitude: 0.95, kind: .appearance
    )]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: observations, motionRanges: [2.3...2.6]
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)

    #expect(plan.camera.diagnostics.feasible)
    #expect(decision.observationIDs == [0])
}

@Test func productionPlannerUsesInformationGainToPreferSubstantialReveal() throws {
    let directed = try composition("""
    [{"action":"click","time":2.0,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    """, duration: 6)
    let observations = [
        VisualMotionObservation(
            time: 2.3,
            normalizedBounds: CGRect(x: 0.47, y: 0.47, width: 0.06, height: 0.05),
            changedFraction: 0.004, magnitude: 0.8, kind: .appearance
        ),
        VisualMotionObservation(
            time: 2.32,
            normalizedBounds: CGRect(x: 0.22, y: 0.62, width: 0.5, height: 0.34),
            changedFraction: 0.14, magnitude: 0.95, kind: .appearance
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: observations, motionRanges: [2.2...2.6]
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)

    #expect(decision.observationIDs == [1])
}

@Test func productionPlannerContextTransitionRequiresEstablishingOverview() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.12,"yNorm":0.46},"targetResolution":{"provenance":"direct","confidence":0.99}},
      {"action":"click","time":4.2,"coordinates":{"xNorm":0.48,"yNorm":0.52},"targetResolution":{"provenance":"direct","confidence":0.99}}
    ]
    """, duration: 7)
    let observations = [
        VisualMotionObservation(
            time: 2.3,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.35, magnitude: 0.95, kind: .contextTransition,
            startTime: 2.05
        ),
        VisualMotionObservation(
            time: 4.5,
            normalizedBounds: CGRect(x: 0.34, y: 0.32, width: 0.3, height: 0.32),
            changedFraction: 0.2, magnitude: 0.95, kind: .focus,
            focusTransition: .gained, startTime: 4.25
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: observations, motionRanges: [2.0...2.5, 4.2...4.7]
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let transition = try #require(plan.decisions.first)

    #expect(transition.observationIDs == [0])
    #expect(abs(transition.pose.logScale) < 0.001)
}

@Test func computerUseActionOrderCannotBeReversedByIndependentTimingEstimates() throws {
    func phase(_ activation: Double) -> InteractionPhases {
        InteractionPhases(
            rawEstimate: activation, toolStart: 3.5, toolEnd: 5.5,
            pointerArrival: activation - 0.2, activation: activation,
            responseOnset: nil, source: "target-visual"
        )
    }
    let directed = try composition(
        """
        [
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.2,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"press_key","time":4.2},
          {"action":"type_text","time":4.4,"semanticTarget":{"bounds":{"xNorm":0.1,"yNorm":0.4,"widthNorm":0.3,"heightNorm":0.08}}}
        ]
        """,
        duration: 7,
        interactionPhases: [0: phase(4.8), 1: phase(4.3), 2: phase(4.5)]
    )

    #expect(directed.actions.map(\.id) == [0, 1, 2])
    #expect(zip(directed.actions, directed.actions.dropFirst()).allSatisfy {
        $0.time < $1.time
    })
}

@Test func productionPlannerSettlesBeforeSemanticVisibilityBegins() throws {
    let directed = try composition(
        """
        [
          {"action":"set_value","time":5.0,"semanticTarget":{"bounds":{"xNorm":0.67,"yNorm":0.72,"widthNorm":0.28,"heightNorm":0.08}}}
        ]
        """,
        duration: 8
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [], motionRanges: []
    )
    // Begin in a legitimately settled prior shot that cannot show the new
    // field. The planner must travel, so this exercises the shared boundary
    // rather than passing vacuously at overview.
    let base = CameraState(x: 220, y: size.height / 2, logScale: log(1.5))
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)

    #expect(plan.camera.diagnostics.feasible)
    let secondVisibility = try #require(NativeComposition.semanticVisibilityStart(
        for: directed.actions[0]
    ))
    let secondMove = try #require(plan.camera.moves.first { $0.label == "normal-action-0" })
    #expect(secondMove.end <= directed.outputTime(atSourceTime: secondVisibility) + 0.001)
}

@Test func productionPlannerRevealsAnOffscreenFactualCursorDeparture() throws {
    let directed = try composition(
        """
        [{"action":"click","time":3.0,"coordinates":{"xNorm":0.82,"yNorm":0.82},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 6
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: [], motionRanges: []
    )
    let base = CameraState(x: 820, y: 650, logScale: log(1.58))
    let plan = ProductionPlanner.plan(graph: graph, composition: directed, base: base)
    let reveal = try #require(plan.camera.moves.first { $0.label == "normal-action-0" })
    let trip = try #require(directed.pointerTrip(forActionID: 0))

    #expect(plan.camera.diagnostics.feasible)
    #expect(reveal.end <= directed.outputTime(atSourceTime: trip.start) + 0.001)
    #expect(plan.camera.moves.count == 1)
    #expect(plan.decisions[0].arrivalPose == plan.decisions[0].pose)
}

@Test func subjectGraphGroupsPersistentFormWorkBeforeCameraPlanning() throws {
    let directed = try composition("""
    [
      {"action":"set_value","time":3.0,"semanticTarget":{"bounds":{"xNorm":0.20,"yNorm":0.70,"widthNorm":0.28,"heightNorm":0.06}}},
      {"action":"type_text","time":4.0,"semanticTarget":{"bounds":{"xNorm":0.20,"yNorm":0.70,"widthNorm":0.28,"heightNorm":0.06}}},
      {"action":"set_value","time":5.2,"semanticTarget":{"bounds":{"xNorm":0.52,"yNorm":0.70,"widthNorm":0.28,"heightNorm":0.06}}},
      {"action":"type_text","time":6.2,"semanticTarget":{"bounds":{"xNorm":0.52,"yNorm":0.70,"widthNorm":0.28,"heightNorm":0.06}}},
      {"action":"click","time":7.5,"coordinates":{"xNorm":0.72,"yNorm":0.82},"semanticTarget":{"bounds":{"xNorm":0.64,"yNorm":0.79,"widthNorm":0.16,"heightNorm":0.06}}}
    ]
    """, duration: 10)
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 10,
        observations: [],
        motionRanges: []
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let form = try #require(subjects.subjects.first { $0.kind == .surface })
    #expect(form.actionIDs == [0, 1, 2, 3, 4])

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let formShots = schedule.shots.filter { $0.subjectID == form.id }
    #expect(formShots.count == 1)
    #expect(formShots[0].intent == .frame)
    #expect(exp(formShots[0].pose.logScale) >= 1.2)
}

@Test func waitingReductionPreservesMultiActionReadabilityEvidence() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":3.0,"coordinates":{"xNorm":0.55,"yNorm":0.46},"timing":{"toolCallDurationMs":600}},
          {"action":"click","time":10.0,"coordinates":{"xNorm":0.51,"yNorm":0.68},"timing":{"toolCallDurationMs":600}},
          {"action":"click","time":11.5,"coordinates":{"xNorm":0.08,"yNorm":0.45}}
        ]
        """,
        duration: 14,
        reduceWaiting: true,
        waitingTime: 0.65,
        verifiedIdleRanges: [0...14]
    )
    let compactWorkflow = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 470, y: 230, width: 110, height: 215),
        sourceRange: 3...10.55, actionIDs: [0, 1], confidence: 0.9
    )
    let nextRegion = SubjectGraph.Subject(
        id: 1, kind: .target,
        bounds: CGRect(x: 40, y: 330, width: 80, height: 70),
        sourceRange: 11.5...12.05, actionIDs: [2], confidence: 0.9,
        requiresOverview: true
    )
    let graph = SubjectGraph(
        size: size, subjects: [compactWorkflow, nextRegion], transitions: []
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)

    var durationOnlyPolicy = ShotSchedulePlanner.Policy.default
    durationOnlyPolicy.additionalActionReadabilitySeconds = 0
    let durationOnly = ShotSchedulePlanner.plan(
        subjects: graph, composition: directed, base: base,
        policy: durationOnlyPolicy
    )
    let durationOnlyShot = try #require(durationOnly.shots.first {
        $0.subjectID == compactWorkflow.id
    })
    #expect(durationOnlyShot.intent == .overview)

    let preserved = ShotSchedulePlanner.plan(
        subjects: graph, composition: directed, base: base
    )
    let preservedShot = try #require(preserved.shots.first {
        $0.subjectID == compactWorkflow.id
    })
    #expect(preservedShot.intent == .frame)
    #expect(preservedShot.readabilityValue > 0)
    #expect(preserved.moves.contains { $0.label == "experimental-shot-0" })
}

@Test func clipGlobalShotSearchCanAmortizeOneEntryAcrossNearbyShortSubjects() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50}},
          {"action":"click","time":3.0,"coordinates":{"xNorm":0.51,"yNorm":0.51}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.52,"yNorm":0.50}}
        ]
        """,
        duration: 7
    )
    let bounds = CGRect(x: 430, y: 320, width: 140, height: 110)
    let graph = SubjectGraph(
        size: size,
        subjects: [
            .init(id: 0, kind: .target, bounds: bounds,
                  sourceRange: 2...2.55, actionIDs: [0], confidence: 0.9),
            .init(id: 1, kind: .target, bounds: bounds.offsetBy(dx: 8, dy: 6),
                  sourceRange: 3...3.55, actionIDs: [1], confidence: 0.9),
            .init(id: 2, kind: .target, bounds: bounds.offsetBy(dx: 16, dy: 0),
                  sourceRange: 4...4.55, actionIDs: [2], confidence: 0.9)
        ],
        transitions: []
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 1.50
    policy.scaleCost = 0
    policy.translationCost = 0
    policy.additionalActionReadabilitySeconds = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: graph,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )

    #expect(schedule.objectiveValue > 0)
    #expect(schedule.moves.count == 1)
    #expect(schedule.shots.filter { $0.intent == .frame }.count == 3)
    #expect(schedule.moves[0].label == "experimental-shot-0")
}

@Test func clipGlobalShotSearchRejectsUnrelatedShortSubjectsThatNeedSeparateMoves() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.10,"yNorm":0.15}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.90,"yNorm":0.85}}
        ]
        """,
        duration: 7
    )
    let graph = SubjectGraph(
        size: size,
        subjects: [
            .init(id: 0, kind: .target,
                  bounds: CGRect(x: 40, y: 60, width: 100, height: 90),
                  sourceRange: 2...2.55, actionIDs: [0], confidence: 0.9),
            .init(id: 1, kind: .target,
                  bounds: CGRect(x: 860, y: 650, width: 100, height: 90),
                  sourceRange: 4...4.55, actionIDs: [1], confidence: 0.9)
        ],
        transitions: []
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 1.50
    policy.scaleCost = 0
    policy.translationCost = 3
    policy.additionalActionReadabilitySeconds = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: graph,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )

    #expect(schedule.moves.isEmpty)
    #expect(schedule.shots.allSatisfy { $0.intent == .overview })
}

@Test func laterLocalizedRevealCanEstablishAnEarlierActionInTheSameSurface() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.55},"semanticTarget":{"bounds":{"xNorm":0.46,"yNorm":0.52,"widthNorm":0.08,"heightNorm":0.06}}},
      {"action":"click","time":16.0,"coordinates":{"xNorm":0.58,"yNorm":0.66},"semanticTarget":{"bounds":{"xNorm":0.54,"yNorm":0.63,"widthNorm":0.10,"heightNorm":0.06}}}
    ]
    """, duration: 20)
    let reveal = VisualMotionObservation(
        time: 16.45,
        normalizedBounds: CGRect(x: 0.32, y: 0.28, width: 0.38, height: 0.48),
        changedFraction: 0.14,
        magnitude: 0.95,
        kind: .appearance,
        startTime: 16.08
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 20,
        observations: [reveal], motionRanges: [16.08...16.45]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(surface.kind == .surface)
    #expect(surface.observationIDs == [0])
    #expect(surface.sourceRange.lowerBound == 2)
    #expect(surface.bounds.width > rect.width * 0.35)
    #expect(surface.requiresOverview == false)

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == surface.id })
    #expect(shot.intent == .frame)
    #expect(shot.interval.lowerBound <= directed.outputTime(atSourceTime: 2) + 0.001)
}

@Test func unresolvedBroadResponseConstrainsTheWholeSubjectToOverview() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.48,"yNorm":0.58}},
      {"action":"click","time":3.0,"coordinates":{"xNorm":0.55,"yNorm":0.58}}
    ]
    """, duration: 7)
    let broad = VisualMotionObservation(
        time: 3.5,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.30,
        magnitude: 1,
        kind: .transformation,
        startTime: 1.98
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [broad], motionRanges: [1.98...3.5]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })
    #expect(surface.requiresOverview)
    let blame = try #require(surface.overviewBlame)
    let evidence = try #require(blame.actions.first)
    #expect(evidence.actionID == 0)
    #expect(evidence.broadObservationIDs == [0])
    #expect(evidence.preexistingBroadObservationIDs.isEmpty)
    #expect(evidence.localizedObservationIDs.isEmpty)
    #expect(evidence.broadWeight > evidence.localizedWeight)
    #expect(evidence.reason == "localized-weight-below-action-aligned-broad-weight-without-verified-release")

    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == surface.id })
    #expect(shot.intent == .overview)
    #expect(exp(shot.pose.logScale) == 1)
    #expect(schedule.moves.isEmpty)
}

@Test func broadMotionAlreadyUnderwayCannotConstrainTheNextActionToOverview() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.08,"yNorm":0.50}},
      {"action":"click","time":3.0,"coordinates":{"xNorm":0.48,"yNorm":0.58}},
      {"action":"click","time":4.0,"coordinates":{"xNorm":0.55,"yNorm":0.58}}
    ]
    """, duration: 7)
    let broad = VisualMotionObservation(
        time: 3.5,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.30,
        magnitude: 1,
        kind: .transformation,
        startTime: 2.80
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [broad], motionRanges: [2.80...3.5]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let laterSurface = try #require(subjects.subjects.first { $0.actionIDs == [1, 2] })

    #expect(laterSurface.requiresOverview == false)
    #expect(laterSurface.overviewBlame == nil)

    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == laterSurface.id })
    #expect(shot.intent == .frame)
}

@Test func overviewBlameSeparatesPreexistingBroadMotionFromTheAlignedVeto() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50}}]
        """,
        duration: 6
    )
    let observations = [
        VisualMotionObservation(
            time: 2.4,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.22,
            magnitude: 0.8,
            kind: .transformation,
            startTime: 1.0
        ),
        VisualMotionObservation(
            time: 2.5,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.18,
            magnitude: 0.9,
            kind: .appearance,
            startTime: 2.05
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 6,
        observations: observations,
        motionRanges: [1...2.5]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })
    let evidence = try #require(subject.overviewBlame?.actions.first)

    #expect(subject.requiresOverview)
    #expect(evidence.broadObservationIDs == [1])
    #expect(evidence.preexistingBroadObservationIDs == [0])
}

@Test func actionResponseSlicesNeverAssignCrossBoundaryEvidenceToEitherAction() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.42,"yNorm":0.45}},
      {"action":"click","time":2.5,"coordinates":{"xNorm":0.58,"yNorm":0.45}}
    ]
    """, duration: 6)
    let evidence = [
        EpisodeVisualEvidence(
            actionID: 0, startTime: 1.92, endTime: 2.24,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.20, confidence: 0.9
        ),
        EpisodeVisualEvidence(
            actionID: -1, startTime: 2.40, endTime: 2.60,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.18, confidence: 0.8
        ),
        EpisodeVisualEvidence(
            actionID: 1, startTime: 2.44, endTime: 2.78,
            normalizedBounds: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            changedFraction: 0.12, confidence: 0.9
        ),
        EpisodeVisualEvidence(
            actionID: -1, startTime: 2.62, endTime: 2.88,
            normalizedBounds: CGRect(x: 0.30, y: 0.30, width: 0.4, height: 0.4),
            changedFraction: 0.10, confidence: 0.8
        )
    ]
    let slices = ActionResponseSlicer.make(
        actions: directed.actions,
        phases: directed.interactionPhases,
        evidence: evidence,
        sourceDuration: 6
    )
    let first = try #require(slices.first { $0.actionID == 0 })
    let second = try #require(slices.first { $0.actionID == 1 })

    #expect(first.exclusiveEvidence.map(\.id) == [0])
    #expect(first.crossBoundaryEvidence.map(\.id) == [1])
    #expect(second.exclusiveEvidence.map(\.id) == [2, 3])
    #expect(second.preexistingEvidence.map(\.id) == [1])
    let exclusiveOwners = Dictionary(grouping: slices.flatMap { slice in
        slice.exclusiveEvidence.map { ($0.id, slice.actionID) }
    }, by: \.0)
    #expect(exclusiveOwners.values.allSatisfy { $0.count == 1 })
}

@Test func crossActionAggregateCannotCreateAnOverviewVetoWhenSlicesAreLocalized() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.48,"yNorm":0.58}},
      {"action":"click","time":3.0,"coordinates":{"xNorm":0.55,"yNorm":0.58}}
    ]
    """, duration: 7)
    let aggregate = VisualMotionObservation(
        time: 4.4,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.30, magnitude: 1, kind: .transformation,
        startTime: 2.05
    )
    let slicedEvidence = [
        EpisodeVisualEvidence(
            actionID: 0, startTime: 2.02, endTime: 2.32,
            normalizedBounds: CGRect(x: 0.40, y: 0.45, width: 0.20, height: 0.20),
            changedFraction: 0.08, confidence: 0.9
        ),
        EpisodeVisualEvidence(
            actionID: -1, startTime: 2.90, endTime: 3.12,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.20, confidence: 0.9
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [aggregate], episodeVisualEvidence: slicedEvidence,
        motionRanges: [2.05...4.4]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(Set(subjects.subjects.flatMap(\.actionIDs)).isSuperset(of: [0, 1]))
    #expect(subjects.subjects.allSatisfy { $0.requiresOverview == false })
    #expect(subjects.subjects.allSatisfy { $0.overviewBlame == nil })
}

@Test func exclusivelySlicedBroadResponseStillConstrainsFraming() throws {
    let directed = try composition("""
    [{"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50}}]
    """, duration: 6)
    let broad = EpisodeVisualEvidence(
        actionID: 0, startTime: 1.94, endTime: 2.36,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.24, confidence: 0.95
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: [], episodeVisualEvidence: [broad], motionRanges: [1.94...2.36]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })
    let blame = try #require(subject.overviewBlame?.actions.first)

    #expect(subject.requiresOverview)
    #expect(blame.broadObservationIDs.isEmpty)
    #expect(blame.broadResponseEvidence.map(\.id) == [0])
    #expect(blame.causalBasis == "exclusive-action-response-slice")
}

@Test func synchronousDistributedComponentsReaggregateOnlyInsideOneActionSlice() throws {
    let directed = try composition("""
    [{"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50}}]
    """, duration: 6)
    let evidence = [
        EpisodeVisualEvidence(
            actionID: 0, startTime: 1.96, endTime: 2.28,
            normalizedBounds: CGRect(x: 0.02, y: 0.05, width: 0.42, height: 0.88),
            changedFraction: 0.12, confidence: 0.9
        ),
        EpisodeVisualEvidence(
            actionID: 0, startTime: 1.96, endTime: 2.28,
            normalizedBounds: CGRect(x: 0.56, y: 0.08, width: 0.42, height: 0.84),
            changedFraction: 0.13, confidence: 0.9
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: [], episodeVisualEvidence: evidence, motionRanges: [1.96...2.28]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })
    let blame = try #require(subject.overviewBlame?.actions.first)

    #expect(subject.requiresOverview)
    #expect(blame.broadResponseEvidence.map(\.id) == [0, 1])
}

@Test func sceneScaleResponseDoesNotReplaceCompactInteractionGeometry() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.48,"yNorm":0.42},"semanticTarget":{"bounds":{"xNorm":0.45,"yNorm":0.39,"widthNorm":0.08,"heightNorm":0.06}}},
      {"action":"click","time":3.0,"coordinates":{"xNorm":0.52,"yNorm":0.54},"semanticTarget":{"bounds":{"xNorm":0.48,"yNorm":0.51,"widthNorm":0.10,"heightNorm":0.06}}}
    ]
    """, duration: 7)
    let sceneResponse = VisualMotionObservation(
        time: 3.45,
        normalizedBounds: CGRect(x: 0.40, y: 0.03, width: 0.58, height: 0.94),
        changedFraction: 0.24,
        magnitude: 1,
        kind: .transformation,
        startTime: 3.08
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [sceneResponse], motionRanges: [3.08...3.45]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(surface.kind == .surface)
    #expect(surface.observationIDs.isEmpty)
    #expect(surface.bounds.width < rect.width * 0.25)
    #expect(surface.bounds.height < rect.height * 0.25)
}

@Test func sparseDistributedExtentCannotBecomeASceneTransitionOrSubject() throws {
    let sparse = VisualMotionObservation(
        time: 4.10,
        normalizedBounds: CGRect(x: 0, y: 0, width: 0.775, height: 1),
        changedFraction: 0.010,
        magnitude: 0.58,
        kind: .transformation,
        startTime: 3.10
    )
    let compact = VisualMotionObservation(
        time: 3.80,
        normalizedBounds: CGRect(x: 0.43, y: 0.54, width: 0.14, height: 0.26),
        changedFraction: 0.045,
        magnitude: 0.85,
        kind: .appearance,
        startTime: 3.20
    )
    let directed = try composition(
        """
        [
          {"action":"click","time":3.0},
          {"action":"click","time":6.0,"coordinates":{"xNorm":0.53,"yNorm":0.66}}
        ]
        """,
        duration: 9,
        motion: [sparse, compact]
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 9,
        observations: [sparse, compact], motionRanges: [3.10...4.10]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(subjects.transitions.isEmpty)
    #expect(surface.requiresOverview == false)
    #expect(surface.bounds.width < size.width * 0.35)
    #expect(surface.bounds.height < size.height * 0.40)
}

@Test func sustainedActionAlignedSceneResponseCreatesAnOrientationBoundary() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.48,"yNorm":0.42}},
      {"action":"click","time":3.0,"coordinates":{"xNorm":0.52,"yNorm":0.54}}
    ]
    """, duration: 7)
    let sceneResponse = VisualMotionObservation(
        time: 3.70,
        normalizedBounds: CGRect(x: 0.40, y: 0.03, width: 0.58, height: 0.94),
        changedFraction: 0.24,
        magnitude: 1,
        kind: .transformation,
        startTime: 3.05
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [sceneResponse], motionRanges: [3.05...3.70]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let transition = try #require(subjects.transitions.first)

    #expect(transition.causalActionID == 1)
    #expect(abs(transition.sourceTime - 3.05) < 0.001)
    #expect(transition.responseSubjectID == nil)

    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )
    let orient = try #require(schedule.moves.first {
        $0.label == "experimental-orient-0"
    })
    #expect(orient.end <= directed.outputTime(atSourceTime: 3.05) + 0.001)
    #expect(abs(orient.to.logScale) < 0.001)
}

@Test func singleFrameWideResponseCannotVetoReadableFactualFraming() throws {
    let directed = try composition("""
    [
      {"action":"drag","time":3.0,"coordinates":{"from":{"xNorm":0.40,"yNorm":0.50},"to":{"xNorm":0.62,"yNorm":0.50}}},
      {"action":"drag","time":3.8,"coordinates":{"from":{"xNorm":0.62,"yNorm":0.50},"to":{"xNorm":0.55,"yNorm":0.50}}}
    ]
    """, duration: 7)
    let oneFrame = VisualMotionObservation(
        time: 3.20,
        normalizedBounds: CGRect(x: 0, y: 0, width: 0.78, height: 0.96),
        changedFraction: 0.01,
        magnitude: 0.44,
        kind: .appearance,
        startTime: 3.20
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [oneFrame], motionRanges: [3.20...3.20]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(surface.requiresOverview == false)
    #expect(subjects.transitions.isEmpty)
}

@Test func inferredSurfaceReleasesBeforeTheNextFactualPointerDeparture() throws {
    let directed = try composition("""
    [
      {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.55}},
      {"action":"click","time":10.0,"coordinates":{"xNorm":0.58,"yNorm":0.66}},
      {"action":"click","time":12.0,"coordinates":{"xNorm":0.06,"yNorm":0.50}}
    ]
    """, duration: 15)
    let reveal = VisualMotionObservation(
        time: 10.45,
        normalizedBounds: CGRect(x: 0.32, y: 0.28, width: 0.38, height: 0.48),
        changedFraction: 0.14,
        magnitude: 0.95,
        kind: .appearance,
        startTime: 10.08
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 15,
        observations: [reveal], motionRanges: [10.08...10.45]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })
    let departure = try #require(directed.pointerTrip(forActionID: 2)).start
    #expect(surface.sourceRange.upperBound <= departure + 0.001)
}

@Test func interactionObjectsPreferARepeatedStableContainerOverItsStationaryTrigger() throws {
    let directed = try composition(
        """
        [
          {
            "action":"click","time":3.0,"coordinates":{"xNorm":0.72,"yNorm":0.52},
            "semanticTarget":{
              "bounds":{"xNorm":0.70,"yNorm":0.50,"widthNorm":0.04,"heightNorm":0.04},
              "interactionContainer":{
                "source":"macos-accessibility-stable-container","confidence":0.9,
                "bounds":{"xNorm":0.35,"yNorm":0.25,"widthNorm":0.42,"heightNorm":0.50},
                "verifiedThroughOffsetMs":5000
              }
            }
          },
          {
            "action":"click","time":4.2,"coordinates":{"xNorm":0.72,"yNorm":0.52},
            "semanticTarget":{
              "bounds":{"xNorm":0.70,"yNorm":0.50,"widthNorm":0.04,"heightNorm":0.04},
              "interactionContainer":{
                "source":"macos-accessibility-stable-container","confidence":0.9,
                "bounds":{"xNorm":0.35,"yNorm":0.25,"widthNorm":0.42,"heightNorm":0.50},
                "verifiedThroughOffsetMs":5000
              }
            }
          }
        ]
        """,
        duration: 8
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [], motionRanges: []
    )
    let objects = InteractionObjectGraph.make(graph: graph, composition: directed)
    let episode = try #require(objects.episodes.first { $0.actionIDs == [0, 1] })
    let selectedID = try #require(episode.selectedResponseCandidateID)
    let selected = try #require(objects.candidates.first { $0.id == selectedID })

    #expect(selected.source == .semanticContainer)
    #expect(selected.bounds.width > 400)
    #expect(selected.bounds.height > 390)
}

@Test func interactionObjectsRetainALocalizedVisualBirthDespitePageWideNoise() throws {
    let directed = try composition(
        """
        [{"action":"click","time":3.0,"coordinates":{"xNorm":0.52,"yNorm":0.55},"semanticTarget":{"bounds":{"xNorm":0.48,"yNorm":0.52,"widthNorm":0.08,"heightNorm":0.06}}}]
        """,
        duration: 8
    )
    let localized = CGRect(x: 0.20, y: 0.78, width: 0.32, height: 0.12)
    let observations = [
        VisualMotionObservation(
            time: 4.0, normalizedBounds: CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96),
            changedFraction: 0.12, magnitude: 0.9, kind: .transformation, startTime: 3.1
        ),
        VisualMotionObservation(
            time: 4.1, normalizedBounds: localized,
            changedFraction: 0.03, magnitude: 0.9, kind: .focus,
            focusTransition: .gained, startTime: 4.1
        ),
        VisualMotionObservation(
            time: 6.0, normalizedBounds: localized,
            changedFraction: 0.03, magnitude: 0.9, kind: .focus,
            focusTransition: .released, startTime: 6.0
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [3.1...6]
    )
    let objects = InteractionObjectGraph.make(graph: graph, composition: directed)
    let episode = try #require(objects.episodes.first)
    let selectedID = try #require(episode.selectedResponseCandidateID)
    let selected = try #require(objects.candidates.first { $0.id == selectedID })

    #expect(selected.source == .visualLifecycle)
    #expect(selected.bounds.width < 400)
    #expect(!objects.candidates.contains {
        $0.source == .visualResidual && $0.bounds.width > 800 && $0.bounds.height > 600
    })
}

@Test func interactionObjectsPreferACoherentMultiFrameResponseOverAWrongLifecycle() throws {
    let directed = try composition(
        """
        [{
          "action":"click","time":3.0,"coordinates":{"xNorm":0.78,"yNorm":0.72},
          "semanticTarget":{
            "bounds":{"xNorm":0.75,"yNorm":0.69,"widthNorm":0.06,"heightNorm":0.06},
            "interactionContainer":{
              "source":"macos-accessibility-stable-container","confidence":0.9,
              "bounds":{"xNorm":0.18,"yNorm":0.28,"widthNorm":0.64,"heightNorm":0.58},
              "verifiedThroughOffsetMs":5000
            }
          }
        }]
        """,
        duration: 8
    )
    // This plausible lifecycle is deliberately in the wrong part of the page.
    // It models a detector joining unrelated lower-page motion after a click.
    let wrongLifecycle = CGRect(x: 0.18, y: 0.10, width: 0.38, height: 0.24)
    let observations = [
        VisualMotionObservation(
            time: 3.35, normalizedBounds: wrongLifecycle,
            changedFraction: 0.05, magnitude: 0.9, kind: .focus,
            focusTransition: .gained, startTime: 3.35
        ),
        VisualMotionObservation(
            time: 6.0, normalizedBounds: wrongLifecycle,
            changedFraction: 0.05, magnitude: 0.9, kind: .focus,
            focusTransition: .released, startTime: 6.0
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [3.2...6.0]
    )
    let response = CGRect(x: 0.36, y: 0.82, width: 0.26, height: 0.07)
    let evidence = [
        EpisodeVisualEvidence(
            actionID: 0, startTime: 3.20, endTime: 3.40,
            normalizedBounds: response, changedFraction: 0.018, confidence: 0.8
        ),
        EpisodeVisualEvidence(
            actionID: 0, startTime: 3.40, endTime: 3.62,
            normalizedBounds: response.offsetBy(dx: 0.006, dy: 0),
            changedFraction: 0.017, confidence: 0.82
        ),
        EpisodeVisualEvidence(
            actionID: 0, startTime: 3.62, endTime: 3.86,
            normalizedBounds: response.offsetBy(dx: -0.004, dy: 0),
            changedFraction: 0.015, confidence: 0.78
        )
    ]
    let objects = InteractionObjectGraph.make(
        graph: graph,
        composition: directed,
        episodeVisualEvidence: evidence
    )
    let episode = try #require(objects.episodes.first)
    let selectedID = try #require(episode.selectedResponseCandidateID)
    let selected = try #require(objects.candidates.first { $0.id == selectedID })

    #expect(selected.source == .visualResidual)
    #expect(selected.bounds.midY < size.height * 0.25)
    #expect(selected.bounds.width < size.width * 0.35)
}

@Test func interactionObjectsRetainAVisualOnlyEpisodeWithoutInventingAnAction() throws {
    let directed = try composition("[]", duration: 8)
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [], motionRanges: [3.0...4.0]
    )
    let object = CGRect(x: 0.32, y: 0.70, width: 0.30, height: 0.16)
    let evidence = [
        EpisodeVisualEvidence(
            actionID: -1, startTime: 3.0, endTime: 3.28,
            normalizedBounds: object, changedFraction: 0.025, confidence: 0.8
        ),
        EpisodeVisualEvidence(
            actionID: -1, startTime: 3.18, endTime: 3.46,
            normalizedBounds: object.offsetBy(dx: 0.004, dy: 0),
            changedFraction: 0.024, confidence: 0.84
        ),
        EpisodeVisualEvidence(
            actionID: -1, startTime: 3.36, endTime: 3.64,
            normalizedBounds: object.offsetBy(dx: -0.003, dy: 0),
            changedFraction: 0.020, confidence: 0.78
        )
    ]
    let objects = InteractionObjectGraph.make(
        graph: graph,
        composition: directed,
        episodeVisualEvidence: evidence
    )
    let episode = try #require(objects.episodes.first)
    let selectedID = try #require(episode.selectedResponseCandidateID)
    let selected = try #require(objects.candidates.first { $0.id == selectedID })

    #expect(episode.actionIDs.isEmpty)
    #expect(episode.triggerCandidateID == nil)
    #expect(selected.actionIDs.isEmpty)
    #expect(selected.source == .visualResidual)
    #expect(selected.bounds.width > 290)
}

@Test func visualOnlyEvidenceCannotRetroactivelyHijackAnOrderedActionEpisode() throws {
    let directed = try composition(
        """
        [{
          "action":"click","time":3.0,"coordinates":{"xNorm":0.72,"yNorm":0.52},
          "semanticTarget":{
            "bounds":{"xNorm":0.69,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.06},
            "interactionContainer":{
              "source":"macos-accessibility-stable-container","confidence":0.9,
              "bounds":{"xNorm":0.34,"yNorm":0.25,"widthNorm":0.44,"heightNorm":0.50},
              "verifiedThroughOffsetMs":5000
            }
          }
        },{
          "action":"click","time":4.0,"coordinates":{"xNorm":0.72,"yNorm":0.52},
          "semanticTarget":{
            "bounds":{"xNorm":0.69,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.06},
            "interactionContainer":{
              "source":"macos-accessibility-stable-container","confidence":0.9,
              "bounds":{"xNorm":0.34,"yNorm":0.25,"widthNorm":0.44,"heightNorm":0.50},
              "verifiedThroughOffsetMs":5000
            }
          }
        }]
        """,
        duration: 8
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [], motionRanges: [3.0...4.0]
    )
    let remote = CGRect(x: 0.02, y: 0.18, width: 0.18, height: 0.45)
    let evidence = (0..<5).map { index in
        EpisodeVisualEvidence(
            actionID: -1,
            startTime: 3.1 + Double(index) * 0.18,
            endTime: 3.38 + Double(index) * 0.18,
            normalizedBounds: remote,
            changedFraction: 0.04,
            confidence: 0.9
        )
    }
    let objects = InteractionObjectGraph.make(
        graph: graph,
        composition: directed,
        episodeVisualEvidence: evidence
    )
    let actionEpisode = try #require(objects.episodes.first { $0.actionIDs == [0, 1] })
    let actionSelectedID = try #require(actionEpisode.selectedResponseCandidateID)
    let actionSelected = try #require(objects.candidates.first { $0.id == actionSelectedID })
    let visualEpisode = try #require(objects.episodes.first { $0.actionIDs.isEmpty })

    #expect(actionSelected.source == .semanticContainer)
    #expect(visualEpisode.selectedResponseCandidateID != actionSelectedID)
}

@Test func objectDiagnosticCannotDisplayACandidateBeforeItsOwnEvidenceRange() {
    let early = InteractionObjectGraph.Candidate(
        id: 0,
        source: .semanticContainer,
        bounds: CGRect(x: 100, y: 100, width: 300, height: 240),
        sourceRange: 3.0...6.0,
        actionIDs: [0],
        observationIDs: [],
        confidence: 0.9,
        causalScore: 2
    )
    let late = InteractionObjectGraph.Candidate(
        id: 1,
        source: .visualResidual,
        bounds: CGRect(x: 500, y: 100, width: 240, height: 100),
        sourceRange: 5.0...5.6,
        actionIDs: [0],
        observationIDs: [],
        confidence: 0.9,
        causalScore: 3
    )
    let episode = InteractionObjectGraph.Episode(
        id: 0,
        actionIDs: [0],
        sourceRange: 3.0...6.0,
        triggerCandidateID: nil,
        candidateIDs: [0, 1],
        selectedResponseCandidateID: 1
    )
    let objects = InteractionObjectGraph(candidates: [early, late], episodes: [episode])

    #expect(objects.activeCandidates(at: 4.0).map(\.id) == [0])
    #expect(objects.selectedCandidateIDs(at: 4.0).isEmpty)
    #expect(objects.activeCandidates(at: 5.2).map(\.id) == [0, 1])
    #expect(objects.selectedCandidateIDs(at: 5.2) == [1])
}

@Test func objectBirthAuditBlamesAVisualCandidateWithoutLocalBirthMotion() {
    let unsupported = InteractionObjectGraph.Candidate(
        id: 0,
        source: .visualResidual,
        bounds: CGRect(x: 400, y: 120, width: 260, height: 90),
        sourceRange: 4.0...4.6,
        actionIDs: [],
        observationIDs: [],
        confidence: 0.8,
        causalScore: 2
    )
    let objects = InteractionObjectGraph(
        candidates: [unsupported],
        episodes: [InteractionObjectGraph.Episode(
            id: 0,
            actionIDs: [],
            sourceRange: 4.0...4.6,
            triggerCandidateID: nil,
            candidateIDs: [0],
            selectedResponseCandidateID: 0
        )]
    )
    let unrelated = EpisodeVisualEvidence(
        actionID: -1,
        startTime: 4.0,
        endTime: 4.3,
        normalizedBounds: CGRect(x: 0.02, y: 0.02, width: 0.08, height: 0.08),
        changedFraction: 0.01,
        confidence: 0.9
    )
    let audit = ObjectBirthAudit.make(
        objects: objects,
        evidence: [unrelated],
        contentRect: rect
    )

    #expect(audit.entries.first?.status == .unsupported)
    #expect(audit.unsupportedVisualBirths.map(\.candidateID) == [0])
}

@Test func remoteActionAfterEstablishedRunStartsANewSubject() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":3.0,"coordinates":{"xNorm":0.46,"yNorm":0.53},"semanticTarget":{"bounds":{"xNorm":0.44,"yNorm":0.51,"widthNorm":0.04,"heightNorm":0.04}}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.60,"yNorm":0.57},"semanticTarget":{"bounds":{"xNorm":0.58,"yNorm":0.55,"widthNorm":0.04,"heightNorm":0.04}}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.60,"yNorm":0.68},"semanticTarget":{"bounds":{"xNorm":0.58,"yNorm":0.66,"widthNorm":0.04,"heightNorm":0.04}}},
          {"action":"click","time":6.0,"coordinates":{"xNorm":0.04,"yNorm":0.44},"semanticTarget":{"bounds":{"xNorm":0.02,"yNorm":0.42,"widthNorm":0.04,"heightNorm":0.04}}}
        ]
        """,
        duration: 9
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 9,
        observations: [],
        motionRanges: []
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(subjects.subjects.contains { $0.actionIDs == [0, 1, 2] })
    #expect(subjects.subjects.contains { $0.actionIDs == [3] })
    #expect(!subjects.subjects.contains { $0.actionIDs == [0, 1, 2, 3] })
}

@Test func laterFactualInteractionGroundsAnEarlierUnresolvedEpisodeWithoutSemanticRules() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0},
          {"action":"type_text","time":2.4},
          {
            "action":"click","time":11.5,
            "coordinates":{"xNorm":0.52,"yNorm":0.56},
            "semanticTarget":{"bounds":{"xNorm":0.50,"yNorm":0.54,"widthNorm":0.06,"heightNorm":0.05}}
          }
        ]
        """,
        duration: 15
    )
    let localRegion = CGRect(x: 0.44, y: 0.50, width: 0.16, height: 0.12)
    let observations = [
        // Scene-wide change is retained as context, but cannot supply the
        // compact subject geometry.
        VisualMotionObservation(
            time: 2.05,
            normalizedBounds: CGRect(x: 0.02, y: 0.03, width: 0.96, height: 0.92),
            changedFraction: 0.04,
            magnitude: 0.8,
            kind: .transformation,
            startTime: 2.05
        ),
        VisualMotionObservation(
            time: 2.30,
            normalizedBounds: localRegion,
            changedFraction: 0.018,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 2.06
        ),
        VisualMotionObservation(
            time: 2.68,
            normalizedBounds: localRegion.offsetBy(dx: 0.004, dy: 0),
            changedFraction: 0.014,
            magnitude: 0.72,
            kind: .transformation,
            startTime: 2.43
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 15,
        observations: observations,
        motionRanges: [2.05...2.68]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let interaction = try #require(subjects.subjects.first { $0.actionIDs == [0, 1, 2] })

    #expect(interaction.bounds.width < size.width * 0.30)
    #expect(interaction.bounds.height < size.height * 0.30)
    #expect(interaction.observationIDs.contains(1))
    #expect(interaction.observationIDs.contains(2))
    #expect(interaction.requiresOverview == false)

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == interaction.id })
    #expect(shot.intent == .frame)
    #expect(exp(shot.pose.logScale) >= ShotSchedulePlanner.Policy.default.minimumReadableScale)
}

@Test func unanchoredActionResponseSurvivesOnlyAsAFramingHypothesis() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0}]
        """,
        duration: 7
    )
    let response = VisualMotionObservation(
        time: 2.35,
        normalizedBounds: CGRect(x: 0.41, y: 0.43, width: 0.18, height: 0.14),
        changedFraction: 0.025,
        magnitude: 0.82,
        kind: .appearance,
        startTime: 2.06
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 7,
        observations: [response],
        motionRanges: [2.06...2.35]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(subject.observationIDs == [0])
    #expect(!subject.isForegroundSupport)
    #expect(subject.framingHypotheses.contains { $0.observationIDs == [0] })
    #expect(subject.sourceRange.upperBound < 3)
}

@Test func motionAlreadyUnderwayCannotBecomeAnActionsResponseHypothesis() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0}]
        """,
        duration: 6
    )
    let priorMotion = VisualMotionObservation(
        time: 2.2,
        normalizedBounds: CGRect(x: 0.41, y: 0.43, width: 0.18, height: 0.14),
        changedFraction: 0.025,
        magnitude: 0.82,
        kind: .appearance,
        startTime: 1.4
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 6,
        observations: [priorMotion],
        motionRanges: [1.4...2.2]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(!subjects.subjects.contains {
        $0.actionIDs == [0] && $0.observationIDs.contains(0)
    })
}

@Test func disconnectedActionResponsesRemainCompetingFramingHypotheses() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.39,"yNorm":0.52},"semanticTarget":{"bounds":{"xNorm":0.36,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.06}}}]
        """,
        duration: 8
    )
    let observations = [
        VisualMotionObservation(
            time: 2.35,
            normalizedBounds: CGRect(x: 0.33, y: 0.44, width: 0.14, height: 0.16),
            changedFraction: 0.02,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 2.06
        ),
        VisualMotionObservation(
            time: 2.40,
            normalizedBounds: CGRect(x: 0.65, y: 0.44, width: 0.14, height: 0.16),
            changedFraction: 0.02,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 2.08
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: observations,
        motionRanges: [2.06...2.40]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(subject.observationIDs == [0, 1])
    #expect(subject.framingHypotheses.count >= 3)
    #expect(subject.framingHypotheses.contains { $0.evidenceCoverage < 1 })
    #expect(subject.framingHypotheses.contains { $0.evidenceCoverage == 1 })
}

@Test func globalSubjectInferenceKeepsEquivalentForwardGroundedEpisodesIndependentOfPriorActivity() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0},
          {"action":"type_text","time":2.4},
          {
            "action":"click","time":11.5,
            "coordinates":{"xNorm":0.35,"yNorm":0.36},
            "semanticTarget":{"bounds":{"xNorm":0.32,"yNorm":0.33,"widthNorm":0.06,"heightNorm":0.05}}
          },
          {
            "action":"scroll","time":20.0,
            "coordinates":{"xNorm":0.67,"yNorm":0.62}
          },
          {"action":"click","time":22.0},
          {"action":"type_text","time":22.4},
          {
            "action":"click","time":31.5,
            "coordinates":{"xNorm":0.70,"yNorm":0.66},
            "semanticTarget":{"bounds":{"xNorm":0.67,"yNorm":0.63,"widthNorm":0.06,"heightNorm":0.05}}
          }
        ]
        """,
        duration: 35
    )
    let firstRegion = CGRect(x: 0.27, y: 0.29, width: 0.16, height: 0.12)
    let secondRegion = CGRect(x: 0.62, y: 0.59, width: 0.16, height: 0.12)
    let observations = [
        VisualMotionObservation(
            time: 2.30,
            normalizedBounds: firstRegion,
            changedFraction: 0.018,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 2.06
        ),
        VisualMotionObservation(
            time: 2.68,
            normalizedBounds: firstRegion.offsetBy(dx: 0.004, dy: 0),
            changedFraction: 0.014,
            magnitude: 0.72,
            kind: .transformation,
            startTime: 2.43
        ),
        // The translated interaction deliberately has no typing-aligned
        // visual observation. A previous factual action may be spatially
        // nearby, but the completed future anchor still supplies the same
        // action-independent evidence as the first episode.
        VisualMotionObservation(
            time: 22.30,
            normalizedBounds: secondRegion,
            changedFraction: 0.018,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 22.06
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 35,
        observations: observations,
        motionRanges: [2.06...2.68, 22.06...22.30]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let first = try #require(subjects.subjects.first { $0.actionIDs == [0, 1, 2] })
    let second = try #require(subjects.subjects.first { $0.actionIDs == [4, 5, 6] })

    #expect(first.bounds.width < size.width * 0.30)
    #expect(first.bounds.height < size.height * 0.30)
    #expect(second.bounds.width < size.width * 0.30)
    #expect(second.bounds.height < size.height * 0.30)
    #expect(!subjects.subjects.contains { $0.actionIDs.contains(3) && $0.actionIDs.contains(4) })

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let firstShot = try #require(schedule.shots.first { $0.subjectID == first.id })
    let secondShot = try #require(schedule.shots.first { $0.subjectID == second.id })
    #expect(firstShot.intent == .frame)
    #expect(secondShot.intent == .frame)
    #expect(abs(firstShot.pose.logScale - secondShot.pose.logScale) < 0.20)
}

@Test func subjectPartitionIsTranslationInvariantForForwardGroundedInteraction() throws {
    func subject(offsetX: Double, offsetY: Double) throws -> SubjectGraph.Subject {
        let targetX = 0.42 + offsetX
        let targetY = 0.48 + offsetY
        let directed = try composition(
            """
            [
              {"action":"click","time":2.0},
              {"action":"type_text","time":2.4},
              {
                "action":"click","time":11.5,
                "coordinates":{"xNorm":\(targetX + 0.03),"yNorm":\(targetY + 0.03)},
                "semanticTarget":{"bounds":{"xNorm":\(targetX),"yNorm":\(targetY),"widthNorm":0.06,"heightNorm":0.05}}
              }
            ]
            """,
            duration: 15
        )
        let local = VisualMotionObservation(
            time: 2.30,
            normalizedBounds: CGRect(
                x: targetX - 0.05,
                y: targetY - 0.04,
                width: 0.16,
                height: 0.12
            ),
            changedFraction: 0.018,
            magnitude: 0.8,
            kind: .appearance,
            startTime: 2.06
        )
        let graph = ProductionPlanGraph.make(
            from: directed,
            contentRect: rect,
            sourceDuration: 15,
            observations: [local],
            motionRanges: [2.06...2.30]
        )
        let subjects = SubjectGraph.make(graph: graph, composition: directed)
        return try #require(subjects.subjects.first { $0.actionIDs == [0, 1, 2] })
    }

    let upperLeft = try subject(offsetX: -0.18, offsetY: -0.16)
    let lowerRight = try subject(offsetX: 0.18, offsetY: 0.16)

    #expect(abs(upperLeft.bounds.width - lowerRight.bounds.width) < 0.001)
    #expect(abs(upperLeft.bounds.height - lowerRight.bounds.height) < 0.001)
    #expect(abs((lowerRight.bounds.midX - upperLeft.bounds.midX) - rect.width * 0.36) < 0.001)
    #expect(abs((upperLeft.bounds.midY - lowerRight.bounds.midY) - rect.height * 0.32) < 0.001)
}

@Test func forwardGroundedSubjectCannotAnticipateAnOrderedViewportScroll() throws {
    let directed = try composition(
        """
        [
          {
            "action":"scroll","time":2.0,
            "coordinates":{"xNorm":0.52,"yNorm":0.52}
          },
          {"action":"click","time":3.0},
          {"action":"type_text","time":3.4},
          {
            "action":"click","time":8.0,
            "coordinates":{"xNorm":0.56,"yNorm":0.58},
            "semanticTarget":{"bounds":{"xNorm":0.53,"yNorm":0.55,"widthNorm":0.06,"heightNorm":0.05}}
          }
        ]
        """,
        duration: 11
    )
    let local = VisualMotionObservation(
        time: 3.30,
        normalizedBounds: CGRect(x: 0.48, y: 0.51, width: 0.16, height: 0.12),
        changedFraction: 0.018,
        magnitude: 0.8,
        kind: .appearance,
        startTime: 3.06
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 11,
        observations: [local],
        motionRanges: [3.06...3.30]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let interaction = try #require(subjects.subjects.first { $0.actionIDs == [1, 2, 3] })

    #expect(interaction.framingEligibleAt == directed.actions[1].time)

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let move = try #require(schedule.moves.first {
        $0.label == "experimental-shot-\(interaction.id)"
    })
    #expect(move.start >= directed.outputTime(atSourceTime: directed.actions[1].time))
}

@Test func forwardGroundingCannotSkipANearerRemoteFactualAction() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0},
          {
            "action":"click","time":4.0,
            "coordinates":{"xNorm":0.10,"yNorm":0.12},
            "semanticTarget":{"bounds":{"xNorm":0.08,"yNorm":0.10,"widthNorm":0.05,"heightNorm":0.05}}
          },
          {
            "action":"click","time":6.0,
            "coordinates":{"xNorm":0.52,"yNorm":0.56},
            "semanticTarget":{"bounds":{"xNorm":0.50,"yNorm":0.54,"widthNorm":0.06,"heightNorm":0.05}}
          }
        ]
        """,
        duration: 9
    )
    let local = VisualMotionObservation(
        time: 2.3,
        normalizedBounds: CGRect(x: 0.44, y: 0.50, width: 0.16, height: 0.12),
        changedFraction: 0.018,
        magnitude: 0.8,
        kind: .appearance,
        startTime: 2.05
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 9,
        observations: [local],
        motionRanges: [2.05...2.3]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(!subjects.subjects.contains {
        $0.actionIDs.contains(0)
            && $0.observationIDs.contains(0)
            && $0.bounds.midX > size.width * 0.35
    })
    #expect(!subjects.subjects.contains { $0.actionIDs == [0, 1, 2] })
}

@Test func forwardGroundingAbstainsAcrossAnObservedSceneTransition() throws {
    let directed = try composition(
        """
        [
          {"action":"type_text","time":2.0},
          {
            "action":"click","time":6.0,
            "coordinates":{"xNorm":0.52,"yNorm":0.56},
            "semanticTarget":{"bounds":{"xNorm":0.50,"yNorm":0.54,"widthNorm":0.06,"heightNorm":0.05}}
          }
        ]
        """,
        duration: 9
    )
    let observations = [
        VisualMotionObservation(
            time: 2.3,
            normalizedBounds: CGRect(x: 0.44, y: 0.50, width: 0.16, height: 0.12),
            changedFraction: 0.018,
            magnitude: 0.8,
            kind: .transformation,
            startTime: 2.05
        ),
        VisualMotionObservation(
            time: 4.0,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.5,
            magnitude: 1,
            kind: .contextTransition,
            startTime: 3.8
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 9,
        observations: observations,
        motionRanges: [2.05...4.0]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(!subjects.subjects.contains {
        $0.actionIDs.contains(0) && $0.observationIDs.contains(0)
    })
}

@Test func remoteSecondActionCannotSeedACrossCanvasSubject() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":3.0,"coordinates":{"xNorm":0.04,"yNorm":0.44},"semanticTarget":{"bounds":{"xNorm":0.02,"yNorm":0.42,"widthNorm":0.04,"heightNorm":0.04}}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.60,"yNorm":0.57},"semanticTarget":{"bounds":{"xNorm":0.58,"yNorm":0.55,"widthNorm":0.04,"heightNorm":0.04}}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.60,"yNorm":0.68},"semanticTarget":{"bounds":{"xNorm":0.58,"yNorm":0.66,"widthNorm":0.04,"heightNorm":0.04}}}
        ]
        """,
        duration: 8
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: [],
        motionRanges: []
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)

    #expect(subjects.subjects.contains { $0.actionIDs == [0] })
    #expect(subjects.subjects.contains { $0.actionIDs == [1, 2] })
    #expect(!subjects.subjects.contains { $0.actionIDs == [0, 1, 2] })
}

@Test func stableInteractionContainerFramesDirectDragSubjectWithoutMovingItsPath() throws {
    let directed = try composition(
        """
        [
          {
            "action":"drag","time":3.0,
            "coordinates":{"from":{"xNorm":0.45,"yNorm":0.51},"to":{"xNorm":0.58,"yNorm":0.51}},
            "semanticTarget":{
              "role":"AXSlider",
              "bounds":{"xNorm":0.54,"yNorm":0.50,"widthNorm":0.01,"heightNorm":0.02},
              "interactionContainer":{
                "source":"macos-accessibility-stable-container","confidence":0.9,
                "bounds":{"xNorm":0.27,"yNorm":0.36,"widthNorm":0.45,"heightNorm":0.30},
                "verifiedThroughOffsetMs":5000
              }
            },
            "targetResolution":{"provenance":"direct","confidence":0.99}
          },
          {
            "action":"drag","time":5.5,
            "coordinates":{"from":{"xNorm":0.58,"yNorm":0.51},"to":{"xNorm":0.49,"yNorm":0.51}},
            "semanticTarget":{
              "role":"AXSlider",
              "bounds":{"xNorm":0.49,"yNorm":0.50,"widthNorm":0.01,"heightNorm":0.02},
              "interactionContainer":{
                "source":"macos-accessibility-stable-container","confidence":0.9,
                "bounds":{"xNorm":0.27,"yNorm":0.36,"widthNorm":0.45,"heightNorm":0.30},
                "verifiedThroughOffsetMs":3000
              }
            },
            "targetResolution":{"provenance":"direct","confidence":0.99}
          }
        ]
        """,
        duration: 8
    )
    #expect(directed.actions[0].from == CGPoint(x: 450, y: 392))
    #expect(directed.actions[0].to == CGPoint(x: 580, y: 392))
    #expect(directed.actions[0].interactionContainerBounds?.width == 450)

    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: [],
        motionRanges: []
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let dragSubject = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })
    #expect(dragSubject.bounds.width >= 450)
    #expect(dragSubject.bounds.height >= 240)

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == dragSubject.id })
    #expect(shot.intent == .frame)
}

@Test func subjectGraphKeepsMeasuredReleaseActionInsideItsForegroundSurface() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.2,"coordinates":{"xNorm":0.5,"yNorm":0.5}},
          {"action":"click","time":6.12,"coordinates":{"xNorm":0.52,"yNorm":0.56}},
          {"action":"click","time":7.0,"coordinates":{"xNorm":0.08,"yNorm":0.7}}
        ]
        """,
        duration: 10
    )
    let focus = CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.45)
    let observations = [
        VisualMotionObservation(
            time: 2,
            normalizedBounds: focus,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .gained,
            startTime: 2
        ),
        VisualMotionObservation(
            time: 6,
            normalizedBounds: focus,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .released,
            startTime: 6
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 10,
        observations: observations,
        motionRanges: [2...6],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle(
            bounds: focus,
            gainedAt: 2,
            releasedAt: 6,
            gainedObservationID: 0,
            releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first {
        $0.kind == .surface && $0.observationIDs == [0, 1]
    })

    #expect(foreground.actionIDs == [0, 1])
    #expect(!foreground.actionIDs.contains(2))
}

@Test func subjectGraphAssignsAnExternalTriggerToTheSurfaceItCausallyCreates() throws {
    let phase = InteractionPhases(
        rawEstimate: 3,
        toolStart: 2.5,
        toolEnd: 3.6,
        pointerArrival: 2.9,
        activation: 3,
        responseOnset: 3.2,
        source: "causal-response-onset"
    )
    let directed = try composition(
        """
        [{"action":"click","time":3,"coordinates":{"xNorm":0.8,"yNorm":0.8}}]
        """,
        duration: 8,
        interactionPhases: [0: phase]
    )
    let support = CGRect(x: 0.1, y: 0.1, width: 0.25, height: 0.4)
    let observations = [
        VisualMotionObservation(
            time: 3.2,
            normalizedBounds: support,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .gained,
            startTime: 3.2
        ),
        VisualMotionObservation(
            time: 6,
            normalizedBounds: support,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .released,
            startTime: 6
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: observations,
        motionRanges: [3.2...6],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle(
            bounds: support,
            gainedAt: 3.2,
            releasedAt: 6,
            gainedObservationID: 0,
            releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first {
        $0.kind == .surface && $0.observationIDs == [0, 1]
    })

    #expect(foreground.actionIDs == [0])
    #expect(foreground.isForegroundSupport)
    #expect(foreground.verifiedReleaseTime == 6)
    #expect(abs(foreground.bounds.midX - 225) < 0.001)
    #expect(foreground.framingEligibleAt == 3.2)
}

@Test func subjectGraphPreservesSmallVerifiedSupportForGlobalScheduling() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.75,"yNorm":0.75}}]
        """,
        duration: 7
    )
    // This is deliberately below the old output-area cutoff. A verified fact
    // must reach ShotSchedule, which owns the readability/travel decision.
    let support = CGRect(x: 0.08, y: 0.82, width: 0.08, height: 0.05)
    let observations = [
        VisualMotionObservation(
            time: 2.2, normalizedBounds: support, changedFraction: 0.01,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 2.2
        ),
        VisualMotionObservation(
            time: 4.4, normalizedBounds: support, changedFraction: 0.01,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 4.4
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: observations, motionRanges: [2.2...4.4],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [.init(
            bounds: support, gainedAt: 2.2, releasedAt: 4.4,
            gainedObservationID: 0, releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first { $0.isForegroundSupport })

    #expect(foreground.actionIDs == [0])
    #expect(foreground.framingEligibleAt == 2.2)
}

@Test func nestedVerifiedLifecyclesMayShareTheirFactualAction() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.2,"yNorm":0.5}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.5,"yNorm":0.5}},
          {"action":"click","time":6.0,"coordinates":{"xNorm":0.52,"yNorm":0.52}}
        ]
        """,
        duration: 9
    )
    let parent = CGRect(x: 0.3, y: 0.25, width: 0.4, height: 0.5)
    let child = CGRect(x: 0.44, y: 0.4, width: 0.2, height: 0.2)
    let observations = [
        VisualMotionObservation(
            time: 2.2, normalizedBounds: parent, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 2.2
        ),
        VisualMotionObservation(
            time: 7.0, normalizedBounds: parent, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 7.0
        ),
        VisualMotionObservation(
            time: 3.8, normalizedBounds: child, changedFraction: 0.05,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 3.8
        ),
        VisualMotionObservation(
            time: 5.5, normalizedBounds: child, changedFraction: 0.05,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 5.5
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 9,
        observations: observations, motionRanges: [2.2...7.0],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1, 2, 3],
        oracleSupportLifecycles: [
            .init(
                bounds: parent, gainedAt: 2.2, releasedAt: 7,
                gainedObservationID: 0, releasedObservationID: 1
            ),
            .init(
                bounds: child, gainedAt: 3.8, releasedAt: 5.5,
                gainedObservationID: 2, releasedObservationID: 3
            )
        ]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = subjects.subjects.filter(\.isForegroundSupport)

    #expect(foreground.count == 2)
    #expect(foreground.allSatisfy { $0.actionIDs.contains(1) })
}

@Test func foregroundShotWaitsForTheFactualCursorToEnterAnOutsideTriggeredSurface() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.85,"yNorm":0.2}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.5,"yNorm":0.5}},
          {"action":"click","time":6.0,"coordinates":{"xNorm":0.52,"yNorm":0.52}},
          {"action":"click","time":7.0,"coordinates":{"xNorm":0.54,"yNorm":0.54}}
        ]
        """,
        duration: 9
    )
    let support = CGRect(x: 0.35, y: 0.25, width: 0.3, height: 0.5)
    let observations = [
        VisualMotionObservation(
            time: 2, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 2
        ),
        VisualMotionObservation(
            time: 8, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 8
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 9,
        observations: observations, motionRanges: [2...8],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [.init(
            bounds: support, gainedAt: 2, releasedAt: 8,
            gainedObservationID: 0, releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first { $0.isForegroundSupport })
    let entry = try #require(foreground.framingEligibleAt)
    let trip = try #require(directed.pointerTrip(forActionID: 1))

    #expect(entry > trip.start)
    #expect(entry < trip.end)

    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.minimumReadableScale = 1.01
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )
    let move = try #require(schedule.moves.first { $0.label.hasPrefix("experimental-shot-") })
    #expect(move.start >= directed.outputTime(atSourceTime: entry))
}

@Test func verifiedTransientForegroundCanProduceAReadableCursorLedShotWhenValuable() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.8,"yNorm":0.2}},
          {"action":"click","time":4.8,"coordinates":{"xNorm":0.55,"yNorm":0.55}}
        ]
        """,
        duration: 6
    )
    let support = CGRect(x: 0.42, y: 0.35, width: 0.25, height: 0.35)
    let observations = [
        VisualMotionObservation(
            time: 2, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 2
        ),
        VisualMotionObservation(
            time: 5, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 5
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 6,
        observations: observations, motionRanges: [2...5],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [.init(
            bounds: support, gainedAt: 2, releasedAt: 5,
            gainedObservationID: 0, releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first { $0.isForegroundSupport })
    let trip = try #require(directed.pointerTrip(forActionID: 1))
    let entry = try #require(foreground.framingEligibleAt)
    #expect(entry == 2)
    #expect(trip.start > entry)

    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )
    let shot = try #require(schedule.shots.first { $0.subjectID == foreground.id })
    #expect(shot.intent == .frame)
}

@Test func subjectGraphCombinesLocalizedRevealTilesWithTheirFactualTrigger() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.55,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 8
    )
    let observations = [
        VisualMotionObservation(
            time: 2.45, normalizedBounds: CGRect(x: 0.35, y: 0.35, width: 0.2, height: 0.15),
            changedFraction: 0.08, magnitude: 0.9, kind: .appearance, startTime: 2.45
        ),
        VisualMotionObservation(
            time: 2.45, normalizedBounds: CGRect(x: 0.55, y: 0.35, width: 0.2, height: 0.15),
            changedFraction: 0.08, magnitude: 0.9, kind: .appearance, startTime: 2.45
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2.4...2.6]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let reveal = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(reveal.kind == .surface)
    #expect(reveal.observationIDs == [0, 1])
    #expect(reveal.bounds.width > 380)
    #expect(reveal.sourceRange.upperBound >= 4.85)
}

@Test func subjectGraphDoesNotTurnDisappearanceIntoAReveal() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.55,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 8
    )
    let observation = VisualMotionObservation(
        time: 2.45,
        normalizedBounds: CGRect(x: 0.35, y: 0.35, width: 0.4, height: 0.15),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .vanish,
        startTime: 2.20
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [observation], motionRanges: [2.2...2.45]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let target = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(target.kind == .target)
    #expect(target.observationIDs.isEmpty)
}

@Test func unverifiedFocusCannotEraseACoexistingStructuralReveal() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 7
    )
    let reveal = VisualMotionObservation(
        time: 2.45,
        normalizedBounds: CGRect(x: 0.38, y: 0.36, width: 0.24, height: 0.22),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .appear,
        startTime: 2.10
    )
    let unverifiedFocus = VisualMotionObservation(
        time: 2.45,
        normalizedBounds: CGRect(x: 0.30, y: 0.25, width: 0.40, height: 0.50),
        changedFraction: 0.20,
        magnitude: 0.9,
        kind: .focus,
        focusTransition: .held,
        startTime: 2.45
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 7,
        observations: [reveal, unverifiedFocus], motionRanges: [2.1...2.45]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(subject.observationIDs.contains(0))
    #expect(subject.isForegroundSupport == false)
}

@Test func localizedDisappearanceClosesABackwardVerifiedSurface() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.52,"yNorm":0.55},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 8
    )
    let broadBirth = VisualMotionObservation(
        time: 2.7,
        normalizedBounds: CGRect(x: 0, y: 0, width: 0.96, height: 1),
        changedFraction: 0.012,
        magnitude: 0.7,
        kind: .transformation,
        startTime: 2.1
    )
    let release = VisualMotionObservation(
        time: 5.35,
        normalizedBounds: CGRect(x: 0.35, y: 0.30, width: 0.30, height: 0.40),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .vanish,
        startTime: 5.10
    )
    let closingTransition = VisualMotionObservation(
        time: 5.0,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.2,
        magnitude: 0.9,
        kind: .contextTransition,
        startTime: 5.0
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [broadBirth, release, closingTransition],
        motionRanges: [2.1...2.7, 5.0...5.35]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(surface.kind == .surface)
    #expect(surface.observationIDs.contains(1))
    #expect(surface.requiresOverview == false)
    #expect(surface.sourceRange.upperBound < 6)
    #expect(surface.verifiedReleaseTime == 5.0)
}

@Test func heldEnclosingFocusVetoesAPartialDisappearanceRelease() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.52,"yNorm":0.55},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 8
    )
    let partialDisappearance = VisualMotionObservation(
        time: 5.35,
        normalizedBounds: CGRect(x: 0.43, y: 0.42, width: 0.16, height: 0.18),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .vanish,
        startTime: 5.10
    )
    let heldEnclosingFocus = VisualMotionObservation(
        time: 5.35,
        normalizedBounds: CGRect(x: 0.30, y: 0.25, width: 0.40, height: 0.50),
        changedFraction: 0.2,
        magnitude: 0.9,
        kind: .focus,
        focusTransition: .held,
        startTime: 5.35
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [partialDisappearance, heldEnclosingFocus],
        motionRanges: [5.1...5.35]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0, 1] })

    #expect(subject.verifiedReleaseTime == nil)
    #expect(subject.observationIDs.contains(0))
}

@Test func laterOwnedActionVetoesAnEarlierNestedDisappearanceRelease() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.52,"yNorm":0.55},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":7.0,"coordinates":{"xNorm":0.54,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 10
    )
    let nestedDisappearance = VisualMotionObservation(
        time: 5.35,
        normalizedBounds: CGRect(x: 0.43, y: 0.42, width: 0.16, height: 0.18),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .vanish,
        startTime: 5.10
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 10,
        observations: [nestedDisappearance],
        motionRanges: [5.1...5.35]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let subject = try #require(subjects.subjects.first { $0.actionIDs == [0, 1, 2] })

    #expect(subject.kind == .surface)
    #expect(subject.verifiedReleaseTime == nil)
}

@Test func requiredObservationCoverageIsReservedBeforeBeamCostFilling() {
    let required: Set<Int> = [41, 73]
    let coverages = Array(repeating: Set<Int>(), count: 200) + [
        Set([41]), Set([73]), Set([41, 73])
    ]
    let reserved = RequiredObservationBeamPolicy.reservationIndices(
        coverages: coverages,
        required: required,
        width: 160
    )

    #expect(reserved.contains(202))
    #expect(reserved.contains(200))
    #expect(reserved.contains(201))
    #expect(reserved.contains(0))
}

@Test func backwardVerifiedSurfaceFramesAfterItsEstablishingTransition() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":4.0,"coordinates":{"xNorm":0.53,"yNorm":0.53},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":6.0,"coordinates":{"xNorm":0.52,"yNorm":0.55},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 9
    )
    let establishingTransition = VisualMotionObservation(
        time: 2.0,
        normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        changedFraction: 0.25,
        magnitude: 1,
        kind: .contextTransition,
        startTime: 2.0
    )
    let release = VisualMotionObservation(
        time: 6.35,
        normalizedBounds: CGRect(x: 0.35, y: 0.30, width: 0.30, height: 0.40),
        changedFraction: 0.08,
        magnitude: 0.9,
        kind: .appearance,
        polarity: .vanish,
        startTime: 6.10
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 9,
        observations: [establishingTransition, release],
        motionRanges: [2.0...2.2, 6.1...6.35]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let surface = try #require(subjects.subjects.first { $0.actionIDs == [0, 1, 2] })
    let eligibleAt = try #require(surface.framingEligibleAt)

    #expect(eligibleAt > 2.0)
    #expect(eligibleAt <= 4.0)
    #expect(surface.verifiedReleaseTime == 6.0)
}

@Test func subjectGraphDoesNotTurnPreexistingAnimationIntoAnActionReveal() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.0,"coordinates":{"xNorm":0.55,"yNorm":0.45},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 8
    )
    let observations = [VisualMotionObservation(
        time: 2.45, normalizedBounds: CGRect(x: 0.35, y: 0.35, width: 0.4, height: 0.15),
        changedFraction: 0.08, magnitude: 0.9, kind: .transformation, startTime: 1.0
    )]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [1.0...2.6]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let target = try #require(subjects.subjects.first { $0.actionIDs == [0] })

    #expect(target.kind == .target)
    #expect(target.observationIDs.isEmpty)
    #expect(target.sourceRange.upperBound < 3)
}

@Test func subjectGraphKeepsActionsWithinOneFrameOfForegroundBirthInTheOwner() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":1.5,"coordinates":{"xNorm":0.8,"yNorm":0.8}},
          {"action":"click","time":1.999999,"coordinates":{"xNorm":0.5,"yNorm":0.25}},
          {"action":"click","time":6.01,"coordinates":{"xNorm":0.52,"yNorm":0.52}}
        ]
        """,
        duration: 8
    )
    let support = CGRect(x: 0.35, y: 0.3, width: 0.3, height: 0.4)
    let observations = [
        VisualMotionObservation(
            time: 2, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .gained, startTime: 2
        ),
        VisualMotionObservation(
            time: 6, normalizedBounds: support, changedFraction: 0.1,
            magnitude: 1, kind: .focus, focusTransition: .released, startTime: 6
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2...6],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [.init(
            bounds: support, gainedAt: 2, releasedAt: 6,
            gainedObservationID: 0, releasedObservationID: 1
        )]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let foreground = try #require(subjects.subjects.first { $0.isForegroundSupport })

    #expect(foreground.actionIDs.contains(1))
    #expect(foreground.actionIDs.contains(2))
    #expect(foreground.sourceRange.lowerBound > 1.9)
}

@Test func shotScheduleValuesMeasuredSurfaceLifetimeInsteadOfSingleClickHold() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.2,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 20
    )
    let surface = SubjectGraph.Subject(
        id: 0,
        kind: .surface,
        bounds: CGRect(x: 350, y: 220, width: 300, height: 300),
        sourceRange: 2...17,
        actionIDs: [0],
        confidence: 1
    )
    let subjects = SubjectGraph(size: size, subjects: [surface], transitions: [])
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let shot = try #require(schedule.shots.first)

    #expect(shot.intent == .frame)
    #expect(exp(shot.pose.logScale) >= 1.2)
    #expect(abs(shot.interval.lowerBound - directed.outputTime(atSourceTime: 2)) < 0.001)
    #expect(abs(shot.interval.upperBound - directed.outputTime(atSourceTime: 17)) < 0.001)
}

@Test func briefVerifiedPeripheralSubjectDoesNotForceAnUnreadableCameraMove() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.2,"coordinates":{"xNorm":0.82,"yNorm":0.75}}]
        """,
        duration: 6
    )
    let subject = SubjectGraph.Subject(
        id: 0,
        kind: .surface,
        bounds: CGRect(x: 690, y: 570, width: 180, height: 90),
        sourceRange: 2...3,
        actionIDs: [0],
        confidence: 1,
        framingEligibleAt: 2,
        isForegroundSupport: true,
        verifiedReleaseTime: 3
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [subject], transitions: []),
        composition: directed, base: base
    )
    let shot = try #require(schedule.shots.first)

    #expect(shot.intent == .overview)
    #expect(shot.pose == base)
    #expect(schedule.moves.isEmpty)
}

@Test func shotScheduleReturnsOnlyAfterVerifiedForegroundRelease() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.2,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 9
    )
    let surface = SubjectGraph.Subject(
        id: 0,
        kind: .surface,
        bounds: CGRect(x: 350, y: 220, width: 300, height: 300),
        sourceRange: 2...6,
        actionIDs: [0],
        confidence: 1,
        isForegroundSupport: true,
        verifiedReleaseTime: 6
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    policy.minimumReadableScale = 1.01
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [surface], transitions: []),
        composition: directed,
        base: base,
        policy: policy
    )
    let release = try #require(schedule.moves.first {
        $0.label == "experimental-release-0"
    })

    #expect(release.start >= directed.outputTime(atSourceTime: 6))
    #expect(abs(release.to.x - base.x) < 0.001)
    #expect(abs(release.to.y - base.y) < 0.001)
    #expect(abs(release.to.logScale - base.logScale) < 0.001)
}

@Test func shotScheduleRestoresAnActiveParentWhenNestedForegroundReleases() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.2,"coordinates":{"xNorm":0.5,"yNorm":0.5}},
          {"action":"click","time":4.2,"coordinates":{"xNorm":0.58,"yNorm":0.58}}
        ]
        """,
        duration: 10
    )
    let parent = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 300, y: 200, width: 400, height: 360),
        sourceRange: 2...8, actionIDs: [0], confidence: 1,
        isForegroundSupport: true, verifiedReleaseTime: 8
    )
    let child = SubjectGraph.Subject(
        id: 1, kind: .surface,
        bounds: CGRect(x: 500, y: 360, width: 180, height: 140),
        sourceRange: 4...6, actionIDs: [1], confidence: 1,
        isForegroundSupport: true, verifiedReleaseTime: 6
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.minimumReadableScale = 1.01
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [parent, child], transitions: []),
        composition: directed, base: base, policy: policy
    )
    let parentShot = try #require(schedule.shots.first { $0.subjectID == parent.id })
    let childShot = try #require(schedule.shots.first { $0.subjectID == child.id })
    let parentRelease = try #require(schedule.moves.first {
        $0.label == "experimental-release-0"
    })

    #expect(childShot.pose == parentShot.pose)
    #expect(!schedule.moves.contains { $0.label == "experimental-shot-1" })
    #expect(!schedule.moves.contains { $0.label == "experimental-release-1" })
    #expect(abs(parentRelease.to.logScale - base.logScale) < 0.001)
}

@Test func simultaneousNestedReleasesReturnToOverviewInsteadOfRestoringExpiredParent() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.2,"coordinates":{"xNorm":0.4,"yNorm":0.5}},
          {"action":"click","time":4.2,"coordinates":{"xNorm":0.5,"yNorm":0.5}}
        ]
        """,
        duration: 9
    )
    let parent = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 280, y: 200, width: 420, height: 360),
        sourceRange: 2...6, actionIDs: [0, 1], confidence: 1,
        isForegroundSupport: true, verifiedReleaseTime: 6
    )
    let child = SubjectGraph.Subject(
        id: 1, kind: .surface,
        bounds: CGRect(x: 460, y: 330, width: 190, height: 150),
        sourceRange: 4...6, actionIDs: [1], confidence: 1,
        isForegroundSupport: true, verifiedReleaseTime: 6
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.minimumReadableScale = 1.01
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [parent, child], transitions: []),
        composition: directed, base: base, policy: policy
    )
    let release = try #require(schedule.moves.last)

    #expect(release.label.hasPrefix("experimental-release-"))
    #expect(abs(release.to.x - base.x) < 0.001)
    #expect(abs(release.to.y - base.y) < 0.001)
    #expect(abs(release.to.logScale - base.logScale) < 0.001)
}

@Test func nestedForegroundReframesWhenTheParentCannotComfortablyShowIt() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.25,"yNorm":0.5}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.82,"yNorm":0.5}}
        ]
        """,
        duration: 10
    )
    let parent = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 100, y: 220, width: 320, height: 320),
        sourceRange: 2...9, actionIDs: [0], confidence: 1
    )
    let child = SubjectGraph.Subject(
        id: 1, kind: .surface,
        bounds: CGRect(x: 760, y: 300, width: 180, height: 180),
        sourceRange: 5...8, actionIDs: [1], confidence: 1,
        framingEligibleAt: 5, isForegroundSupport: true,
        verifiedReleaseTime: 8
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    policy.minimumReadableScale = 1.01
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [parent, child], transitions: []),
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )

    #expect(schedule.moves.contains { $0.label == "experimental-shot-1" })
}

@Test func rejectedNestedCloseupKeepsTheActiveParentInsteadOfZoomingOut() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.5,"yNorm":0.5}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.58,"yNorm":0.58}}
        ]
        """,
        duration: 10
    )
    let parent = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 300, y: 200, width: 400, height: 360),
        sourceRange: 2...9, actionIDs: [0], confidence: 1
    )
    let child = SubjectGraph.Subject(
        id: 1, kind: .surface,
        bounds: CGRect(x: 500, y: 360, width: 180, height: 140),
        sourceRange: 5...5.25, actionIDs: [1], confidence: 1
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [parent, child], transitions: []),
        composition: directed, base: base, policy: policy
    )
    let parentShot = try #require(schedule.shots.first { $0.subjectID == 0 })
    let childShot = try #require(schedule.shots.first { $0.subjectID == 1 })

    #expect(parentShot.intent == .frame)
    #expect(childShot.pose == parentShot.pose)
    #expect(!schedule.moves.contains {
        $0.start >= childShot.interval.lowerBound && abs($0.to.logScale) < 0.001
    })
}

@Test func shotScheduleDoesNotInventReleaseFromUnverifiedSubjectTiming() throws {
    let directed = try composition(
        """
        [{"action":"click","time":2.2,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 9
    )
    let surface = SubjectGraph.Subject(
        id: 0,
        kind: .surface,
        bounds: CGRect(x: 350, y: 220, width: 300, height: 300),
        sourceRange: 2...6,
        actionIDs: [0],
        confidence: 1
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.minimumReadableScale = 1.01
    let schedule = ShotSchedulePlanner.plan(
        subjects: SubjectGraph(size: size, subjects: [surface], transitions: []),
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0),
        policy: policy
    )

    #expect(!schedule.moves.contains { $0.label.hasPrefix("experimental-release-") })
}

@Test func factualOnlyDragCannotInventASecondResponsePose() throws {
    let directed = try composition(
        """
        [{"action":"drag","time":3.0,"coordinates":{"from":{"xNorm":0.35,"yNorm":0.5},"to":{"xNorm":0.65,"yNorm":0.5}},"targetResolution":{"provenance":"direct","confidence":0.99}}]
        """,
        duration: 6
    )
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 6,
        observations: [],
        motionRanges: []
    )
    let plan = ProductionPlanner.plan(
        graph: graph,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    let decision = try #require(plan.decisions.first)

    #expect(plan.camera.diagnostics.feasible)
    #expect(decision.arrivalPose == decision.pose)
    #expect(!plan.camera.moves.contains { $0.label.hasSuffix("-response") })
}

@Test func subjectGraphSeparatesOrientationFromLocalizedTransitionResponse() throws {
    let observations = [
        VisualMotionObservation(
            time: 3.6,
            normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            changedFraction: 0.62,
            magnitude: 0.9,
            kind: .contextTransition,
            startTime: 3.2
        ),
        VisualMotionObservation(
            time: 3.7,
            normalizedBounds: CGRect(x: 0.22, y: 0.48, width: 0.56, height: 0.28),
            changedFraction: 0.16,
            magnitude: 0.85,
            kind: .appearance,
            startTime: 3.25
        )
    ]
    let directed = try composition("""
    [{"action":"click","time":3.0,"coordinates":{"xNorm":0.82,"yNorm":0.18}}]
    """, duration: 8, motion: observations)
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: observations,
        motionRanges: [3.2...3.8]
    )
    let subjects = SubjectGraph.make(graph: graph, composition: directed)
    let transition = try #require(subjects.transitions.first)
    let responseID = try #require(transition.responseSubjectID)
    #expect(subjects.subjects.first { $0.id == responseID }?.kind == .response)

    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    )
    #expect(schedule.shots.contains { $0.intent == .orient })
    #expect(schedule.shots.contains { $0.intent == .pushIn && $0.subjectID == responseID })
}

@Test func cameraTrackIsAFirstClassTrajectoryOverride() throws {
    let base = CameraState(x: 500, y: 400, logScale: 0)
    let plan = CameraPlan(
        moves: [CameraMove(
            label: "editorial", start: 1, end: 3,
            from: base, to: CameraState(x: 700, y: 500, logScale: log(1.4))
        )],
        tracks: [CameraTrack(label: "track", keyframes: [
            .init(time: 1.5, state: CameraState(x: 540, y: 420, logScale: log(1.1))),
            .init(time: 2.0, state: CameraState(x: 620, y: 460, logScale: log(1.2))),
            .init(time: 2.5, state: CameraState(x: 680, y: 490, logScale: log(1.3)))
        ])],
        diagnostics: CameraPlanDiagnostics(plannerVersion: "experimental-test", feasible: true)
    )
    let tracked = cameraState(at: 2.0, plan: plan, base: base)
    #expect(abs(tracked.x - 620) < 0.001)
    #expect(abs(exp(tracked.logScale) - 1.2) < 0.001)
    let editorial = cameraState(at: 1.25, plan: plan, base: base)
    #expect(editorial != base)
}

@Test func overlappingShotIntervalsSelectTheLatestStartedOwner() throws {
    let base = CameraState(x: 500, y: 400, logScale: 0)
    let older = ShotSchedule.Shot(
        id: 2, subjectID: 10, intent: .overview, interval: 2...12,
        pose: base, actionIDs: [0], readabilityValue: 0
    )
    let newer = ShotSchedule.Shot(
        id: 3, subjectID: 11, intent: .frame, interval: 6...10,
        pose: CameraState(x: 620, y: 430, logScale: log(1.4)),
        actionIDs: [1], readabilityValue: 1
    )
    let schedule = ShotSchedule(shots: [newer, older], moves: [])

    #expect(schedule.selectedShot(at: 4)?.subjectID == 10)
    #expect(schedule.selectedShot(at: 8)?.subjectID == 11)
    #expect(schedule.selectedShot(at: 13) == nil)
}

@Test func overviewShotSettlesBeforeFactualPointerDeparture() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.08,"yNorm":0.12},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":7.0,"coordinates":{"xNorm":0.92,"yNorm":0.88},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 10
    )
    let size = directed.size
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let subjects = SubjectGraph(
        size: size,
        subjects: [
            .init(
                id: 0, kind: .surface,
                bounds: CGRect(x: 40, y: 50, width: 140, height: 120),
                sourceRange: 2...4, actionIDs: [0], confidence: 0.9
            ),
            .init(
                id: 1, kind: .target,
                bounds: CGRect(origin: .zero, size: size),
                sourceRange: 7...7.55, actionIDs: [1], confidence: 0.9
            )
        ],
        transitions: []
    )
    var policy = ShotSchedulePlanner.Policy.default
    policy.moveCost = 0
    policy.scaleCost = 0
    policy.translationCost = 0
    policy.minimumReadableScale = 1.01
    let schedule = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed, base: base, policy: policy
    )
    let trip = try #require(directed.pointerTrip(forActionID: 1))
    let departure = directed.outputTime(atSourceTime: trip.start)
    let returnMove = try #require(schedule.moves.last { abs($0.to.logScale) < 0.001 })
    #expect(returnMove.end <= departure + 0.000_001)
}

@Test func globalRetimeProtectsTheCompleteFactualPointerTrip() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.1,"yNorm":0.1},"targetResolution":{"provenance":"direct","confidence":0.99}},
          {"action":"click","time":7.0,"coordinates":{"xNorm":0.9,"yNorm":0.9},"targetResolution":{"provenance":"direct","confidence":0.99}}
        ]
        """,
        duration: 10
    )
    let trip = try #require(directed.pointerTrip(forActionID: 1))
    #expect(trip.start < directed.actions[1].time - 0.82)
    let protected = directed.protectedPointerTravelRanges(sourceDuration: 10)
    let retime = GlobalRetimePlanner.plan(
        actions: directed.actions,
        sourceDuration: 10,
        motionRanges: [],
        protectedInteractionRanges: protected,
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )
    let covering = retime.filter {
        $0.sourceEnd > trip.start && $0.sourceStart < trip.end
    }
    #expect(!covering.isEmpty)
    #expect(covering.allSatisfy { $0.rate == 1 })
    #expect(covering.first?.sourceStart ?? .infinity <= trip.start)
    #expect(covering.last?.sourceEnd ?? -.infinity >= trip.end)
}

@Test func globalRetimePlannerUsesOneEvidencePartition() throws {
    let directed = try composition("""
    [{"action":"click","time":5.0,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    """, duration: 12)
    let retime = GlobalRetimePlanner.plan(
        actions: directed.actions,
        sourceDuration: 12,
        motionRanges: [8...10],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )

    #expect(retime.contains { $0.sourceStart <= 5 && $0.sourceEnd >= 5 && $0.rate == 1 })
    #expect(retime.contains { $0.sourceStart <= 8 && $0.sourceEnd >= 10 && $0.rate == 6 })
    #expect(retime.reduce(0) { $0 + $1.outputDuration } < 7)
}

@Test func globalRetimeStartsOneSecondBeforeFirstPointerMovementWhenOpeningIsProvenIdle() {
    let retime = GlobalRetimePlanner.plan(
        actions: [],
        sourceDuration: 10,
        motionRanges: [],
        verifiedIdleRanges: [0...5],
        firstPointerMovementTime: 5,
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )

    #expect(abs((retime.first?.sourceStart ?? -1) - 4) < 0.000_001)
    #expect(retime.first?.sourceEnd ?? 0 >= 5)
    #expect(retime.first?.rate == 1)
    let pointerOutputTime = retime.reduce(0.0) { output, segment in
        guard segment.sourceStart < 5 else { return output }
        return output + (min(5, segment.sourceEnd) - segment.sourceStart) / segment.rate
    }
    #expect(abs(pointerOutputTime - 1) < 0.000_001)
}

@Test func globalRetimePreservesOpeningWhenLeadingIdleIsNotProven() {
    let unverified = GlobalRetimePlanner.plan(
        actions: [], sourceDuration: 10, motionRanges: [],
        verifiedIdleRanges: [], firstPointerMovementTime: 5,
        reduceWaiting: true, waitingTime: 0.1, deadTimeRate: 6
    )
    let visibleMotion = GlobalRetimePlanner.plan(
        actions: [], sourceDuration: 10, motionRanges: [2...2.5],
        verifiedIdleRanges: [0...5], firstPointerMovementTime: 5,
        reduceWaiting: true, waitingTime: 0.1, deadTimeRate: 6
    )

    #expect(unverified.first?.sourceStart == 0)
    #expect(visibleMotion.first?.sourceStart == 0)
}

@Test func globalRetimeKeepsShortOpeningBeforeEarlyPointerMovement() {
    let retime = GlobalRetimePlanner.plan(
        actions: [], sourceDuration: 4, motionRanges: [],
        verifiedIdleRanges: [0...0.8], firstPointerMovementTime: 0.8,
        reduceWaiting: true, waitingTime: 0.1, deadTimeRate: 6
    )

    #expect(retime.first?.sourceStart == 0)
}

@Test func globalRetimeProtectsSelectedStructuralResponseAndReadingHold() throws {
    let observations = [VisualMotionObservation(
        time: 5.6,
        normalizedBounds: CGRect(x: 0.2, y: 0.6, width: 0.5, height: 0.3),
        changedFraction: 0.12, magnitude: 0.95, kind: .appearance,
        startTime: 5.0
    )]
    let protected = GlobalRetimePlanner.protectedResponseRanges(
        observations: observations, observationIDs: [0],
        sourceDuration: 10, readingHold: 0.4
    )
    let retime = GlobalRetimePlanner.plan(
        actions: [], sourceDuration: 10, motionRanges: [5.0...5.6],
        protectedResponseRanges: protected,
        reduceWaiting: true, waitingTime: 0.1, deadTimeRate: 6
    )

    #expect(protected == [5.0...6.0])
    #expect(retime.contains { $0.sourceStart <= 5.0 && $0.sourceEnd >= 6.0 && $0.rate == 1 })
}

@Test func globalRetimeOnlyRemovesActionProtectionWithIdleProof() throws {
    let directed = try composition(
        "[{\"action\":\"scroll\",\"time\":5.0}]", duration: 10
    )
    let conservative = GlobalRetimePlanner.plan(
        actions: directed.actions,
        sourceDuration: 10,
        motionRanges: [],
        verifiedIdleRanges: [1...9],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )
    let provenNoOp = GlobalRetimePlanner.plan(
        actions: directed.actions,
        sourceDuration: 10,
        motionRanges: [],
        verifiedIdleRanges: [1...9],
        provenIdleActionIDs: [0],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )

    #expect(conservative.contains { $0.sourceStart <= 5 && $0.sourceEnd >= 5 })
    #expect(!provenNoOp.contains { $0.sourceStart <= 5 && $0.sourceEnd >= 5 })
}

@Test func declaredProvenancePreservesEveryUnverifiedGap() throws {
    let retime = GlobalRetimePlanner.plan(
        actions: [],
        sourceDuration: 10,
        motionRanges: [],
        verifiedIdleRanges: [],
        reduceWaiting: true,
        waitingTime: 0.1,
        deadTimeRate: 6
    )

    #expect(retime.first?.sourceStart == 0)
    #expect(retime.last?.sourceEnd == 10)
    #expect(retime.allSatisfy { $0.rate == 1 })
    #expect(zip(retime, retime.dropFirst()).allSatisfy {
        abs($0.sourceEnd - $1.sourceStart) < 0.000_001
    })
}

@Test func oracleForegroundSupportFixtureProducesVisibleLifecycleEndpoints() throws {
    let data = Data("""
    {
      "version": 1,
      "coordinateSpace": "source-window-normalized-top-left",
      "observations": [{
        "id": "dialog-1",
        "lifecycleId": "dialog",
        "startTime": 2.5,
        "endTime": 6.0,
        "bounds": {"x": 0.25, "y": 0.2, "width": 0.5, "height": 0.6},
        "confidence": 1.0,
        "abstained": false,
        "note": "visible support only"
      }]
    }
    """.utf8)
    let fixture = try JSONDecoder().decode(
        OracleForegroundSupportFixture.self,
        from: data
    ).validated(sourceDuration: 8)
    let observations = fixture.visualObservations()

    #expect(observations.count == 2)
    #expect(observations[0].focusTransition == .gained)
    #expect(observations[1].focusTransition == .released)
    #expect(observations.allSatisfy { $0.normalizedBounds == CGRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6) })
}

@Test func topLeftOracleCoordinatesMapIntoBottomLeftCameraCanvasExactly() throws {
    let directed = try composition("[]", duration: 8)
    let normalized = CGRect(x: 0.35, y: 0.38, width: 0.28, height: 0.32)
    let observations = [
        VisualMotionObservation(
            time: 2,
            normalizedBounds: normalized,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .gained,
            startTime: 2
        ),
        VisualMotionObservation(
            time: 6,
            normalizedBounds: normalized,
            changedFraction: 0.1,
            magnitude: 1,
            kind: .focus,
            focusTransition: .released,
            startTime: 6
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed,
        contentRect: rect,
        sourceDuration: 8,
        observations: observations,
        motionRanges: [2...6],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [0, 1],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle(
            bounds: normalized,
            gainedAt: 2,
            releasedAt: 6,
            gainedObservationID: 0,
            releasedObservationID: 1
        )]
    )
    let mapped = try #require(graph.lifecycles.first?.bounds)

    #expect(abs(mapped.minX - 350) < 0.001)
    #expect(abs(mapped.minY - 240) < 0.001)
    #expect(abs(mapped.width - 280) < 0.001)
    #expect(abs(mapped.height - 256) < 0.001)
}

@Test func oracleGateSuppressesDisjointMotionWithoutChangingCurrentCondition() throws {
    let directed = try composition("""
    [{"action":"click","time":3.0,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    """, duration: 8)
    let observations = [
        VisualMotionObservation(
            time: 3.45,
            normalizedBounds: CGRect(x: 0.02, y: 0.08, width: 0.16, height: 0.2),
            changedFraction: 0.15, magnitude: 0.9, kind: .appearance,
            startTime: 3.1
        ),
        VisualMotionObservation(
            time: 2.8,
            normalizedBounds: CGRect(x: 0.35, y: 0.2, width: 0.55, height: 0.65),
            changedFraction: 0.12, magnitude: 1, kind: .focus,
            focusTransition: .gained, startTime: 2.68
        ),
        VisualMotionObservation(
            time: 6.0,
            normalizedBounds: CGRect(x: 0.35, y: 0.2, width: 0.55, height: 0.65),
            changedFraction: 0.12, magnitude: 1, kind: .focus,
            focusTransition: .released, startTime: 5.88
        )
    ]
    let current = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2.68...6.0],
        evaluationCondition: .cOracleCurrent, supportObservationIDs: [1, 2]
    )
    let gated = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [2.68...6.0],
        evaluationCondition: .dOracleGated, supportObservationIDs: [1, 2],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle(
            bounds: CGRect(x: 0.35, y: 0.2, width: 0.55, height: 0.65),
            gainedAt: 2.8, releasedAt: 6,
            gainedObservationID: 1, releasedObservationID: 2
        )]
    )

    #expect(current.actions[0].attention.contains { $0.observationIDs.contains(0) })
    #expect(!gated.actions[0].attention.contains { $0.observationIDs.contains(0) })
    #expect(gated.actions[0].attention.contains { $0.observationClass == .oracleForegroundSupport })
    #expect(gated.observationClass(for: 0) == .motionEditorial)
    #expect(gated.observationClass(for: 1) == .oracleForegroundSupport)
}

@Test func currentEvaluationConditionPreservesProductionCameraDecisions() throws {
    let observations = [VisualMotionObservation(
        time: 3.6,
        normalizedBounds: CGRect(x: 0.3, y: 0.25, width: 0.35, height: 0.3),
        changedFraction: 0.15, magnitude: 0.9, kind: .appearance,
        startTime: 3.2
    )]
    let directed = try composition("""
    [{"action":"click","time":3.0,"coordinates":{"xNorm":0.5,"yNorm":0.5},"targetResolution":{"provenance":"direct","confidence":0.99}}]
    """, duration: 8, motion: observations)
    let production = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [3.2...3.6]
    )
    let current = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: observations, motionRanges: [3.2...3.6],
        evaluationCondition: .aCurrent
    )
    let base = CameraState(x: size.width / 2, y: size.height / 2, logScale: 0)
    let productionPlan = ProductionPlanner.plan(graph: production, composition: directed, base: base)
    let currentPlan = ProductionPlanner.plan(graph: current, composition: directed, base: base)

    #expect(productionPlan.decisions.map(\.attentionID) == currentPlan.decisions.map(\.attentionID))
    #expect(productionPlan.decisions.map(\.timingID) == currentPlan.decisions.map(\.timingID))
    #expect(productionPlan.camera.moves.count == currentPlan.camera.moves.count)
    for (left, right) in zip(productionPlan.camera.moves, currentPlan.camera.moves) {
        #expect(abs(left.start - right.start) < 0.000_001)
        #expect(abs(left.end - right.end) < 0.000_001)
        #expect(abs(left.to.x - right.to.x) < 0.000_001)
        #expect(abs(left.to.y - right.to.y) < 0.000_001)
        #expect(abs(left.to.logScale - right.to.logScale) < 0.000_001)
    }
}

@Test func factorialGraphFreezesResolvedControlTiming() throws {
    let phase = InteractionPhases(
        rawEstimate: 4.2, toolStart: 2.8, toolEnd: 4.5,
        pointerArrival: 3.0, activation: 3.25, responseOnset: 3.5,
        source: "resolved-control"
    )
    let directed = try composition(
        """
        [{"action":"click","time":4.0,"coordinates":{"xNorm":0.5,"yNorm":0.5}}]
        """,
        duration: 8,
        interactionPhases: [0: phase]
    )
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 8,
        observations: [], motionRanges: [],
        evaluationCondition: .bOptionalMotion,
        freezeResolvedTiming: true
    )
    let timings = try #require(graph.actions.first?.timings)

    #expect(timings.count == 1)
    #expect(timings[0].activation == 3.25)
    #expect(timings[0].pointerArrival == 3.0)
    #expect(timings[0].responseOnset == 3.5)
    #expect(timings[0].source == "factorial-control:resolved-control")
}

@Test func gatedObjectiveKeepsOrdinaryEditorialEvidenceOptionalOutsideOracleOwnership() throws {
    let directed = try composition("[]", duration: 10)
    let observations = [
        VisualMotionObservation(
            time: 3.8,
            normalizedBounds: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5),
            changedFraction: 0.1, magnitude: 0.8, kind: .appearance,
            startTime: 3.2
        ),
        VisualMotionObservation(
            time: 8.0,
            normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
            changedFraction: 0.1, magnitude: 0.8, kind: .appearance,
            startTime: 7.5
        ),
        VisualMotionObservation(
            time: 3.0,
            normalizedBounds: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.6),
            changedFraction: 0.1, magnitude: 1, kind: .focus,
            focusTransition: .gained, startTime: 3.0
        ),
        VisualMotionObservation(
            time: 6.0,
            normalizedBounds: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.6),
            changedFraction: 0.1, magnitude: 1, kind: .focus,
            focusTransition: .released, startTime: 6.0
        )
    ]
    let graph = ProductionPlanGraph.make(
        from: directed, contentRect: rect, sourceDuration: 10,
        observations: observations, motionRanges: [3.0...6.0, 7.5...8.0],
        evaluationCondition: .dOracleGated,
        supportObservationIDs: [2, 3],
        oracleSupportLifecycles: [OracleForegroundSupportLifecycle(
            bounds: CGRect(x: 0.25, y: 0.15, width: 0.5, height: 0.6),
            gainedAt: 3.0, releasedAt: 6.0,
            gainedObservationID: 2, releasedObservationID: 3
        )]
    )

    #expect(graph.editorialEvidenceIsOptional(observationID: 0))
    #expect(graph.editorialEvidenceIsOptional(observationID: 1))
    #expect(graph.editorialEvidenceIsOptional(observationID: 2))
}

@Test func actionResponseCoverageCatchesShortFragmentedEffectOutsideCamera() throws {
    func evidence(
        _ id: Int, actionID: Int, start: Double, end: Double, bounds: CGRect,
        changed: Double = 0.001, confidence: Double = 0.6
    ) -> ActionResponseSlice.Evidence {
        ActionResponseSlice.Evidence(id: id, source: EpisodeVisualEvidence(
            actionID: actionID, startTime: start, endTime: end,
            normalizedBounds: bounds, changedFraction: changed,
            confidence: confidence
        ))
    }
    let response = [
        evidence(0, actionID: -1, start: 2.05, end: 2.30,
                 bounds: CGRect(x: 0.72, y: 0.10, width: 0.13, height: 0.03)),
        evidence(1, actionID: 7, start: 2.14, end: 2.40,
                 bounds: CGRect(x: 0.72, y: 0.10, width: 0.15, height: 0.05)),
        evidence(2, actionID: 7, start: 2.22, end: 2.48,
                 bounds: CGRect(x: 0.90, y: 0.10, width: 0.075, height: 0.05))
    ]
    let slices = [ActionResponseSlice(
        actionID: 7, activation: 2, exclusiveEnd: 3,
        exclusiveEvidence: response
    )]
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: slices,
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: log(1.6))
        }
    )
    let failure = try #require(audit.croppedMaterialResponses.first)

    #expect(failure.actionID == 7)
    #expect(failure.evidenceIDs == [0, 1, 2])
    #expect(failure.sourceOwnedEvidenceIDs == [1, 2])
    #expect(failure.sourceRange.upperBound - failure.sourceRange.lowerBound < 0.75)
    #expect(failure.normalizedBounds.maxX == 0.975)
    #expect(failure.minimumVisibleFraction < 0.5)
}

@Test func actionResponseCoverageDoesNotPromoteUnownedMotionToMaterialResponse() throws {
    let global = ActionResponseSlice.Evidence(id: 0, source: EpisodeVisualEvidence(
        actionID: -1, startTime: 2.05, endTime: 2.45,
        normalizedBounds: CGRect(x: 0.75, y: 0.08, width: 0.22, height: 0.08),
        changedFraction: 0.02, confidence: 0.95
    ))
    let repeated = ActionResponseSlice.Evidence(id: 1, source: EpisodeVisualEvidence(
        actionID: -1, startTime: 2.20, endTime: 2.60,
        normalizedBounds: CGRect(x: 0.76, y: 0.08, width: 0.21, height: 0.08),
        changedFraction: 0.02, confidence: 0.95
    ))
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: [ActionResponseSlice(
            actionID: 4, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [global, repeated]
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: log(1.8))
        }
    )

    #expect(audit.responses.count == 1)
    #expect(audit.responses[0].cropped)
    #expect(!audit.responses[0].material)
    #expect(audit.croppedMaterialResponses.isEmpty)
}

@Test func actionResponseCoverageKeepsDistantSimultaneousChangesSeparate() throws {
    func item(_ id: Int, _ x: CGFloat) -> ActionResponseSlice.Evidence {
        ActionResponseSlice.Evidence(id: id, source: EpisodeVisualEvidence(
            actionID: 2, startTime: 2.05, endTime: 2.35,
            normalizedBounds: CGRect(x: x, y: 0.1, width: 0.08, height: 0.08),
            changedFraction: 0.01, confidence: 0.8
        ))
    }
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: [ActionResponseSlice(
            actionID: 2, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [item(0, 0.05), item(1, 0.85)]
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: 0)
        }
    )

    #expect(audit.responses.count == 2)
    #expect(audit.responses.allSatisfy { $0.evidenceCount == 1 })
    #expect(audit.materialResponses.isEmpty)
}

@Test func actionResponseCoverageRejectsWeakCroppedFragmentBesideStrongCoveredResponse() throws {
    func item(
        _ id: Int, bounds: CGRect, changed: Double
    ) -> ActionResponseSlice.Evidence {
        ActionResponseSlice.Evidence(id: id, source: EpisodeVisualEvidence(
            actionID: 3, startTime: 2.05 + Double(id % 2) * 0.08,
            endTime: 2.35 + Double(id % 2) * 0.08,
            normalizedBounds: bounds, changedFraction: changed,
            confidence: 0.8
        ))
    }
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: [ActionResponseSlice(
            actionID: 3, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [
                item(0, bounds: CGRect(x: 0.35, y: 0.35, width: 0.20, height: 0.15), changed: 0.03),
                item(1, bounds: CGRect(x: 0.36, y: 0.35, width: 0.19, height: 0.15), changed: 0.03),
                item(2, bounds: CGRect(x: 0.92, y: 0.08, width: 0.07, height: 0.16), changed: 0.003),
                item(3, bounds: CGRect(x: 0.93, y: 0.08, width: 0.06, height: 0.16), changed: 0.003)
            ]
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: log(1.6))
        }
    )
    let weak = try #require(audit.responses.first { $0.normalizedBounds.minX > 0.8 })
    let strong = try #require(audit.responses.first { $0.normalizedBounds.minX < 0.8 })

    #expect(weak.cropped)
    #expect(weak.relativeSignal < 0.2)
    #expect(!weak.material)
    #expect(strong.material)
    #expect(!strong.cropped)
    #expect(audit.croppedMaterialResponses.isEmpty)
}

@Test func actionResponseCoverageRetainsMultipleComparableResponseHypotheses() throws {
    func item(
        _ id: Int, x: CGFloat, changed: Double
    ) -> ActionResponseSlice.Evidence {
        ActionResponseSlice.Evidence(id: id, source: EpisodeVisualEvidence(
            actionID: 5, startTime: 2.05 + Double(id % 2) * 0.08,
            endTime: 2.35 + Double(id % 2) * 0.08,
            normalizedBounds: CGRect(x: x, y: 0.40, width: 0.12, height: 0.10),
            changedFraction: changed, confidence: 0.8
        ))
    }
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: [ActionResponseSlice(
            actionID: 5, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [
                item(0, x: 0.42, changed: 0.03), item(1, x: 0.43, changed: 0.03),
                item(2, x: 0.84, changed: 0.027), item(3, x: 0.85, changed: 0.027)
            ]
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: log(1.6))
        }
    )

    #expect(audit.materialResponses.count == 2)
    #expect(audit.croppedMaterialResponses.count == 1)
    #expect(audit.croppedMaterialResponses[0].relativeSignal > 0.8)
}

@Test func actionResponseCoverageLeavesDiffuseSceneFieldsToOverviewInference() throws {
    func item(_ id: Int, start: Double) -> ActionResponseSlice.Evidence {
        ActionResponseSlice.Evidence(id: id, source: EpisodeVisualEvidence(
            actionID: 8, startTime: start, endTime: start + 0.30,
            normalizedBounds: CGRect(x: 0.20, y: 0.05, width: 0.60, height: 0.80),
            changedFraction: 0.20, confidence: 0.95
        ))
    }
    let audit = ActionResponseCoverageAudit.evaluate(
        slices: [ActionResponseSlice(
            actionID: 8, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [item(0, start: 2.05), item(1, start: 2.18)]
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
        outputSize: CGSize(width: 1_000, height: 1_000),
        cameraAtSourceTime: { _ in
            CameraState(x: 500, y: 500, logScale: log(1.8))
        }
    )

    #expect(audit.responses.count == 1)
    #expect(audit.responses[0].cropped)
    #expect(!audit.responses[0].material)
    #expect(ActionResponseCoverageAudit.constraints(
        slices: [ActionResponseSlice(
            actionID: 8, activation: 2, exclusiveEnd: 3,
            exclusiveEvidence: [item(0, start: 2.05), item(1, start: 2.18)]
        )]
    ).isEmpty)
}

@Test func shotScheduleUsesResponseCoverageOnlyToZoomOutFromChosenCenter() throws {
    let directed = try composition(
        """
        [
          {"action":"click","time":2.0,"coordinates":{"xNorm":0.50,"yNorm":0.50}},
          {"action":"click","time":5.0,"coordinates":{"xNorm":0.52,"yNorm":0.50}}
        ]
        """,
        duration: 12
    )
    let subject = SubjectGraph.Subject(
        id: 0, kind: .surface,
        bounds: CGRect(x: 450, y: 440, width: 110, height: 120),
        sourceRange: 2...10, actionIDs: [0, 1], confidence: 0.9
    )
    let subjects = SubjectGraph(
        size: CGSize(width: 1_000, height: 1_000),
        subjects: [subject], transitions: []
    )
    let base = CameraState(x: 500, y: 500, logScale: 0)
    let unconstrained = ShotSchedulePlanner.plan(
        subjects: subjects, composition: directed, base: base
    )
    let constrained = ShotSchedulePlanner.plan(
        subjects: subjects,
        composition: directed,
        base: base,
        responseCoverageConstraints: [.init(
            actionID: 1,
            sourceRange: 5.1...5.6,
            normalizedBounds: CGRect(x: 0.70, y: 0.40, width: 0.20, height: 0.10),
            evidenceIDs: [0, 1], relativeSignal: 1
        )],
        contentRect: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
    )
    let originalShot = try #require(unconstrained.shots.first { $0.subjectID == 0 })
    let safeShot = try #require(constrained.shots.first { $0.subjectID == 0 })
    let originalScale = exp(originalShot.pose.logScale)
    let safeScale = exp(safeShot.pose.logScale)

    #expect(originalScale > safeScale)
    #expect(safeScale >= 1.15)
    #expect(abs(safeShot.pose.x - originalShot.pose.x) < 0.001)
    #expect(abs(safeShot.pose.y - originalShot.pose.y) < 0.001)
    let response = CGRect(x: 700, y: 500, width: 200, height: 100)
    let projectedMin = projectPointThroughCamera(
        response.origin, camera: safeShot.pose, outputSize: subjects.size
    )
    let projectedMax = projectPointThroughCamera(
        CGPoint(x: response.maxX, y: response.maxY),
        camera: safeShot.pose, outputSize: subjects.size
    )
    let projected = CGRect(
        x: min(projectedMin.x, projectedMax.x),
        y: min(projectedMin.y, projectedMax.y),
        width: abs(projectedMax.x - projectedMin.x),
        height: abs(projectedMax.y - projectedMin.y)
    )
    let visible = projected.intersection(CGRect(origin: .zero, size: subjects.size))
    let visibleFraction = visible.width * visible.height
        / (projected.width * projected.height)
    #expect(visibleFraction >= 0.98 - 0.000_001)
}
