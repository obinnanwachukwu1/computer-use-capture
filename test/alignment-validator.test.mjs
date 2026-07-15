import assert from "node:assert/strict";
import test from "node:test";
import { execFile } from "node:child_process";
import { mkdtemp, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import os from "node:os";
import path from "node:path";

const execFileAsync = promisify(execFile);
const validator = path.resolve("scripts/validate-alignment.mjs");

test("alignment audit rejects a hidden zoom pulse inside a nominal pan", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-alignment-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  await writeFile(auditPath, JSON.stringify({
    version: 2,
    alignment: [],
    moves: [{
      label: "same-shot-pan", start: 1, end: 1.8,
      translation: { dx: 300, dy: 0 },
      scale: { start: 1.58, end: 1.58, minimum: 1, maximum: 1.58 },
      scaleReversals: 1, xReversals: 0, yReversals: 0,
      pathEfficiency: 1, maxLineDeviation: 0
    }]
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  await assert.rejects(
    execFileAsync(process.execPath, [validator, auditPath, directorPath]),
    error => {
      assert.match(error.stdout, /hidden zoom pulse|reverses zoom direction/);
      return true;
    }
  );
});

test("alignment audit requires the click spring and visual cluster to share one activation frame", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-click-phase-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  await writeFile(auditPath, JSON.stringify({
    version: 2,
    alignment: [{
      actionID: 0, actionId: "click-0", kind: "click", check: "pointer-activation",
      visible: true, safeVisible: true, hotspotError: 0, cursorScale: 1
    }],
    moves: []
  }));
  await writeFile(directorPath, JSON.stringify({
    actions: [{
      id: 0, actionId: "click-0", kind: "click", renderedCursor: true,
      timing: {
        rawEstimate: 1.4, toolStart: 1, toolEnd: 2,
        pointerArrival: 1.3, pointerArrivalSource: "activation-relative-fallback",
        activation: 1.6, source: "target-visual",
        activityClusters: [{ start: 1.7, end: 1.8, peak: 2, peakTime: 1.7, count: 2 }]
      }
    }]
  }));
  await assert.rejects(
    execFileAsync(process.execPath, [validator, auditPath, directorPath]),
    error => {
      assert.match(error.stdout, /click spring is not compressed/);
      assert.match(error.stdout, /activation is not supported by a target-local activity cluster/);
      assert.match(error.stdout, /pointer lead is outside the shared 0-120ms bound/);
      return true;
    }
  );
});

test("alignment audit rejects adjacent camera moves that pan out and immediately back", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-camera-detour-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  const move = (label, start, end, dx) => ({
    label, start, end, translation: { dx, dy: 0 },
    scale: { start: 1.25, end: 1.25, minimum: 1.25, maximum: 1.25 },
    scaleReversals: 0, xReversals: 0, yReversals: 0,
    pathEfficiency: 1, maxLineDeviation: 0
  });
  await writeFile(auditPath, JSON.stringify({
    version: 2, alignment: [], windows: [],
    moves: [
      move("route-fit", 1, 1.3, -146),
      move("delayed-focus", 1.3, 1.6, 146)
    ]
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  await assert.rejects(
    execFileAsync(process.execPath, [validator, auditPath, directorPath]),
    error => {
      assert.match(error.stdout, /reverse camera direction across adjacent segments/);
      return true;
    }
  );
});

test("production audit rejects infeasible plans and any renderer visibility correction", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-plan-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  await writeFile(auditPath, JSON.stringify({
    version: 3, planner: "v3-global", planFeasible: false,
    planFailure: "no feasible path", emergencyCorrections: 3,
    alignment: [], moves: []
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  await assert.rejects(
    execFileAsync(process.execPath, [validator, auditPath, directorPath]),
    error => {
      assert.match(error.stdout, /v3 camera plan is infeasible: no feasible path/);
      assert.match(error.stdout, /v3 required 3 emergency visibility correction/);
      return true;
    }
  );
});

test("alignment audit catches a perceptual A-B-A detour separated by a short hold", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-camera-churn-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  const move = (label, start, end, dx) => ({
    label, start, end, translation: { dx, dy: 0 },
    scale: { start: 1.4, end: 1.4, minimum: 1.4, maximum: 1.4 },
    scaleReversals: 0, xReversals: 0, yReversals: 0,
    pathEfficiency: 1, maxLineDeviation: 0
  });
  await writeFile(auditPath, JSON.stringify({
    version: 3, alignment: [], moves: [
      move("action-1-arrival", 1, 1.4, -180),
      move("action-2-arrival", 1.85, 2.25, 180)
    ]
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  await assert.rejects(
    execFileAsync(process.execPath, [validator, auditPath, directorPath]),
    error => {
      assert.match(error.stdout, /reverse camera direction across adjacent segments/);
      return true;
    }
  );
});

test("alignment audit permits an explicit episode return to base", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-camera-boundary-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  const move = (label, start, end, dx) => ({
    label, start, end, translation: { dx, dy: 0 },
    scale: { start: 1.4, end: 1.4, minimum: 1.4, maximum: 1.4 },
    scaleReversals: 0, xReversals: 0, yReversals: 0,
    pathEfficiency: 1, maxLineDeviation: 0
  });
  await writeFile(auditPath, JSON.stringify({
    version: 3, planner: "v3-global", planFeasible: true, emergencyCorrections: 0,
    alignment: [], moves: [
      move("action-1-arrival", 1, 1.4, -180),
      move("episode-0-end", 1.85, 2.25, 180)
    ]
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  const result = await execFileAsync(process.execPath, [validator, auditPath, directorPath]);
  assert.match(result.stdout, /"status": "passed"/);
});

test("alignment audit marks unresolved pointer evidence as a degraded taste fixture", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-evidence-quality-"));
  const auditPath = path.join(directory, "probe.camera-audit.json");
  const directorPath = path.join(directory, "probe.director.json");
  await writeFile(auditPath, JSON.stringify({
    version: 3, planner: "v3-global", planFeasible: true, emergencyCorrections: 0,
    pointerEvidence: { total: 7, factual: 3, inferredRendered: 0, inferredOmitted: 0, unresolved: 4 },
    alignment: [], moves: []
  }));
  await writeFile(directorPath, JSON.stringify({ actions: [] }));
  const result = await execFileAsync(process.execPath, [validator, auditPath, directorPath]);
  assert.match(result.stdout, /"status": "passed"/);
  assert.match(result.stdout, /capture evidence is degraded: 4\/7 pointer action/);
});
