import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { extractComputerUseEvents } from "../lib/codex-events.mjs";
import { resolveAccessibilityTarget } from "../lib/accessibility-resolver.mjs";

const input = path.resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  throw new Error("Usage: node scripts/reprocess-timeline.mjs <recording-base|timeline.json>");
}
const timelinePath = input.endsWith(".timeline.json") ? input : `${input}.timeline.json`;
const timeline = JSON.parse(await readFile(timelinePath, "utf8"));
const accessibilityPath = timeline.introspection?.semanticObservationsFile;
const sessionFile = timeline.introspection?.sessionFile;
if (!accessibilityPath || !sessionFile) {
  throw new Error("Timeline does not contain its accessibility sidecar and Codex session paths");
}

const observations = (await readFile(accessibilityPath, "utf8"))
  .split("\n")
  .filter(Boolean)
  .map(line => JSON.parse(line));
const extracted = await extractComputerUseEvents({
  sessionFile,
  captureStartedAt: timeline.capture.startedAt,
  captureEndedAt: timeline.capture.endedAt
});
const screenshot = timeline.coordinateSpace?.screenshot;
const captureWidth = timeline.capture.width;
const captureHeight = timeline.capture.height;
const events = extracted.events
  .map(event => mapCoordinates(event, screenshot, captureWidth, captureHeight))
  .map(event => resolveAccessibilityTarget({
    event,
    observations,
    captureStartedAt: timeline.capture.startedAt,
    captureWidth,
    captureHeight
  }));

const observerWarnings = (timeline.warnings ?? []).filter(warning => warning.type === "semantic_observer");
const output = { ...timeline, events, warnings: [...extracted.warnings, ...observerWarnings] };
await writeFile(timelinePath, `${JSON.stringify(output, null, 2)}\n`);

const resolved = events.filter(event => event.targetResolution?.provenance !== "unresolved").length;
const unresolved = events.length - resolved;
process.stdout.write(
  `TIMELINE_REPROCESSED path=${timelinePath} events=${events.length} ` +
  `resolved=${resolved} unresolved=${unresolved} warnings=${output.warnings.length}\n`
);

function mapCoordinates(event, screenshotSpace, width, height) {
  if (!screenshotSpace || !width || !height) return event;
  if (event.action === "drag") {
    const { from_x, from_y, to_x, to_y } = event.args ?? {};
    if (![from_x, from_y, to_x, to_y].every(Number.isFinite)) return event;
    return {
      ...event,
      coordinates: {
        from: normalizePoint(from_x, from_y, screenshotSpace, width, height),
        to: normalizePoint(to_x, to_y, screenshotSpace, width, height)
      }
    };
  }
  const { x, y } = event.args ?? {};
  if (!Number.isFinite(x) || !Number.isFinite(y)) return event;
  return { ...event, coordinates: normalizePoint(x, y, screenshotSpace, width, height) };
}

function normalizePoint(x, y, screenshotSpace, width, height) {
  const xNorm = x / screenshotSpace.width;
  const yNorm = y / screenshotSpace.height;
  return { xNorm, yNorm, captureX: xNorm * width, captureY: yNorm * height };
}
