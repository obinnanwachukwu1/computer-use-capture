import { spawn } from "node:child_process";
import { mkdir, readFile, readdir, rename, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..");
const command = process.argv[2];
if (!["update", "verify"].includes(command)) {
  throw new Error("Usage: node scripts/golden-director-plans.mjs <update|verify> [recordingId ...]");
}
const storeRoot = path.resolve(process.env.COMPUTER_USE_CAPTURE_STORE
  ?? path.join(os.homedir(), "Library", "Application Support", "ComputerUseCapture", "projects"));
const requested = process.argv.slice(3);
const recordingIds = requested.length ? requested : (await readdir(storeRoot, { withFileTypes: true }).catch(() => []))
  .filter(entry => entry.isDirectory() && entry.name.startsWith("rec_"))
  .map(entry => entry.name);
let checked = 0;
for (const recordingId of recordingIds) {
  const projectDir = path.join(storeRoot, recordingId);
  const manifest = await readJson(path.join(projectDir, "manifest.json")).catch(() => undefined);
  if (!manifest || manifest.state !== "stopped") continue;
  const output = path.join(projectDir, "renders", ".golden-plan.mp4");
  await run(process.execPath, [
    path.join(repoRoot, "scripts", "compose-recording.mjs"), manifest.base,
    "--output", output, "--plan-only", "--director-debug"
  ]);
  const report = await readJson(output.replace(/\.mp4$/, ".director.json"));
  const snapshot = normalizeReport(report);
  const goldenPath = path.join(projectDir, "golden.director.json");
  if (command === "update") {
    await writeJsonAtomic(goldenPath, snapshot);
    process.stdout.write(`GOLDEN_UPDATED recording=${recordingId} path=${goldenPath}\n`);
  } else {
    const expected = await readJson(goldenPath).catch(() => undefined);
    if (!expected) throw new Error(`Missing golden plan for ${recordingId}; run golden:update first`);
    if (JSON.stringify(expected) !== JSON.stringify(snapshot)) {
      throw new Error(`Director plan changed for ${recordingId}; inspect the new .golden-plan.director.json`);
    }
    process.stdout.write(`GOLDEN_VERIFIED recording=${recordingId}\n`);
  }
  checked += 1;
}
if (!checked) throw new Error("No stopped recordings were available for golden-plan verification");

function normalizeReport(report) {
  const actionIds = new Map((report.actions ?? []).map(action => [action.id, action.actionId]));
  return {
    version: 1,
    output: roundDeep(report.output),
    motion: {
      sampledFrames: report.motion?.sampledFrames ?? 0,
      movingFrames: report.motion?.movingFrames ?? 0,
      components: roundDeep(report.motion?.components ?? [])
    },
    actions: (report.actions ?? []).map(action => roundDeep({
      actionId: action.actionId,
      kind: action.kind,
      sourceTime: action.sourceTime,
      outputTime: action.outputTime,
      provenance: action.pointer?.provenance ?? "unresolved",
      renderedCursor: action.renderedCursor,
      attention: action.attention,
      camera: action.camera,
      timingSource: action.timing?.source
    })),
    shots: (report.shots ?? []).map(shot => roundDeep({
      actionIds: (shot.actionIDs ?? []).map(id => actionIds.get(id) ?? `missing-${id}`),
      start: shot.start,
      end: shot.end,
      baseScale: shot.baseScale
    }))
  };
}

function roundDeep(value) {
  if (typeof value === "number") return Number(value.toFixed(3));
  if (Array.isArray(value)) return value.map(roundDeep);
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).sort(([left], [right]) => left.localeCompare(right))
      .map(([key, item]) => [key, roundDeep(item)]));
  }
  return value;
}

function run(commandName, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(commandName, args, { cwd: repoRoot, stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve() : reject(new Error(`${commandName} exited with ${code}`)));
  });
}

async function readJson(file) { return JSON.parse(await readFile(file, "utf8")); }
async function writeJsonAtomic(file, value) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, file);
}
