import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  compareToBaseline, scoreCameraAudit, structuralCameraMetrics
} from "../lib/camera-evaluation.mjs";

const annotations = {
  version: 1,
  coordinateSpace: "source-window-normalized-top-left",
  beats: [
    {
      id: "dialog", actionID: 0, baseline: "bad", desiredShot: "frame-subject",
      subject: {x: 0.25, y: 0.2, width: 0.5, height: 0.6},
      scale: {min: 1.2, max: 1.8}
    },
    {id: "hold", actionID: 1, baseline: "acceptable", desiredShot: "hold-current"},
    {id: "close", actionID: 2, baseline: "ambiguous", desiredShot: "return", negative: true}
  ]
};

function audit(cameras, {moves = [], windows = []} = {}) {
  return {
    planner: "normal-eval",
    canvas: {width: 1000, height: 800},
    contentRect: {x: 0, y: 0, width: 1000, height: 800},
    beatScales: cameras.map((camera, actionID) => ({actionID, outputTime: actionID, camera})),
    alignment: [{visible: true, safeVisible: true}],
    causalOrdering: {violations: 0},
    emergencyCorrections: 0,
    trajectory: cameras.map((camera, actionID) => ({outputTime: actionID, ...camera})),
    moves,
    windows
  };
}

test("camera evaluation scores framing, continuity, and return beats", () => {
  const score = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.0}
  ]), annotations);

  assert.equal(score.passed, 3);
  assert.equal(score.total, 3);
  assert.equal(score.factualViolations, 0);
  assert.equal(score.coverage.coversFinalAction, true);
});

test("structural metrics are available without editorial annotations", () => {
  const metrics = structuralCameraMetrics(audit([
    {x: 500, y: 400, scale: 1},
    {x: 600, y: 400, scale: 1.2}
  ], {
    moves: [{translation: {dx: 100, dy: 0}}],
    windows: [{
      actionID: 1, start: 0, end: 1,
      pathEfficiency: 0.8, scaleEfficiency: 1,
      xReversals: 1, yReversals: 0, scaleReversals: 0
    }]
  }));

  assert.equal(metrics.moveCount, 1);
  assert.equal(metrics.travel, 100);
  assert.deepEqual(metrics.continuityViolations[0].reasons, [
    "x-reversal", "inefficient-path"
  ]);
});

test("camera evaluation exposes an unscored recording tail", () => {
  const partial = {
    ...annotations,
    beats: annotations.beats.slice(0, 2)
  };
  const score = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.0}
  ]), partial);

  assert.equal(score.coverage.coversFinalAction, false);
  assert.equal(score.coverage.finalRecordedActionID, 2);
  assert.deepEqual(score.coverage.unannotatedActionIDs, [2]);
});

test("visibility-only beats do not require centering or a zoom", () => {
  const visibilityAnnotations = {
    version: 1,
    coordinateSpace: "source-window-normalized-top-left",
    beats: [{
      id: "brief-notice",
      actionID: 0,
      baseline: "acceptable",
      desiredShot: "keep-visible",
      subject: {x: 0.82, y: 0.12, width: 0.16, height: 0.08},
      scale: {max: 1.08}
    }]
  };
  const overview = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.0}
  ]), visibilityAnnotations);
  const unnecessaryPunchIn = scoreCameraAudit(audit([
    {x: 900, y: 672, scale: 1.15}
  ]), visibilityAnnotations);

  assert.equal(overview.passed, 1);
  assert.equal(overview.beats[0].visibleFraction, 1);
  assert.ok(overview.beats[0].centerDistance > 0.23);
  assert.deepEqual(unnecessaryPunchIn.beats[0].reasons, ["scale-too-tight"]);
});

test("factorial comparison separates fixes from acceptable-beat regressions", () => {
  const baseline = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0}
  ]), annotations);
  const candidate = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.4},
    {x: 650, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0}
  ]), annotations);
  const compared = compareToBaseline([
    {condition: "a-current", score: baseline},
    {condition: "d-oracle-gated", score: candidate}
  ]);

  assert.deepEqual(compared[1].correctedBaselineBeats, ["dialog"]);
  assert.deepEqual(compared[1].regressedAcceptableBeats, ["hold"]);
});

test("factorial gate rejects sampled-frame wins with excessive travel or camera churn", () => {
  const baseline = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0}
  ], {
    moves: [{translation: {dx: 100, dy: 0}}]
  }), annotations);
  const candidate = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.0}
  ], {
    moves: [
      {translation: {dx: 100, dy: 0}},
      {translation: {dx: 100, dy: 0}}
    ],
    windows: [{
      actionID: 0, start: 0, end: 1,
      pathEfficiency: 0.85, scaleEfficiency: 0.55,
      xReversals: 0, yReversals: 0, scaleReversals: 1
    }]
  }), annotations);
  const compared = compareToBaseline([
    {condition: "a-current", score: baseline},
    {condition: "d-oracle-gated", score: candidate}
  ]);

  assert.equal(compared[1].score.passed, 3);
  assert.equal(compared[1].continuityGatePassed, false);
  assert.equal(compared[1].deterministicGatePassed, false);
  assert.deepEqual(compared[1].score.continuityViolations[0].reasons, [
    "scale-reversal", "inefficient-path", "inefficient-scale"
  ]);
});

test("factorial comparison can use the no-oracle condition as baseline", () => {
  const withoutOracle = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0},
    {x: 500, y: 400, scale: 1.0}
  ]), annotations);
  const oracleGated = scoreCameraAudit(audit([
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.4},
    {x: 500, y: 400, scale: 1.0}
  ]), annotations);
  const compared = compareToBaseline([
    {condition: "b-optional-motion", score: withoutOracle},
    {condition: "d-oracle-gated", score: oracleGated}
  ], "b-optional-motion");

  assert.deepEqual(compared[1].correctedBaselineBeats, ["dialog"]);
  assert.equal(compared[1].deterministicGatePassed, true);
});

test("accepted editorial baseline remains explicit, portable, and fully annotated", async () => {
  const root = new URL("../Fixtures/CameraEvaluation/editorial-baseline-v1/", import.meta.url);
  const [baselineText, annotationsText, supportText] = await Promise.all([
    readFile(new URL("baseline.json", root), "utf8"),
    readFile(new URL("camera-annotations.json", root), "utf8"),
    readFile(new URL("oracle-support.json", root), "utf8")
  ]);
  const baseline = JSON.parse(baselineText);
  const accepted = JSON.parse(annotationsText);
  const support = JSON.parse(supportText);

  assert.equal(baseline.status, "accepted-editorial-reference");
  assert.equal(baseline.evaluationCondition, "d-oracle-gated");
  assert.deepEqual(baseline.expected, {
    correctBeats: 12,
    totalBeats: 12,
    moveCount: 6,
    falseEmphasis: 0,
    factualViolations: 0,
    continuityViolations: 0
  });
  assert.equal(accepted.beats.length, baseline.expected.totalBeats);
  assert.equal(accepted.beats.at(-1).actionID, 11);
  assert.deepEqual(support.observations.map(observation => observation.lifecycleId), [
    "export-menu", "edit-report-modal", "folder-menu", "notice"
  ]);
  assert.ok(support.observations.some(observation => observation.abstained));
  assert.doesNotMatch(`${baselineText}${annotationsText}${supportText}`, /\/Users\//);
});
