import { spawn } from "node:child_process";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { extractComputerUseEvents, findActiveCodexSession } from "../lib/codex-events.mjs";
import { findScreenshotCoordinateSpace } from "../lib/codex-screenshots.mjs";
import { resolveAccessibilityTarget } from "../lib/accessibility-resolver.mjs";

const outputBase = path.resolve(process.argv[2] ?? "artifacts/recording");
const maximumDuration = Number(process.argv[3] ?? 1800);
if (!Number.isFinite(maximumDuration) || maximumDuration <= 0) {
  throw new Error("Maximum duration must be a positive number of seconds");
}

await mkdir(path.dirname(outputBase), { recursive: true });
const session = await findActiveCodexSession({ cwd: process.cwd() });
const videoPath = `${outputBase}.mov`;
const timelinePath = `${outputBase}.timeline.json`;
const accessibilityPath = `${outputBase}.accessibility.jsonl`;
const semanticObservations = [];
const semanticObserverErrors = [];
const semanticObserver = spawn(
  path.resolve(".build/release/inspect-focused-element"),
  ["com.apple.Safari", "--watch"],
  { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] }
);
readline.createInterface({ input: semanticObserver.stdout, crlfDelay: Infinity }).on("line", line => {
  try {
    semanticObservations.push(JSON.parse(line));
  } catch {
    semanticObserverErrors.push(`Invalid AX observer output: ${line.slice(0, 160)}`);
  }
});
semanticObserver.stderr.on("data", chunk => semanticObserverErrors.push(String(chunk).trim()));
const child = spawn(
  path.resolve(".build/release/capture-safari"),
  [videoPath, String(maximumDuration)],
  { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] }
);

let captureStartedAt;
let captureEndedAt;
let captureWidth;
let captureHeight;
let captureScale;
let captureCodec;
let stopRequested = false;

readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", line => {
  process.stdout.write(`${line}\n`);
  if (line.startsWith("CAPTURE_READY")) {
    captureStartedAt = new Date().toISOString();
    const size = line.match(/size=(\d+)x(\d+)/);
    captureWidth = size ? Number(size[1]) : undefined;
    captureHeight = size ? Number(size[2]) : undefined;
    const scale = line.match(/scale=([\d.]+)/);
    const codec = line.match(/codec=([^\s]+)/);
    captureScale = scale ? Number(scale[1]) : undefined;
    captureCodec = codec?.[1];
    process.stdout.write(
      `RECORDING_READY thread=${session.threadId ?? "unknown"} ` +
      `stop=send-newline maxDuration=${maximumDuration}s output=${videoPath}\n`
    );
  }
  if (line.startsWith("CAPTURE_COMPLETE")) {
    captureEndedAt = new Date().toISOString();
  }
});

child.stderr.on("data", chunk => process.stderr.write(chunk));
process.stdin.setEncoding("utf8");
process.stdin.once("data", () => requestStop());
process.once("SIGINT", requestStop);
process.once("SIGTERM", requestStop);

function requestStop() {
  if (stopRequested || child.exitCode !== null) return;
  stopRequested = true;
  child.kill("SIGINT");
}

const exitCode = await new Promise((resolve, reject) => {
  child.once("error", reject);
  child.once("exit", code => resolve(code ?? 1));
});
await stopSemanticObserver();
if (exitCode !== 0) {
  throw new Error(`capture-safari exited with code ${exitCode}`);
}
if (!captureStartedAt) throw new Error("Capture process never became ready");
captureEndedAt ??= new Date().toISOString();

await new Promise(resolve => setTimeout(resolve, 250));
const extracted = await extractComputerUseEvents({
  sessionFile: session.file,
  captureStartedAt,
  captureEndedAt
});
const screenshotSpace = await findScreenshotCoordinateSpace({
  appName: "Safari",
  referenceTime: new Date(captureEndedAt).getTime()
});
const mappedEvents = extracted.events
  .map(event => mapCoordinates(event, screenshotSpace))
  .map(event => resolveAccessibilityTarget({
    event,
    observations: semanticObservations,
    captureStartedAt,
    captureWidth,
    captureHeight
  }));
const warnings = [
  ...extracted.warnings,
  ...semanticObserverErrors.filter(Boolean).map(message => ({ type: "semantic_observer", message }))
];
const timeline = {
  version: 2,
  capture: {
    video: videoPath,
    startedAt: captureStartedAt,
    endedAt: captureEndedAt,
    width: captureWidth,
    height: captureHeight,
    pointPixelScale: captureScale,
    codec: captureCodec
  },
  introspection: {
    adapter: "codex-rollout-jsonl",
    threadId: session.threadId,
    sessionFile: session.file,
    readOnly: true,
    semanticAdapter: "macos-accessibility-indexed-snapshot",
    semanticObservations: semanticObservations.length,
    semanticObservationsFile: accessibilityPath
  },
  coordinateSpace: {
    input: "computer-use-screenshot-pixels",
    output: "capture-pixels",
    mapping: screenshotSpace ? "normalized-from-passive-screenshot-reference" : "unavailable",
    screenshot: screenshotSpace,
    capture: { width: captureWidth, height: captureHeight, pointPixelScale: captureScale }
  },
  composition: {
    preset: "product-demo",
    cursorScale: 3,
    director: {
      deadTimeRate: 6,
      cursorCompression: 0.1,
      zoomStrength: 1,
      cursorPath: "natural",
      cursorTiltStrength: 1
    }
  },
  events: mappedEvents,
  warnings
};
await writeFile(
  accessibilityPath,
  semanticObservations.map(observation => JSON.stringify(observation)).join("\n") + "\n"
);
await writeFile(timelinePath, `${JSON.stringify(timeline, null, 2)}\n`);
process.stdout.write(
  `RECORDING_COMPLETE video=${videoPath} timeline=${timelinePath} ` +
  `events=${timeline.events.length} warnings=${timeline.warnings.length}\n`
);

function mapCoordinates(event, screenshotSpace) {
  if (!screenshotSpace || !captureWidth || !captureHeight) return event;
  if (event.action === "drag") {
    const { from_x, from_y, to_x, to_y } = event.args ?? {};
    if (![from_x, from_y, to_x, to_y].every(Number.isFinite)) return event;
    return {
      ...event,
      coordinates: {
        from: normalizePoint(from_x, from_y, screenshotSpace),
        to: normalizePoint(to_x, to_y, screenshotSpace)
      }
    };
  }
  const { x, y } = event.args ?? {};
  if (!Number.isFinite(x) || !Number.isFinite(y)) return event;
  return {
    ...event,
    coordinates: normalizePoint(x, y, screenshotSpace)
  };
}

function normalizePoint(x, y, screenshotSpace) {
  const xNorm = x / screenshotSpace.width;
  const yNorm = y / screenshotSpace.height;
  return {
    xNorm,
    yNorm,
    captureX: xNorm * captureWidth,
    captureY: yNorm * captureHeight
  };
}

async function stopSemanticObserver() {
  if (semanticObserver.exitCode !== null) return;
  semanticObserver.kill("SIGINT");
  await Promise.race([
    new Promise(resolve => semanticObserver.once("exit", resolve)),
    new Promise(resolve => setTimeout(resolve, 1500))
  ]);
  if (semanticObserver.exitCode === null) semanticObserver.kill("SIGKILL");
}
