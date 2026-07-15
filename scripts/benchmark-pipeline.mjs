import { spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..");
const argv = process.argv.slice(2);
const positional = argv.filter((value, index) =>
  !value.startsWith("--") && (index === 0 || !argv[index - 1].startsWith("--"))
);

if (positional.length < 2) {
  console.error("usage: npm run benchmark:pipeline -- <source.mov> <timeline.json> [--mode both|plan|render] [--trials 3] [--planner v3] [--fps 60] [--samples 8] [--analysis-cache warm|cold|off] [--output-scale 1] [--output directory] [--keep-outputs]");
  process.exit(2);
}

const source = path.resolve(positional[0]);
const timeline = path.resolve(positional[1]);
const mode = value("--mode", "both");
const trials = positiveInteger("--trials", 3);
const planner = value("--planner", "v3");
const fps = positiveInteger("--fps", 60);
const samples = positiveInteger("--samples", 8);
const outputScale = positiveInteger("--output-scale", 1);
const analysisCache = value("--analysis-cache", "warm");
if (!["warm", "cold", "off"].includes(analysisCache)) {
  throw new Error("--analysis-cache must be warm, cold, or off");
}
const keepOutputs = argv.includes("--keep-outputs");
const stamp = new Date().toISOString().replaceAll(":", "-").replace(".", "-");
const outputDirectory = path.resolve(value("--output", path.join(repoRoot, ".benchmarks", stamp)));
const modes = mode === "both" ? ["plan", "render"] : [mode];
if (!modes.every(candidate => ["plan", "render"].includes(candidate))) {
  throw new Error("--mode must be both, plan, or render");
}

await mkdir(outputDirectory, { recursive: true });
await run("swift", ["build", "-c", "release", "--product", "native-compose"], { inherit: true });
const binary = path.join(repoRoot, ".build", "release", "native-compose");
const results = [];

if (analysisCache === "warm") {
  const primeOutput = path.join(outputDirectory, "cache-prime.mp4");
  const primeProfile = path.join(outputDirectory, "cache-prime.profile.json");
  await run(binary, [
    source, timeline, primeOutput,
    "--camera-planner", planner,
    "--fps", String(fps),
    "--samples", String(samples),
    "--output-scale", String(outputScale),
    "--profile", primeProfile,
    "--plan-only"
  ]);
}

for (const currentMode of modes) {
  for (let trial = 1; trial <= trials; trial += 1) {
    if (analysisCache === "cold") {
      await rm(`${source}.motion-analysis.cache.json`, { force: true });
    }
    const stem = `${currentMode}-${String(trial).padStart(2, "0")}`;
    const output = path.join(outputDirectory, `${stem}.mp4`);
    const profile = path.join(outputDirectory, `${stem}.profile.json`);
    const composeArgs = [
      source, timeline, output,
      "--camera-planner", planner,
      "--fps", String(fps),
      "--samples", String(samples),
      "--output-scale", String(outputScale),
      "--profile", profile
    ];
    if (analysisCache === "off") composeArgs.push("--no-analysis-cache");
    if (currentMode === "plan") composeArgs.push("--plan-only");
    process.stdout.write(`[${currentMode} ${trial}/${trials}] `);
    const measured = await run("/usr/bin/time", ["-lp", binary, ...composeArgs]);
    const pipeline = JSON.parse(await readFile(profile, "utf8"));
    const metrics = parseTimeMetrics(measured.stderr);
    results.push({ mode: currentMode, trial, metrics, pipeline });
    console.log(`wall=${metrics.realSeconds.toFixed(3)}s pipeline=${pipeline.totalSeconds.toFixed(3)}s peakRSS=${formatBytes(metrics.maximumResidentSetBytes)}`);
    if (!keepOutputs && currentMode === "render") await rm(output, { force: true });
  }
}

const summary = {
  version: 1,
  generatedAt: new Date().toISOString(),
  configuration: { source, timeline, trials, modes, planner, fps, samples, outputScale, analysisCache },
  aggregates: Object.fromEntries(modes.map(currentMode => [currentMode, aggregate(
    results.filter(result => result.mode === currentMode)
  )])),
  trials: results
};
const summaryPath = path.join(outputDirectory, "summary.json");
await writeFile(summaryPath, `${JSON.stringify(summary, null, 2)}\n`);
console.log(`\nsummary=${summaryPath}`);
for (const currentMode of modes) {
  const aggregateResult = summary.aggregates[currentMode];
  console.log(`${currentMode}: median wall=${aggregateResult.wallSeconds.median.toFixed(3)}s CPU=${aggregateResult.cpuSeconds.median.toFixed(3)}s peakRSS=${formatBytes(aggregateResult.peakRSSBytes.median)}`);
  for (const phase of aggregateResult.phases) {
    console.log(`  ${phase.name.padEnd(34)} ${phase.medianSeconds.toFixed(3)}s`);
  }
}

function value(flag, fallback) {
  const index = argv.indexOf(flag);
  return index >= 0 && argv[index + 1] !== undefined ? argv[index + 1] : fallback;
}

function positiveInteger(flag, fallback) {
  const parsed = Number.parseInt(value(flag, String(fallback)), 10);
  if (!Number.isInteger(parsed) || parsed < 1) throw new Error(`${flag} must be a positive integer`);
  return parsed;
}

function run(command, args, { inherit = false } = {}) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: repoRoot, stdio: inherit ? "inherit" : ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    child.stdout?.on("data", chunk => { stdout += chunk; });
    child.stderr?.on("data", chunk => { stderr += chunk; });
    child.once("error", reject);
    child.once("exit", code => {
      if (code === 0) resolve({ stdout, stderr });
      else reject(new Error(`${command} exited with ${code}\n${stdout}\n${stderr}`));
    });
  });
}

