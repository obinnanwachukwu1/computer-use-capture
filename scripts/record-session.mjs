import { spawn } from "node:child_process";
import { createReadStream, createWriteStream, rmSync } from "node:fs";
import { once } from "node:events";
import { mkdir, rename, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { extractComputerUseEvents, findCodexSessions } from "../lib/codex-events.mjs";
import { findScreenshotCoordinateSpaces } from "../lib/codex-screenshots.mjs";
import { mapEventCoordinates } from "../lib/coordinate-mapper.mjs";
import { resolveAccessibilityTarget } from "../lib/accessibility-resolver.mjs";
import { redactAccessibilityObservation, redactEventForPersistence } from "../lib/redaction.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
const outputBase = path.resolve(process.argv[2] ?? "artifacts/recording");
const maximumDuration = Number(process.argv[3] ?? 1800);
const targetApp = process.argv[4] ?? "com.apple.Safari";
const targetAppName = targetApp.split(".").at(-1);
if (!Number.isFinite(maximumDuration) || maximumDuration <= 0) {
  throw new Error("Maximum duration must be a positive number of seconds");
}

await mkdir(path.dirname(outputBase), { recursive: true });
const explicitSession = process.env.AGENTRECORDER_SESSION_FILE
  ? { file: path.resolve(process.env.AGENTRECORDER_SESSION_FILE), threadId: process.env.AGENTRECORDER_THREAD_ID ?? null }
  : undefined;
const initialCandidates = explicitSession ? [explicitSession]
  : await findCodexSessions({ cwd: process.cwd(), threadId: process.env.AGENTRECORDER_THREAD_ID });
if (!initialCandidates.length) throw new Error(`Could not find a Codex session for ${process.cwd()}`);
let session = initialCandidates[0];
const videoPath = `${outputBase}.mov`;
const timelinePath = `${outputBase}.timeline.json`;
const accessibilityPath = `${outputBase}.accessibility.jsonl`;
const privateAccessibilityPath = `${outputBase}.accessibility.private.tmp`;
const accessibilityStream = createWriteStream(privateAccessibilityPath, { encoding: "utf8", mode: 0o600 });
process.once("exit", () => {
  try { rmSync(privateAccessibilityPath, { force: true }); } catch { /* best-effort crash cleanup */ }
});
let semanticObservationCount = 0;
const semanticObserverErrors = [];
let accessibilityStreamError;
accessibilityStream.on("error", error => {
  accessibilityStreamError = error;
  semanticObserverErrors.push(`AX sidecar write failed: ${error.message}`);
  requestStop();
});
const semanticObserver = spawn(
  path.join(repoRoot, ".build/release/inspect-focused-element"),
  [targetApp, "--watch"],
  { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] }
);
readline.createInterface({ input: semanticObserver.stdout, crlfDelay: Infinity }).on("line", line => {
  try {
    JSON.parse(line);
    semanticObservationCount += 1;
    if (!accessibilityStream.write(`${line}\n`)) {
      semanticObserver.stdout.pause();
      accessibilityStream.once("drain", () => semanticObserver.stdout.resume());
    }
  } catch {
    semanticObserverErrors.push(`Invalid AX observer output: ${line.slice(0, 160)}`);
  }
});
semanticObserver.stderr.on("data", chunk => semanticObserverErrors.push(String(chunk).trim()));
semanticObserver.once("error", error => {
  semanticObserverErrors.push(`AX observer failed to start: ${error.message}`);
  requestStop();
});
const child = spawn(
  path.join(repoRoot, ".build/release/capture-app"),
  [videoPath, String(maximumDuration), targetApp],
  { cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] }
);

let captureStartedAt;
let captureEndedAt;
let captureWidth;
let captureHeight;
let captureScale;
let captureCodec;
let captureReady = false;
let stopRequested = false;
const expectedParentPID = Number(process.env.AGENTRECORDER_PARENT_PID);
if (Number.isInteger(expectedParentPID)) {
  const parentWatch = setInterval(() => {
    if (process.ppid !== expectedParentPID) requestStop();
  }, 1000);
  parentWatch.unref();
}

