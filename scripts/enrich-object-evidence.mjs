import { readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { resolveAccessibilityTargets } from "../lib/accessibility-resolver.mjs";

const input = path.resolve(process.argv[2] ?? "");
const outputIndex = process.argv.indexOf("--output");
const output = outputIndex >= 0 ? path.resolve(process.argv[outputIndex + 1] ?? "") : undefined;
if (!process.argv[2] || !output) {
  throw new Error("Usage: node scripts/enrich-object-evidence.mjs <timeline.json> --output <timeline.json>");
}

const timeline = JSON.parse(await readFile(input, "utf8"));
const accessibilityPath = timeline.introspection?.semanticObservationsFile;
if (!accessibilityPath) throw new Error("Timeline does not reference an accessibility sidecar");
const observations = (await readFile(accessibilityPath, "utf8"))
  .split("\n")
  .filter(Boolean)
  .map(line => JSON.parse(line));
const events = resolveAccessibilityTargets({
  events: timeline.events,
  observations,
  captureStartedAt: timeline.capture.startedAt,
  captureWidth: timeline.capture.width,
  captureHeight: timeline.capture.height
});
await writeFile(output, `${JSON.stringify({...timeline, events}, null, 2)}\n`, {mode: 0o600});
const containers = events.filter(event => event.semanticTarget?.interactionContainer).length;
process.stdout.write(`OBJECT_EVIDENCE_ENRICHED output=${output} events=${events.length} containers=${containers}\n`);
