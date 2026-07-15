import { spawn } from "node:child_process";
import { access, mkdir, readdir } from "node:fs/promises";
import path from "node:path";
import { runtimeBinaryPath, runtimeMode, verifyPrebuiltRuntime } from "../lib/runtime-binaries.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
const expectedParentPID = Number(process.env.COMPUTER_USE_CAPTURE_PARENT_PID);
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
  : process.env.COMPUTER_USE_CAPTURE_OUTPUT_SCALE ?? "1";
const verifyAssetsOnly = cliArgs.includes("--verify-assets-only");
if (!verifyAssetsOnly) await Promise.all([access(videoPath), access(timelinePath)]);
if (runtimeMode(repoRoot) === "source") {
  await run("swift", ["build", "-c", "release", "--product", "native-compose"]);
} else {
  await verifyPrebuiltRuntime(repoRoot);
}
const wallpaperIndex = cliArgs.indexOf("--wallpaper");
const backgroundColorIndex = cliArgs.indexOf("--background-color");
const cursorIndex = cliArgs.indexOf("--cursor");
const cursorMetadataIndex = cliArgs.indexOf("--cursor-metadata");
const wallpaperPath = wallpaperIndex >= 0
  ? path.resolve(cliArgs[wallpaperIndex + 1])
  : backgroundColorIndex < 0 ? await ensureSystemWallpaper() : undefined;
const cursorPath = cursorIndex >= 0 ? path.resolve(cliArgs[cursorIndex + 1]) : await ensureMacOSCursor();
const cursorMetadataPath = cursorMetadataIndex >= 0
  ? path.resolve(cliArgs[cursorMetadataIndex + 1])
  : `${cursorPath}.json`;
await Promise.all([
  ...(wallpaperPath ? [access(wallpaperPath)] : []),
  access(cursorPath),
  access(cursorMetadataPath)
]);
const nativeArgs = [
  videoPath,
  timelinePath,
  outputPath,
  "--output-scale", outputScale,
  "--fps", process.env.COMPUTER_USE_CAPTURE_FPS ?? "60",
  "--samples", process.env.COMPUTER_USE_CAPTURE_MOTION_SAMPLES ?? "8",
  "--shutter", process.env.COMPUTER_USE_CAPTURE_SHUTTER ?? "0.55"
];
if (wallpaperPath) nativeArgs.push("--wallpaper", wallpaperPath);
if (backgroundColorIndex >= 0) nativeArgs.push("--background-color", cliArgs[backgroundColorIndex + 1]);
nativeArgs.push("--cursor", cursorPath, "--cursor-metadata", cursorMetadataPath);
if (verifyAssetsOnly) nativeArgs.push("--verify-assets-only");
const keepWaiting = cliArgs.includes("--keep-waiting")
  || process.env.COMPUTER_USE_CAPTURE_REDUCE_WAITING === "0";
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
  : process.env.COMPUTER_USE_CAPTURE_WAITING_TIME_MS;
if (waitingTime !== undefined) nativeArgs.push("--waiting-time", waitingTime);
await run(runtimeBinaryPath(repoRoot, "native-compose"), nativeArgs);

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

async function ensureSystemWallpaper() {
  const destination = path.join(path.dirname(base), "assets", "tahoe-light.jpg");
  try {
    await access(destination);
    return destination;
  } catch {
    // Generate a local still from artwork installed by macOS.
  }
  const source = await systemWallpaperSource();
  await mkdir(path.dirname(destination), { recursive: true });
  await run("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "92", source, "--out", destination]);
  await run("sips", ["-Z", "2400", destination]);
  return destination;
}

async function ensureMacOSCursor() {
  const destination = path.join(path.dirname(base), "assets", "macos-arrow.png");
  try {
    await Promise.all([access(destination), access(`${destination}.json`)]);
    return destination;
  } catch {
    // Generated from the installed macOS cursor artwork and metadata.
  }
  await mkdir(path.dirname(destination), { recursive: true });
  if (runtimeMode(repoRoot) === "source") {
    await run("swift", ["build", "-c", "release", "--product", "export-macos-cursor"]);
  }
  await run(runtimeBinaryPath(repoRoot, "export-macos-cursor"), [destination]);
  return destination;
}

async function systemWallpaperSource() {
  const preferred = [
    "/System/Library/ExtensionKit/Extensions/NeptuneOneWallpaper.appex/Contents/Resources/TahoeLight.heic",
    "/System/Library/Desktop Pictures/Tahoe.heic",
    "/System/Library/Desktop Pictures/Sequoia Sunrise.heic",
    "/System/Library/Desktop Pictures/Sonoma Horizon.heic",
    "/System/Library/Desktop Pictures/Ventura.heic"
  ];
  for (const candidate of preferred) {
    if (await access(candidate).then(() => true).catch(() => false)) return candidate;
  }
  const directory = "/System/Library/Desktop Pictures";
  const names = await readdir(directory).catch(() => []);
  const fallback = names.find(name => /\.(heic|jpg|png)$/i.test(name) && !/(solid|color|calibrat)/i.test(name));
  if (!fallback) throw new Error("macOS did not provide a usable default wallpaper");
  return path.join(directory, fallback);
}
