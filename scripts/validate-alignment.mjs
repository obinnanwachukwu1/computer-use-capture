import { readFile } from "node:fs/promises";
import path from "node:path";

const auditPath = path.resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  throw new Error("Usage: node scripts/validate-alignment.mjs <render.camera-audit.json> [render.director.json]");
}
const directorPath = path.resolve(process.argv[3] ?? auditPath.replace(/\.camera-audit\.json$/, ".director.json"));
const [audit, director] = await Promise.all([
  readJSON(auditPath),
  readJSON(directorPath).catch(() => undefined)
]);
const failures = [];
const warnings = [];

if ((audit.pointerEvidence?.unresolved ?? 0) > 0) {
  const total = audit.pointerEvidence.total ?? 0;
  const unresolved = audit.pointerEvidence.unresolved;
  warnings.push(
    `capture evidence is degraded: ${unresolved}/${total} pointer action(s) are unresolved; ` +
    "camera continuity may validate but this is not a reliable planner taste fixture"
  );
}

if (audit.planner?.startsWith("v3") || audit.planner?.startsWith("v4")) {
  const plannerFamily = audit.planner.startsWith("v4") ? "v4" : "v3";
  if (audit.planFeasible !== true) {
    failures.push(`${plannerFamily} camera plan is infeasible${audit.planFailure ? `: ${audit.planFailure}` : ""}`);
  }
  if ((audit.emergencyCorrections ?? 0) !== 0) {
    failures.push(`${plannerFamily} required ${audit.emergencyCorrections} emergency visibility correction(s)`);
  }
}

for (const check of audit.alignment ?? []) {
  const identity = `${check.actionId ?? check.actionID}:${check.check}`;
  if (!check.visible) failures.push(`${identity} is outside the rendered frame at the factual action time`);
  if (!check.safeVisible) warnings.push(`${identity} is visible but outside the preferred 50px safety inset`);
  if (Number.isFinite(check.hotspotError) && check.hotspotError > 1.5) {
    failures.push(`${identity} cursor hotspot misses the logged target by ${check.hotspotError.toFixed(2)}px`);
  }
  if (check.check === "pointer-activation" && check.kind === "click"
      && (!Number.isFinite(check.cursorScale) || Math.abs(check.cursorScale - 0.9) > 0.015)) {
    failures.push(`${identity} click spring is not compressed on the measured activation frame`);
  }
}

for (const move of audit.moves ?? []) {
  const duration = move.end - move.start;
  const distance = Math.hypot(move.translation?.dx ?? 0, move.translation?.dy ?? 0);
  if (move.scaleReversals > 0) failures.push(`${move.label} reverses zoom direction ${move.scaleReversals} time(s)`);
  if (move.xReversals > 0 || move.yReversals > 0) {
    failures.push(`${move.label} reverses camera direction (x=${move.xReversals}, y=${move.yReversals})`);
  }
  if (distance > 5 && move.pathEfficiency < 0.985) {
    failures.push(`${move.label} path efficiency is ${(move.pathEfficiency * 100).toFixed(1)}%, not a straight pan`);
  }
  if (distance > 5 && move.maxLineDeviation > 2) {
    failures.push(`${move.label} deviates ${move.maxLineDeviation.toFixed(1)}px from its direct path`);
  }
  const scale = move.scale ?? {};
  if (Math.abs((scale.start ?? 1) - (scale.end ?? 1)) < 0.02
      && Math.max(Math.abs((scale.maximum ?? 1) - (scale.start ?? 1)), Math.abs((scale.minimum ?? 1) - (scale.start ?? 1))) > 0.04) {
    failures.push(`${move.label} contains a hidden zoom pulse despite equal endpoint scales`);
  }
  if (duration < 0.18 - 1e-6) failures.push(`${move.label} is shorter than the camera continuity floor`);
}

