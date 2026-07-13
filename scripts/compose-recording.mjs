import { spawn } from "node:child_process";
import { access } from "node:fs/promises";
import path from "node:path";

const base = path.resolve(process.argv[2] ?? "artifacts/recording");
const videoPath = `${base}.mov`;
const timelinePath = `${base}.timeline.json`;
const outputPath = `${base}.directed.mp4`;
const cliArgs = process.argv.slice(3);
const outputScaleIndex = cliArgs.indexOf("--output-scale");
const outputScale = outputScaleIndex >= 0
  ? cliArgs[outputScaleIndex + 1]
  : process.env.AGENTRECORDER_OUTPUT_SCALE ?? "1";
await Promise.all([access(videoPath), access(timelinePath)]);
await ensureTahoeWallpaper();

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
for (const flag of ["--cursor-path", "--cursor-tilt-strength"]) {
  const index = cliArgs.indexOf(flag);
  if (index >= 0 && cliArgs[index + 1] !== undefined) nativeArgs.push(flag, cliArgs[index + 1]);
}
const waitingTimeIndex = cliArgs.indexOf("--waiting-time");
const waitingTime = waitingTimeIndex >= 0
  ? cliArgs[waitingTimeIndex + 1]
  : process.env.AGENTRECORDER_WAITING_TIME_MS;
if (waitingTime !== undefined) nativeArgs.push("--waiting-time", waitingTime);
await run(path.resolve(".build/release/native-compose"), nativeArgs);

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd: process.cwd(), stdio: "inherit" });
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve() : reject(new Error(`${command} exited with code ${code}`)));
  });
}

async function ensureTahoeWallpaper() {
  const destination = path.resolve("artifacts/tahoe-light.jpg");
  try {
    await access(destination);
    return;
  } catch {
    // Generate a local still from the wallpaper installed with macOS Tahoe.
  }
  const source = "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/TahoeLight.heic";
  await access(source);
  await run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", source, "--out", destination]);
  await run("sips", ["-Z", "2400", destination]);
}
