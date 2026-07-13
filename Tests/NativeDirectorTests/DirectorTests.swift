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
    allowInferredTargets: Bool = false
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
        interactionPhases: interactionPhases
    )
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
    #expect(exp(first.logScale) > 1.15)
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
    #expect(directed.retime.contains { $0.sourceStart <= 3 && $0.sourceEnd >= 7 && $0.rate == 6 })
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
    #expect(abs((phases.preActivationActivityEnd ?? 0) - 10.24) < 0.001)
    #expect(abs((phases.responseOnset ?? 0) - 11.05) < 0.001)
    #expect(phases.source == "target-visual")
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
        preActivationActivityEnd: 4.32
    )
    let afterInternalRelocation = try composition("""
    [{"action":"click","time":4.1,"coordinates":{"xNorm":0.82,"yNorm":0.52},"semanticTarget":{"bounds":{"xNorm":0.79,"yNorm":0.49,"widthNorm":0.06,"heightNorm":0.05},"viewportRelocation":{"kind":"target-entered-viewport","displacementNorm":0.62,"fromVisibleFraction":0,"toVisibleFraction":1,"postActionOffsetMs":450}}}]
    """, duration: 7, interactionPhases: [0: relocationPhases])
    let relocationOrderedTrip = try #require(afterInternalRelocation.pointerTrip(forActionID: 0))
    #expect(relocationOrderedTrip.start >= 4.37)
    #expect(relocationOrderedTrip.end <= relocationPhases.activation)
}

@Test func interactionTimingFallsBackToSemanticToolCompletionWithoutMagicOffset() {
    let phases = InteractionPhaseDetector.detect(
        samples: [], rawEstimate: 4.4, toolStart: 4, toolEnd: 4.8,
        finalActionInToolCall: true
    )
    #expect(phases.pointerArrival == 4.4)
    #expect(phases.activation == 4.8)
    #expect(phases.source == "tool-completion")
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

    // The reconstructed pointer starts at 3.05. Camera follows 100 ms later,
    // rather than waiting for the measured click activation at 4.70.
    #expect(abs(directed.shots[0].start - 3.15) < 0.001)
    #expect(exp(try #require(directed.settledCamera(forActionID: 0)).logScale) > 1)
    #expect(directed.cursor(at: 3.5).point.x > size.width * 0.16)
    #expect(directed.retime.contains {
        $0.sourceStart <= 3.05 && $0.sourceEnd >= 4.7 && $0.rate == 1
    })
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
    #expect(abs(directed.shots[0].start - 1.95) < 0.001)
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