for (const [left, right] of zip(audit.moves ?? [], (audit.moves ?? []).slice(1))) {
  const gap = right.start - left.end;
  const leftVector = left.translation ?? {};
  const rightVector = right.translation ?? {};
  const leftDistance = Math.hypot(leftVector.dx ?? 0, leftVector.dy ?? 0);
  const rightDistance = Math.hypot(rightVector.dx ?? 0, rightVector.dy ?? 0);
  const dot = (leftVector.dx ?? 0) * (rightVector.dx ?? 0)
    + (leftVector.dy ?? 0) * (rightVector.dy ?? 0);
  const intentionalBoundary = isEpisodeBoundary(left) || isEpisodeBoundary(right);
  if (!intentionalBoundary && gap <= 0.7 && leftDistance > 5 && rightDistance > 5 && dot < 0) {
    const cosine = dot / (leftDistance * rightDistance);
    if (cosine < -0.35) {
      failures.push(`${left.label} and ${right.label} reverse camera direction across adjacent segments`);
    }
  }
}

if (director) {
  const renderedActions = (director.actions ?? []).filter(action =>
    action.renderedCursor && ["click", "drag"].includes(action.kind)
  );
  for (const action of renderedActions) {
    const expectedChecks = action.kind === "drag" ? 2 : 1;
    const actualChecks = (audit.alignment ?? []).filter(check => check.actionID === action.id && check.check !== "semantic-bounds").length;
    if (actualChecks !== expectedChecks) {
      failures.push(`${action.actionId ?? action.id} has ${actualChecks}/${expectedChecks} pointer alignment checks`);
    }
  }
  for (const action of director.actions ?? []) {
    const timing = action.timing;
    if (!timing) continue;
    if (Number.isFinite(timing.rawEstimate)
        && (timing.rawEstimate < timing.toolStart - 0.001 || timing.rawEstimate > timing.toolEnd + 0.001)) {
      failures.push(`${action.actionId ?? action.id} raw action estimate is outside its Codex tool envelope`);
    }
    if (Number.isFinite(timing.pointerArrival) && Number.isFinite(timing.activation)
        && timing.pointerArrival > timing.activation + 0.001) {
      failures.push(`${action.actionId ?? action.id} pointer arrives after visual activation`);
    }
    if (timing.source?.startsWith("target-visual") && Number.isFinite(timing.activation)
        && (timing.activation < timing.toolStart - 0.6 || timing.activation > timing.toolEnd + 1.3)) {
      failures.push(`${action.actionId ?? action.id} visual activation falls outside the measured response window`);
    }
    if (timing.source?.startsWith("target-visual")) {
      const clusters = timing.activityClusters ?? [];
      const selected = clusters.find(cluster =>
        timing.activation >= cluster.start - 0.001 && timing.activation <= cluster.end + 0.001
      );
      if (!selected) {
        failures.push(`${action.actionId ?? action.id} visual activation is not supported by a target-local activity cluster`);
      }
      if (timing.source === "target-visual-raw-span") {
        const rawCluster = clusters.find(cluster =>
          cluster.start <= timing.rawEstimate + 0.031 && cluster.end >= timing.rawEstimate - 0.031
        );
        if (!rawCluster) {
          failures.push(`${action.actionId ?? action.id} raw-span timing has no cluster spanning the raw estimate`);
        }
      }
      if (timing.pointerArrivalSource === "activation-cluster-onset" && selected
          && Math.abs(timing.pointerArrival - selected.start) > 0.001) {
        failures.push(`${action.actionId ?? action.id} pointer arrival does not match its selected cluster onset`);
      }
      if (timing.pointerArrivalSource === "activation-relative-fallback") {
        const lead = timing.activation - timing.pointerArrival;
        if (lead < -0.001 || lead > 0.121) {
          failures.push(`${action.actionId ?? action.id} activation-relative pointer lead is outside the shared 0-120ms bound`);
        }
      }
    }
  }
}

const summary = {
  status: failures.length ? "failed" : "passed",
  cameraMoves: audit.moves?.length ?? 0,
  actionChecks: audit.alignment?.length ?? 0,
  failures,
  warnings
};
process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
if (failures.length) process.exitCode = 1;

async function readJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}

function zip(left, right) {
  return left.slice(0, Math.min(left.length, right.length)).map((value, index) => [value, right[index]]);
}

function isEpisodeBoundary(move) {
  return /(?:episode-\d+-end|shot-zoom-out|viewport-relocation-zoom-out|v3-scene-transition|v3-focus-release)/.test(move.label ?? "");
}
