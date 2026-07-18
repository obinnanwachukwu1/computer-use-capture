import path from "node:path";
import { readFile } from "node:fs/promises";

export async function readJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

export function artifactPaths(outputVideo) {
  const stem = outputVideo.slice(0, -path.extname(outputVideo).length);
  return {
    audit: `${stem}.camera-audit.json`,
    plan: `${stem}.production-plan.json`
  };
}

export function validateAnnotations(value) {
  if (value?.version !== 1) throw new Error("annotations version must be 1");
  if (value.coordinateSpace !== "source-window-normalized-top-left") {
    throw new Error("annotations coordinateSpace must be source-window-normalized-top-left");
  }
  if (!Array.isArray(value.beats) || value.beats.length === 0) {
    throw new Error("annotations must contain at least one beat");
  }
  const ids = new Set();
  for (const beat of value.beats) {
    if (!beat.id || ids.has(beat.id)) throw new Error(`invalid or duplicate beat id ${beat.id}`);
    ids.add(beat.id);
    if (!Number.isInteger(beat.actionID)) throw new Error(`${beat.id} requires integer actionID`);
    if (!["acceptable", "bad", "ambiguous"].includes(beat.baseline)) {
      throw new Error(`${beat.id} has invalid baseline`);
    }
    if (!["overview", "frame-subject", "keep-visible", "hold-current", "return"].includes(beat.desiredShot)) {
      throw new Error(`${beat.id} has invalid desiredShot`);
    }
    if (["frame-subject", "keep-visible"].includes(beat.desiredShot)) {
      validateRect(beat.subject, beat.id);
    }
  }
  return value;
}

function validateRect(rect, id) {
  if (!rect || ![rect.x, rect.y, rect.width, rect.height].every(Number.isFinite)) {
    throw new Error(`${id} requires a finite subject rectangle`);
  }
  if (rect.x < 0 || rect.y < 0 || rect.width <= 0 || rect.height <= 0
      || rect.x + rect.width > 1 || rect.y + rect.height > 1) {
    throw new Error(`${id} subject must be normalized inside the source window`);
  }
}

export function scoreCameraAudit(audit, annotations) {
  validateAnnotations(annotations);
  const samples = new Map(audit.beatScales.map(beat => [beat.actionID, beat]));
  const recordedActionIDs = [...samples.keys()].sort((a, b) => a - b);
  const annotatedActionIDs = new Set(annotations.beats.map(beat => beat.actionID));
  const finalRecordedActionID = recordedActionIDs.at(-1) ?? null;
  const finalAnnotatedActionID = Math.max(...annotatedActionIDs);
  const trajectory = audit.trajectory ?? [];
  const canvas = audit.canvas;
  const content = audit.contentRect;
  if (!canvas || !content) throw new Error("camera audit is missing canvas/contentRect geometry");
  let previous;
  const beats = annotations.beats.map(annotation => {
    const sample = samples.get(annotation.actionID);
    if (!sample?.camera) return {...annotation, passed: false, reasons: ["missing-camera-sample"]};
    const outputTime = sample.outputTime + (annotation.sampleOutputOffset ?? 0);
    const camera = annotation.sampleOutputOffset
      ? nearestCamera(trajectory, outputTime) ?? sample.camera
      : sample.camera;
    const result = scoreBeat(annotation, camera, previous?.camera, canvas, content);
    previous = {camera};
    return {...annotation, camera, outputTime, ...result};
  });
  const structural = structuralCameraMetrics(audit);
  return {
    planner: audit.planner,
    passed: beats.filter(beat => beat.passed).length,
    total: beats.length,
    passRate: beats.length ? beats.filter(beat => beat.passed).length / beats.length : 0,
    falseEmphasis: beats.filter(beat => beat.negative && !beat.passed).length,
    ...structural,
    coverage: {
      finalRecordedActionID,
      finalAnnotatedActionID: Number.isFinite(finalAnnotatedActionID) ? finalAnnotatedActionID : null,
      coversFinalAction: finalRecordedActionID === null
        || annotatedActionIDs.has(finalRecordedActionID),
      unannotatedActionIDs: recordedActionIDs.filter(id => !annotatedActionIDs.has(id))
    },
    beats
  };
}