readline.createInterface({ input: child.stdout, crlfDelay: Infinity }).on("line", line => {
  process.stdout.write(`${line}\n`);
  if (line.startsWith("CAPTURE_READY")) {
    captureReady = true;
    const size = line.match(/size=(\d+)x(\d+)/);
    captureWidth = size ? Number(size[1]) : undefined;
    captureHeight = size ? Number(size[2]) : undefined;
    const scale = line.match(/scale=([\d.]+)/);
    const codec = line.match(/codec=([^\s]+)/);
    captureScale = scale ? Number(scale[1]) : undefined;
    captureCodec = codec?.[1];
  }
  if (line.startsWith("CAPTURE_FRAME") && !captureStartedAt) {
    captureStartedAt = line.match(/wallTime=([^\s]+)/)?.[1] ?? new Date().toISOString();
    process.stdout.write(
      `RECORDING_READY thread=${session.threadId ?? "unknown"} ` +
      `startedAt=${captureStartedAt} stop=send-newline maxDuration=${maximumDuration}s output=${videoPath}\n`
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
  child.once("error", error => {
    stopSemanticObserver().finally(() => reject(error));
  });
  child.once("exit", code => resolve(code ?? 1));
});
await stopSemanticObserver();
await closeAccessibilityStream();
if (exitCode !== 0) {
  throw new Error(`capture-app exited with code ${exitCode}`);
}
if (!captureReady || !captureStartedAt) throw new Error("Capture process never committed a first frame");
captureEndedAt ??= new Date().toISOString();

const finalCandidates = explicitSession ? [explicitSession]
  : await findCodexSessions({ cwd: process.cwd(), threadId: process.env.AGENTRECORDER_THREAD_ID });
const settleResults = await Promise.all(finalCandidates.map(candidate => waitForFileQuiescence(candidate.file)));
const candidateExtractions = await Promise.all(finalCandidates.map(async candidate => ({
  candidate,
  extracted: await extractComputerUseEvents({ sessionFile: candidate.file, captureStartedAt, captureEndedAt })
})));
const activeExtractions = candidateExtractions.filter(item => item.extracted.events.length > 0);
const ambiguous = activeExtractions.length > 1;
if (activeExtractions.length === 1) session = activeExtractions[0].candidate;
const extracted = ambiguous
  ? {
      events: [],
      warnings: [{
        type: "introspection_ambiguous",
        message: "Multiple Codex sessions in this working directory emitted Computer Use actions during capture",
        ...(process.env.AGENTRECORDER_PERSIST_PRIVATE_PATHS === "1"
          ? { threadIds: activeExtractions.map(item => item.candidate.threadId) }
          : { sessionCount: activeExtractions.length })
      }],
      adapter: { status: "degraded", formatFingerprint: "ambiguous", observedShapes: [] }
    }
  : (activeExtractions[0]?.extracted ?? candidateExtractions[0].extracted);
const semanticObservations = await processAccessibilitySidecar({
  privatePath: privateAccessibilityPath,
  publicPath: accessibilityPath,
  events: extracted.events,
  captureStartedAt
});
const reconstruction = {
  status: ambiguous ? "ambiguous"
    : settleResults.some(result => result.status === "truncated") ? "truncated" : "settled",
  candidateSessions: finalCandidates.length,
  activeSessions: activeExtractions.length,
  settleWaitMs: Math.max(0, ...settleResults.map(result => result.waitedMs))
};
const screenshotSpaces = await findScreenshotCoordinateSpaces({
  appName: targetAppName,
  referenceTimes: extracted.events.map(event => Date.parse(event.timestamp))
});
const mappedEvents = extracted.events
  .map((event, index) => mapEventCoordinates({
    event,
    screenshotSpace: screenshotSpaces[index],
    captureWidth,
    captureHeight,
    observations: semanticObservations
  }))
  .map(event => resolveAccessibilityTarget({
    event,
    observations: semanticObservations,
    captureStartedAt,
    captureWidth,
    captureHeight
  }))
  .map(redactEventForPersistence);
const occlusionSpans = frontmostOcclusionSpans(semanticObservations, captureStartedAt, captureEndedAt);
const warnings = [
  ...extracted.warnings,
  ...mappedEvents.filter(event => event.coordinateResolution?.provenance === "unresolved")
    .map(event => ({ type: "coordinate_unresolved", actionId: event.actionId, message: event.coordinateResolution.reason })),
  ...semanticObserverErrors.filter(Boolean).map(message => ({ type: "semantic_observer", message })),
  ...occlusionSpans.map(span => ({
    type: "system_ui_occlusion",
    atMs: Math.round(span.startTime * 1000),
    message: `The target app was not frontmost for ${Math.round((span.endTime - span.startTime) * 1000)}ms; pointer reconstruction fails closed in this span`
  }))
];
const timeline = {
  version: 3,
  capture: {
    app: targetApp,
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
    adapterStatus: extracted.adapter,
    sessionBinding: process.env.AGENTRECORDER_THREAD_ID ? "explicit" : ambiguous ? "ambiguous" : "auto-resolved",
    ...(process.env.AGENTRECORDER_PERSIST_PRIVATE_PATHS === "1" ? { threadId: session.threadId } : {}),
    ...(process.env.AGENTRECORDER_PERSIST_PRIVATE_PATHS === "1" ? { sessionFile: session.file } : {}),
    reconstruction,
    readOnly: true,
    semanticAdapter: "macos-accessibility-indexed-snapshot",
    semanticObservations: semanticObservationCount,
    semanticObservationsFile: accessibilityPath
  },
  coordinateSpace: {
    input: "computer-use-screenshot-pixels",
    output: "capture-pixels",
    mapping: "per-event-passive-screenshot-reference",
    screenshotEvidence: screenshotSpaces.map(space => space
      ? { observedAt: space.observedAt, width: space.width, height: space.height, confidence: space.confidence, ageMs: space.ageMs }
      : null),
    capture: { width: captureWidth, height: captureHeight, pointPixelScale: captureScale }
  },
  occlusionSpans,
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
await rm(privateAccessibilityPath, { force: true });
await writeJSONAtomic(timelinePath, timeline);
process.stdout.write(
  `RECORDING_COMPLETE video=${videoPath} timeline=${timelinePath} ` +
  `events=${timeline.events.length} warnings=${timeline.warnings.length}\n`
);

async function stopSemanticObserver() {
  if (semanticObserver.exitCode !== null) return;
  semanticObserver.kill("SIGINT");
  await Promise.race([
    new Promise(resolve => semanticObserver.once("exit", resolve)),
    new Promise(resolve => setTimeout(resolve, 1500))
  ]);
  if (semanticObserver.exitCode === null) semanticObserver.kill("SIGKILL");
}

async function closeAccessibilityStream() {
  if (accessibilityStreamError) throw accessibilityStreamError;
  if (accessibilityStream.closed) return;
  await new Promise((resolve, reject) => {
    accessibilityStream.once("close", resolve);
    accessibilityStream.end();
  });
  if (accessibilityStreamError) throw accessibilityStreamError;
}

async function processAccessibilitySidecar({ privatePath, publicPath, events, captureStartedAt }) {
  const temporary = `${publicPath}.tmp-${process.pid}`;
  const output = createWriteStream(temporary, { encoding: "utf8", mode: 0o600 });
  let outputError;
  output.on("error", error => { outputError = error; });
  const input = readline.createInterface({
    input: createReadStream(privatePath, { encoding: "utf8" }),
    crlfDelay: Infinity
  });
  const windows = events.map(event => ({
    start: Date.parse(event.timing?.toolCallStartedAt ?? event.timestamp) - 1500,
    action: Date.parse(event.timing?.toolCallStartedAt ?? event.timestamp),
    end: Date.parse(event.timing?.toolCallEndedAt ?? event.timestamp) + 750,
    latestBefore: undefined
  }));
  const selected = new Map();
  let previousSystemSurface;
  let firstGeometryRetained = false;
  for await (const line of input) {
    let observation;
    try { observation = JSON.parse(line); } catch { continue; }
    const observedAt = Date.parse(observation.observedAt);
    const redactedLine = `${JSON.stringify(redactAccessibilityObservation(observation))}\n`;
    if (!output.write(redactedLine)) await once(output, "drain");
    if (outputError) throw outputError;
    const key = `${observation.observedAt}:${selected.size}`;
    if (!firstGeometryRetained && observation.windowBounds) {
      selected.set(key, observation);
      firstGeometryRetained = true;
    }
    if (previousSystemSurface !== observation.frontmostIsSystemSurface) {
      selected.set(key, observation);
      previousSystemSurface = observation.frontmostIsSystemSurface;
    }
    for (const window of windows) {
      if (!Number.isFinite(observedAt)) continue;
      if (observedAt >= Date.parse(captureStartedAt) && observedAt <= window.action
          && observation.frontmostIsSystemSurface !== true && observation.treeComplete !== false) {
        window.latestBefore = observation;
      }
      if (observedAt >= window.start && observedAt <= window.end) selected.set(key, observation);
    }
  }
  for (const window of windows) {
    if (window.latestBefore) selected.set(`latest:${window.latestBefore.observedAt}`, window.latestBefore);
  }
  output.end();
  await once(output, "close");
  if (outputError) throw outputError;
  await rename(temporary, publicPath);
  return [...selected.values()].toSorted((left, right) => Date.parse(left.observedAt) - Date.parse(right.observedAt));
}

async function writeJSONAtomic(file, value) {
  const temporary = `${file}.tmp-${process.pid}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, file);
}

async function waitForFileQuiescence(file, { stableMs = 1200, timeoutMs = 5000 } = {}) {
  const started = Date.now();
  let last = await stat(file).catch(() => undefined);
  let stableSince = Date.now();
  while (Date.now() - started < timeoutMs) {
    await new Promise(resolve => setTimeout(resolve, 200));
    const current = await stat(file).catch(() => undefined);
    if (!current || !last || current.size !== last.size || current.mtimeMs !== last.mtimeMs) {
      stableSince = Date.now();
      last = current;
      continue;
    }
    if (Date.now() - stableSince >= stableMs) return { status: "settled", waitedMs: Date.now() - started };
  }
  return { status: "truncated", waitedMs: Date.now() - started };
}

function frontmostOcclusionSpans(observations, captureStartedAt, captureEndedAt) {
  const captureStartMs = Date.parse(captureStartedAt);
  const captureEndMs = Date.parse(captureEndedAt);
  const samples = observations
    .filter(observation => Number.isFinite(Date.parse(observation.observedAt)))
    .toSorted((left, right) => Date.parse(left.observedAt) - Date.parse(right.observedAt));
  const spans = [];
  let open;
  for (let index = 0; index < samples.length; index += 1) {
    const sample = samples[index];
    const at = Math.min(captureEndMs, Math.max(captureStartMs, Date.parse(sample.observedAt)));
    if (sample.frontmostIsSystemSurface === true && !open) {
      open = { startMs: at, frontmostBundleIdentifier: sample.frontmostBundleIdentifier };
    }
    if (sample.frontmostIsSystemSurface !== true && open) {
      spans.push({ ...open, endMs: at });
      open = undefined;
    }
  }
  if (open) spans.push({ ...open, endMs: captureEndMs });
  return spans.filter(span => span.endMs > span.startMs).map(span => ({
    startTime: (span.startMs - captureStartMs) / 1000,
    endTime: (span.endMs - captureStartMs) / 1000,
    frontmostBundleIdentifier: span.frontmostBundleIdentifier ?? "unknown",
    evidence: "macos-frontmost-application"
  }));
}