function parseTimeMetrics(stderr) {
  const number = label => {
    const escaped = label.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = stderr.match(new RegExp(`^\\s*([0-9.]+)\\s+${escaped}\\s*$`, "m"))
      ?? stderr.match(new RegExp(`^\\s*${escaped}\\s+([0-9.]+)\\s*$`, "m"));
    if (!match) throw new Error(`could not parse ${label} from /usr/bin/time output`);
    return Number(match[1]);
  };
  return {
    realSeconds: number("real"),
    userSeconds: number("user"),
    systemSeconds: number("sys"),
    maximumResidentSetBytes: number("maximum resident set size"),
    peakMemoryFootprintBytes: number("peak memory footprint"),
    instructionsRetired: number("instructions retired"),
    cyclesElapsed: number("cycles elapsed")
  };
}

function aggregate(rows) {
  const phaseNames = [...new Set(rows.flatMap(row => row.pipeline.phases.map(phase => phase.name)))];
  return {
    wallSeconds: stats(rows.map(row => row.metrics.realSeconds)),
    cpuSeconds: stats(rows.map(row => row.metrics.userSeconds + row.metrics.systemSeconds)),
    peakRSSBytes: stats(rows.map(row => row.metrics.maximumResidentSetBytes)),
    pipelineSeconds: stats(rows.map(row => row.pipeline.totalSeconds)),
    phases: phaseNames.map(name => ({
      name,
      medianSeconds: median(rows.map(row => row.pipeline.phases.find(phase => phase.name === name)?.seconds ?? 0))
    }))
  };
}

function stats(values) {
  return { min: Math.min(...values), median: median(values), max: Math.max(...values) };
}

function median(values) {
  const ordered = [...values].sort((a, b) => a - b);
  const middle = Math.floor(ordered.length / 2);
  return ordered.length % 2 ? ordered[middle] : (ordered[middle - 1] + ordered[middle]) / 2;
}

function formatBytes(bytes) {
  return `${(bytes / 1024 / 1024).toFixed(1)} MiB`;
}
