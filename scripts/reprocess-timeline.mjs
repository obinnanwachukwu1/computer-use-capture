import { readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";
import { extractComputerUseEvents } from "../lib/codex-events.mjs";
import { resolveAccessibilityTarget } from "../lib/accessibility-resolver.mjs";
import { mapEventCoordinates } from "../lib/coordinate-mapper.mjs";
import { redactEventForPersistence } from "../lib/redaction.mjs";

const input = path.resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  throw new Error("Usage: node scripts/reprocess-timeline.mjs <recording-base|timeline.json> [--session-file rollout.jsonl]");
}
const timelinePath = input.endsWith(".timeline.json") ? input : `${input}.timeline.json`;
const timeline = JSON.parse(await readFile(timelinePath, "utf8"));
const accessibilityPath = timeline.introspection?.semanticObservationsFile;
const sessionFlag = process.argv.indexOf("--session-file");
const sessionFile = sessionFlag >= 0 ? path.resolve(process.argv[sessionFlag + 1] ?? "")
  : timeline.introspection?.sessionFile;
if (!accessibilityPath || !sessionFile) {
  throw new Error("Timeline needs its accessibility sidecar and --session-file <rollout.jsonl> (private paths are not persisted by default)");
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
const screenshots = timeline.coordinateSpace?.screenshotEvidence ?? [];
const captureWidth = timeline.capture.width;
const captureHeight = timeline.capture.height;
const events = extracted.events
  .map((event, index) => mapEventCoordinates({
    event,
    screenshotSpace: screenshots[index],
    captureWidth,
    captureHeight,
    observations
  }))
  .map(event => resolveAccessibilityTarget({
    event,
    observations,
    captureStartedAt: timeline.capture.startedAt,
    captureWidth,
    captureHeight
  }))
  .map(redactEventForPersistence);

const observerWarnings = (timeline.warnings ?? []).filter(warning => warning.type === "semantic_observer");
const output = { ...timeline, events, warnings: [...extracted.warnings, ...observerWarnings] };
const temporaryTimeline = `${timelinePath}.tmp-${process.pid}`;
await writeFile(temporaryTimeline, `${JSON.stringify(output, null, 2)}\n`, { mode: 0o600 });
await rename(temporaryTimeline, timelinePath);

const resolved = events.filter(event => event.targetResolution?.provenance !== "unresolved").length;
const unresolved = events.length - resolved;
process.stdout.write(
  `TIMELINE_REPROCESSED path=${timelinePath} events=${events.length} ` +
  `resolved=${resolved} unresolved=${unresolved} warnings=${output.warnings.length}\n`
);
