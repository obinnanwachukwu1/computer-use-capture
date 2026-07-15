import { spawn } from "node:child_process";
import { access, mkdir } from "node:fs/promises";
import path from "node:path";

const repoRoot = path.resolve(import.meta.dirname, "..");
const expectedParentPID = Number(process.env.AGENTRECORDER_PARENT_PID);
if (Number.isInteger(expectedParentPID)) {
  const parentWatch = setInterval(() => {
    if (process.ppid !== expectedParentPID) process.kill(process.pid, "SIGTERM");
  }, 1000);
  parentWatch.unref();
}
const base = path.resolve(process.argv[2] ?? "artifacts/recording");
const videoPath = `${base}.mov`;
const timelinePath = `${base}.timeline.json`;
const cliArgs = process.argv.slice(3);
const outputIndex = cliArgs.indexOf("--output");
const outputPath = outputIndex >= 0 ? path.resolve(cliArgs[outputIndex + 1]) : `${base}.directed.mp4`;
const outputScaleIndex = cliArgs.indexOf("--output-scale");
const outputScale = outputScaleIndex >= 0
  ? cliArgs[outputScaleIndex + 1]
  : process.env.AGENTRECORDER_OUTPUT_SCALE ?? "1";
await Promise.all([access(videoPath), access(timelinePath)]);
await Promise.all([ensureTahoeWallpaper(), ensureMacOSCursor()]);

await run("swift", ["build", "-c", "release", "--product", "native-compose"]);
const nativeArgs = [
  videoPath,
  timelinePath,
  outputPath,
  "--output-scale", outputScale,
  "--fps", process.env.AGENTRECORDER_FPS ?? "60",
  "--samples", process.env.AGENTRECORDER_MOTION_SAMPLES ?? "8",
  "--shutter", process.env.AGENTRECORDER_SHUTTER ?? "0.55"
];
const keepWaiting = cliArgs.includes("--keep-waiting")
  || process.env.AGENTRECORDER_REDUCE_WAITING === "0";
nativeArgs.push(keepWaiting ? "--keep-waiting" : "--reduce-waiting");
if (cliArgs.includes("--director-debug")) nativeArgs.push("--director-debug");
if (cliArgs.includes("--plan-only")) nativeArgs.push("--plan-only");
if (cliArgs.includes("--no-analysis-cache")) nativeArgs.push("--no-analysis-cache");
if (cliArgs.includes("--experimental-camera-planner")) nativeArgs.push("--experimental-camera-planner");
if (cliArgs.includes("--profile")) {
  const index = cliArgs.indexOf("--profile");
  nativeArgs.push("--profile");
  if (cliArgs[index + 1] !== undefined && !cliArgs[index + 1].startsWith("--")) {
    nativeArgs.push(path.resolve(cliArgs[index + 1]));
  }
}
for (const flag of ["--cursor-path", "--cursor-tilt-strength"]) {
  const index = cliArgs.indexOf(flag);
  if (index >= 0 && cliArgs[index + 1] !== undefined) nativeArgs.push(flag, cliArgs[index + 1]);
}
const waitingTimeIndex = cliArgs.indexOf("--waiting-time");
const waitingTime = waitingTimeIndex >= 0
  ? cliArgs[waitingTimeIndex + 1]
  : process.env.AGENTRECORDER_WAITING_TIME_MS;
if (waitingTime !== undefined) nativeArgs.push("--waiting-time", waitingTime);
await run(path.join(repoRoot, ".build/release/native-compose"), nativeArgs);

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: repoRoot, stdio: "inherit" });
    const forward = signal => child.exitCode === null && child.kill(signal);
    const onInterrupt = () => forward("SIGINT");
    const onTerminate = () => forward("SIGTERM");
    process.once("SIGINT", onInterrupt);
    process.once("SIGTERM", onTerminate);
    const cleanup = () => {
      process.off("SIGINT", onInterrupt);
      process.off("SIGTERM", onTerminate);
    };
    child.once("error", reject);
    child.once("exit", code => {
      cleanup();
      code === 0 ? resolve() : reject(new Error(`${command} exited with code ${code}`));
    });
  });
}

async function ensureTahoeWallpaper() {
  const destination = path.join(repoRoot, "artifacts/tahoe-light.jpg");
  try {
    await access(destination);
    return;
  } catch {
    // Generate a local still from the wallpaper installed with macOS Tahoe.
  }
  const source = "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/TahoeLight.heic";
  await mkdir(path.dirname(destination), { recursive: true });
  await access(source);
  await run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", source, "--out", destination]);
  await run("sips", ["-Z", "2400", destination]);
}

async function ensureMacOSCursor() {
  const destination = path.join(repoRoot, "artifacts/macos-arrow.png");
  try {
    await Promise.all([access(destination), access(`${destination}.json`)]);
    return;
  } catch {
    // Generated from the installed macOS cursor artwork and metadata.
  }
  await mkdir(path.dirname(destination), { recursive: true });
  await run("swift", ["build", "-c", "release", "--product", "export-macos-cursor"]);
  await run(path.join(repoRoot, ".build/release/export-macos-cursor"), [destination]);
}
