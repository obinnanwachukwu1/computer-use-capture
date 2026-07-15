import { spawn } from "node:child_process";
import { access, mkdtemp, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..");
const args = process.argv.slice(2);
const plannerFlag = args.indexOf("--planners");
const planners = plannerFlag >= 0
  ? args[plannerFlag + 1].split(",").map(value => value.trim()).filter(Boolean)
  : ["v3", "v4"];
if (!planners.length || planners.some(planner => !["v3", "v4"].includes(planner))) {
  throw new Error("--planners must contain a comma-separated subset of v3,v4");
}
const requested = args.filter((_, index) => index !== plannerFlag && index !== plannerFlag + 1);
const fixtures = requested.length ? requested : [
  "artifacts/native-alignment-rig",
  "artifacts/chrome-pointer-final"
];
const outputRoot = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-comparison-"));
const comparisons = [];

for (const fixture of fixtures) {
  const base = path.resolve(fixture.replace(/\.(?:mov|timeline\.json)$/, ""));
  await Promise.all([access(`${base}.mov`), access(`${base}.timeline.json`)]);
  const plans = {};
  for (const planner of planners) {
    const output = path.join(outputRoot, `${path.basename(base)}-${planner}.mp4`);
    await run(process.execPath, [
      path.join(repoRoot, "scripts", "compose-recording.mjs"), base,
      "--output", output, "--plan-only", "--camera-planner", planner,
      "--director-debug"
    ]);
    const auditPath = output.replace(/\.mp4$/, ".camera-audit.json");
    const directorPath = output.replace(/\.mp4$/, ".director.json");
    const validation = await run(process.execPath, [
      path.join(repoRoot, "scripts", "validate-alignment.mjs"), auditPath, directorPath
    ], { allowFailure: true });
    plans[planner] = summarize(await readJSON(auditPath), validation.code === 0);
  }
  const baseline = plans[planners[0]];
  comparisons.push({
    fixture: path.relative(repoRoot, base),
    ...plans,
    plans,
    deltasFrom: planners[0],
    deltas: Object.fromEntries(planners.slice(1).map(planner => [planner, {
      moves: plans[planner].moves - baseline.moves,
      panTravel: round(plans[planner].panTravel - baseline.panTravel),
      zoomTravel: round(plans[planner].zoomTravel - baseline.zoomTravel),
      emergencyCorrections: plans[planner].emergencyCorrections - baseline.emergencyCorrections,
      pulses: plans[planner].pulses - baseline.pulses,
      readableBeats: plans[planner].readableBeats - baseline.readableBeats
    }]))
  });
}

process.stdout.write(`${JSON.stringify({ outputRoot, planners, comparisons }, null, 2)}\n`);
if (comparisons.some(comparison => !comparison.plans[planners.at(-1)].validationPassed)) {
  process.exitCode = 1;
}

function summarize(audit, validationPassed) {
  const moves = audit.moves ?? [];
  const tracks = audit.tracks ?? [];
  const zoomEdges = moves
    .map(move => {
      const start = Math.max(0.000_001, move.scale?.start ?? 1);
      const end = Math.max(0.000_001, move.scale?.end ?? 1);
      const delta = Math.log(end / start);
      return Math.abs(delta) > 0.0001
        ? { start: move.start ?? 0, end: move.end ?? 0, direction: Math.sign(delta) }
        : null;
    })
    .filter(Boolean);
  const pulses = zoomEdges.slice(1).reduce((count, edge, index) => {
    const previous = zoomEdges[index];
    return count + (edge.start - previous.end < 1.2 && edge.direction !== previous.direction ? 1 : 0);
  }, 0);
  const beatScales = audit.beatScales ?? [];
  return {
    planner: audit.planner,
    feasible: audit.planFeasible,
    validationPassed,
    moves: moves.length,
    tracks: tracks.length,
    shotEvents: moves.length + tracks.length,
    pulses,
    readableBeats: beatScales.filter(beat => (beat.scale ?? 1) >= 1.2).length,
    totalBeats: beatScales.length,
    meanBeatScale: round(beatScales.length
      ? beatScales.reduce((sum, beat) => sum + (beat.scale ?? 1), 0) / beatScales.length
      : 1),
    panTravel: round(moves.reduce((sum, move) =>
      sum + Math.hypot(move.translation?.dx ?? 0, move.translation?.dy ?? 0), 0)),
    zoomTravel: round(moves.reduce((sum, move) => {
      const start = Math.max(0.000_001, move.scale?.start ?? 1);
      const end = Math.max(0.000_001, move.scale?.end ?? 1);
      return sum + Math.abs(Math.log(end / start));
    }, 0)),
    emergencyCorrections: audit.emergencyCorrections ?? 0,
    pointerEvidence: audit.pointerEvidence ?? null,
    rejectedNodes: audit.rejectedNodes ?? 0,
    rejectedEdges: audit.rejectedEdges ?? 0
  };
}

function round(value) { return Number(value.toFixed(3)); }
async function readJSON(file) { return JSON.parse(await readFile(file, "utf8")); }

function run(command, args, { allowFailure = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: repoRoot, stdio: ["ignore", "inherit", "inherit"] });
    child.once("error", reject);
    child.once("exit", code => code === 0 || allowFailure
      ? resolve({ code })
      : reject(new Error(`${command} exited with ${code}`)));
  });
}