export function structuralCameraMetrics(audit) {
  const moves = audit.moves ?? [];
  const windows = audit.windows ?? [];
  const trajectory = audit.trajectory ?? [];
  const travel = moves.reduce((sum, move) => {
    const translation = move.translation ?? {};
    return sum + Math.hypot(translation.dx ?? 0, translation.dy ?? 0);
  }, 0);
  const continuityViolations = windows.flatMap(window => {
    const reasons = [];
    if ((window.scaleReversals ?? 0) > 0) reasons.push("scale-reversal");
    if ((window.xReversals ?? 0) > 0) reasons.push("x-reversal");
    if ((window.yReversals ?? 0) > 0) reasons.push("y-reversal");
    if ((window.pathEfficiency ?? 1) < 0.92) reasons.push("inefficient-path");
    if ((window.scaleEfficiency ?? 1) < 0.80) reasons.push("inefficient-scale");
    return reasons.length ? [{actionID: window.actionID, reasons, window}] : [];
  });
  return {
    factualViolations: (audit.alignment ?? []).filter(check => check.visible !== true).length,
    safeFactualViolations: (audit.alignment ?? []).filter(check => check.safeVisible !== true).length,
    causalOrderingViolations: audit.causalOrdering?.violations ?? 0,
    emergencyCorrections: audit.emergencyCorrections ?? 0,
    moveCount: moves.length,
    travel,
    duration: Math.max(
      0,
      ...trajectory.map(sample => sample.outputTime ?? 0),
      ...windows.map(window => window.end ?? 0)
    ),
    continuityViolations
  };
}

function nearestCamera(trajectory, outputTime) {
  let nearest;
  let distance = Infinity;
  for (const sample of trajectory) {
    const candidateDistance = Math.abs(sample.outputTime - outputTime);
    if (candidateDistance < distance) {
      nearest = {x: sample.x, y: sample.y, scale: sample.scale};
      distance = candidateDistance;
    }
  }
  return nearest;
}

function scoreBeat(annotation, camera, previousCamera, canvas, content) {
  const reasons = [];
  const scale = camera.scale;
  const range = annotation.scale ?? defaultScaleRange(annotation.desiredShot);
  if (range.min !== undefined && scale < range.min) reasons.push("scale-too-wide");
  if (range.max !== undefined && scale > range.max) reasons.push("scale-too-tight");

  if (["frame-subject", "keep-visible"].includes(annotation.desiredShot)) {
    const projected = projectNormalizedRect(annotation.subject, camera, canvas, content);
    const visible = intersectionArea(projected, {x: 0, y: 0, width: canvas.width, height: canvas.height});
    const visibleFraction = area(projected) > 0 ? visible / area(projected) : 0;
    const center = {x: projected.x + projected.width / 2, y: projected.y + projected.height / 2};
    const centerDistance = Math.hypot(center.x - canvas.width / 2, center.y - canvas.height / 2)
      / Math.hypot(canvas.width, canvas.height);
    if (visibleFraction < (annotation.visibleFraction ?? 0.95)) reasons.push("subject-cropped");
    // A brief or peripheral subject can be editorially important without
    // justifying a camera move. `keep-visible` encodes that visibility fact
    // independently from the centering/scale taste required by a true shot.
    if (annotation.desiredShot === "frame-subject"
        && centerDistance > (annotation.centerTolerance ?? 0.23)) {
      reasons.push("subject-off-center");
    }
    return {passed: reasons.length === 0, reasons, projectedSubject: projected, visibleFraction, centerDistance};
  }
  if (annotation.desiredShot === "return") {
    const distance = Math.hypot(camera.x - canvas.width / 2, camera.y - canvas.height / 2)
      / Math.hypot(canvas.width, canvas.height);
    if (distance > (annotation.centerTolerance ?? 0.08)) reasons.push("not-reestablished");
  }
  if (annotation.desiredShot === "hold-current") {
    if (!previousCamera) reasons.push("missing-previous-beat");
    else {
      const distance = Math.hypot(camera.x - previousCamera.x, camera.y - previousCamera.y)
        / Math.hypot(canvas.width, canvas.height);
      if (distance > (annotation.centerTolerance ?? 0.06)) reasons.push("unnecessary-pan");
      if (Math.abs(camera.scale - previousCamera.scale) > (annotation.scaleTolerance ?? 0.12)) {
        reasons.push("unnecessary-zoom");
      }
    }
  }
  return {passed: reasons.length === 0, reasons};
}

