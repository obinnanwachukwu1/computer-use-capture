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

@Test func globalScenePlanOwnsStructuralObservationsButPreservesTranslation() throws {
    let plan = try JSONDecoder().decode(GlobalScenePlanFile.self, from: Data("""
    {
      "version": 1,
      "coordinateSpace": "source-window-normalized-top-left",
      "model": "global-scene-sequence-v1",
      "sceneEpisodes": [
        {"start": 3.0, "end": 3.4, "kind": "contextTransition", "bounds": null,
         "features": {"evidenceCoverage": 0.3}},
        {"start": 5.0, "end": 5.5, "kind": "focusGained",
         "bounds": {"x": 0.3, "y": 0.2, "width": 0.4, "height": 0.5},
         "features": {"evidenceCoverage": 0.2}},
        {"start": 8.0, "end": 8.3, "kind": "focusReleased",
         "bounds": {"x": 0.3, "y": 0.2, "width": 0.4, "height": 0.5},
         "features": {"evidenceCoverage": 0.2}}
      ]
    }
    """.utf8))
    let original = [
        VisualMotionObservation(
            time: 2.0, normalizedBounds: CGRect(x: 0, y: 0.2, width: 1, height: 0.7),
            changedFraction: 0.3, magnitude: 1, kind: .translation
        ),
        VisualMotionObservation(
            time: 3.3, normalizedBounds: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
            changedFraction: 0.1, magnitude: 0.8, kind: .appearance
        ),
        VisualMotionObservation(
            time: 5.7, normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            changedFraction: 0.2, magnitude: 0.9, kind: .focus, focusTransition: .gained
        ),
    ]

    let result = applyingGlobalScenePlan(plan, to: original)
    #expect(result.count == 4)
    #expect(result.filter { $0.kind == .translation }.count == 1)
    #expect(result.filter { $0.kind == .appearance }.isEmpty)
    #expect(result.filter { $0.kind == .contextTransition }.count == 1)
    #expect(result.filter { $0.kind == .focus }.map(\.focusTransition) == [.gained, .released])
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
    let material = field.structural.filter { $0.changedFraction > 0.01 }
    #expect(material.count == 2)
    #expect(material.allSatisfy { rectArea($0.normalizedBounds) < 0.10 })
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

@Test func experimentalObservationOverrideReplacesOnlyVisualEvidenceInItsCausalWindow() {
    let original = [
        VisualMotionObservation(time: 3.2, normalizedBounds: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2), changedFraction: 0.1, magnitude: 0.5, kind: .appearance),
        VisualMotionObservation(time: 3.3, normalizedBounds: CGRect(x: 0, y: 0, width: 1, height: 1), changedFraction: 0.5, magnitude: 0.8, kind: .translation),
        VisualMotionObservation(time: 8, normalizedBounds: CGRect(x: 0.6, y: 0.6, width: 0.1, height: 0.1), changedFraction: 0.1, magnitude: 0.5, kind: .appearance),
    ]
    let replacement = MotionObservationOverride(
        actionID: 4,
        replaceStart: 3,
        replaceEnd: 4,
        time: 3.7,
        bounds: .init(x: 0.3, y: 0.2, width: 0.4, height: 0.5),
        kind: .focus,
        focusTransition: .gained,
        changedFraction: 0.2,
        magnitude: 0.9
    )

    let result = applyingMotionObservationOverrides([replacement], to: original)
    #expect(result.count == 3)
    #expect(result.contains { $0.kind == .translation && $0.time == 3.3 })
    #expect(result.contains { $0.kind == .appearance && $0.time == 8 })
    let focus = result.first { $0.kind == .focus }
    #expect(abs((focus?.normalizedBounds.minX ?? 0) - 0.3) < 0.000_001)
    #expect(abs((focus?.normalizedBounds.minY ?? 0) - 0.2) < 0.000_001)
    #expect(abs((focus?.normalizedBounds.width ?? 0) - 0.4) < 0.000_001)
    #expect(abs((focus?.normalizedBounds.height ?? 0) - 0.5) < 0.000_001)
    #expect(focus?.focusTransition == .gained)
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

@Test func productionPlannerV3UsesSeparateActivationAndResponsePoses() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)
    let close = try #require(plan.decisions.last)

    #expect(plan.camera.diagnostics.feasible)
    #expect(exp(close.arrivalPose.logScale) > 1.1)
    #expect(abs(close.pose.logScale) < 0.001)
    #expect(plan.camera.moves.contains { $0.label.contains("focus-release") })
}

@Test func productionPlannerV3RetainsStructuralAlternativesBeyondCheapPoseVariants() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)

    #expect(plan.camera.diagnostics.feasible)
    #expect(decision.observationIDs == [0])
}

@Test func productionPlannerV3UsesInformationGainToPreferSubstantialReveal() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)
    let decision = try #require(plan.decisions.first)

    #expect(decision.observationIDs == [1])
}

@Test func productionPlannerV3ContextTransitionRequiresEstablishingOverview() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)
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

@Test func productionPlannerV3SettlesBeforeSemanticVisibilityBegins() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)

    #expect(plan.camera.diagnostics.feasible)
    let secondVisibility = try #require(NativeComposition.semanticVisibilityStart(
        for: directed.actions[0]
    ))
    let secondMove = try #require(plan.camera.moves.first { $0.label == "v3-action-0" })
    #expect(secondMove.end <= directed.outputTime(atSourceTime: secondVisibility) + 0.001)
}

@Test func productionPlannerV3RevealsAnOffscreenFactualCursorDeparture() throws {
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
    let plan = ProductionPlannerV3.plan(graph: graph, composition: directed, base: base)
    let reveal = try #require(plan.camera.moves.first { $0.label == "v3-action-0" })
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
        diagnostics: CameraPlanDiagnostics(plannerVersion: "v4-test", feasible: true)
    )
    let tracked = cameraState(at: 2.0, plan: plan, base: base)
    #expect(abs(tracked.x - 620) < 0.001)
    #expect(abs(exp(tracked.logScale) - 1.2) < 0.001)
    let editorial = cameraState(at: 1.25, plan: plan, base: base)
    #expect(editorial != base)
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