function defaultScaleRange(desiredShot) {
  if (["overview", "return"].includes(desiredShot)) return {min: 1, max: 1.08};
  if (desiredShot === "frame-subject") return {min: 1.15, max: 2.4};
  if (desiredShot === "keep-visible") return {};
  return {};
}

function projectNormalizedRect(rect, camera, canvas, content) {
  const source = {
    x: content.x + rect.x * content.width,
    y: content.y + (1 - rect.y - rect.height) * content.height,
    width: rect.width * content.width,
    height: rect.height * content.height
  };
  return {
    x: canvas.width / 2 + (source.x - camera.x) * camera.scale,
    y: canvas.height / 2 + (source.y - camera.y) * camera.scale,
    width: source.width * camera.scale,
    height: source.height * camera.scale
  };
}

function area(rect) {
  return Math.max(0, rect.width) * Math.max(0, rect.height);
}

function intersectionArea(a, b) {
  const width = Math.max(0, Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x));
  const height = Math.max(0, Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y));
  return width * height;
}

export function compareToBaseline(
  results,
  baselineCondition = "a-current",
  editorialBaselineCondition = baselineCondition
) {
  const baseline = results.find(result => result.condition === baselineCondition);
  if (!baseline) throw new Error(`${baselineCondition} result is required`);
  const editorialBaseline = results.find(result => result.condition === editorialBaselineCondition);
  if (!editorialBaseline) throw new Error(`${editorialBaselineCondition} result is required`);
  const baselineBeats = new Map(editorialBaseline.score.beats.map(beat => [beat.id, beat]));
  return results.map(result => {
    const corrected = result.score.beats.filter(beat =>
      ["bad", "ambiguous"].includes(beat.baseline)
      && beat.passed && baselineBeats.get(beat.id)?.passed !== true
    ).map(beat => beat.id);
    const regressed = result.score.beats.filter(beat =>
      beat.baseline === "acceptable"
      && !beat.passed && baselineBeats.get(beat.id)?.passed === true
    ).map(beat => beat.id);
    const durationMinutes = Math.max(1 / 60, result.score.duration / 60);
    const addedMovesPerMinute = Math.max(
      0,
      result.score.moveCount - baseline.score.moveCount
    ) / durationMinutes;
    const travelRatio = baseline.score.travel > 0
      ? result.score.travel / baseline.score.travel
      : result.score.travel === 0 ? 1 : Infinity;
    const continuityGatePassed = travelRatio <= 1.25
      && addedMovesPerMinute <= 2
      && result.score.continuityViolations.length === 0;
    const deterministicGatePassed = result.condition !== editorialBaselineCondition
      && result.score.passed > editorialBaseline.score.passed
      && result.score.falseEmphasis <= editorialBaseline.score.falseEmphasis
      && result.score.factualViolations === 0
      && result.score.causalOrderingViolations === 0
      && result.score.emergencyCorrections === 0
      && result.score.coverage.coversFinalAction
      && regressed.length <= 1
      && continuityGatePassed;
    return {
      ...result,
      correctedBaselineBeats: corrected,
      regressedAcceptableBeats: regressed,
      travelRatio,
      addedMovesPerMinute,
      continuityGatePassed,
      deterministicGatePassed
    };
  });
}
