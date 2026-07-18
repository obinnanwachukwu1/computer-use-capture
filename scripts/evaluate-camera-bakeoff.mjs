#!/usr/bin/env node
import path from "node:path";
import {readFile, writeFile} from "node:fs/promises";
import {
  scoreCameraAudit, structuralCameraMetrics, validateAnnotations
} from "../lib/camera-evaluation.mjs";

const manifestPath = process.argv[2];
if (!manifestPath) {
  console.error("usage: node scripts/evaluate-camera-bakeoff.mjs manifest.json [output.json]");
  process.exit(2);
}
const absoluteManifest = path.resolve(manifestPath);
const root = path.dirname(absoluteManifest);
const manifest = JSON.parse(await readFile(absoluteManifest, "utf8"));
if (manifest?.version !== 1 || !Array.isArray(manifest.recordings)) {
  throw new Error("bake-off manifest must contain version 1 and recordings[]");
}

const resolveFromManifest = value => path.resolve(root, value);
const rows = [];
for (const recording of manifest.recordings) {
  if (!recording.id || !recording.normalAudit || !recording.experimentalAudit) {
    throw new Error("each recording requires id, normalAudit, and experimentalAudit");
  }
  const [normalAudit, experimentalAudit, annotations] = await Promise.all([
    readJSON(resolveFromManifest(recording.normalAudit)),
    readJSON(resolveFromManifest(recording.experimentalAudit)),
    recording.annotations
      ? readJSON(resolveFromManifest(recording.annotations)).then(validateAnnotations)
      : null
  ]);
  const normal = summarize(normalAudit, annotations);
  const experimental = summarize(experimentalAudit, annotations);
  rows.push({
    id: recording.id,
    kind: recording.kind ?? null,
    annotations: recording.annotations ?? null,
    normal,
    experimental,
    delta: {
      moves: experimental.moveCount - normal.moveCount,
      travel: experimental.travel - normal.travel,
      continuity: experimental.continuityViolations.length
        - normal.continuityViolations.length,
      correctBeats: annotations ? experimental.passed - normal.passed : null
    }
  });
}

const report = {
  version: 1,
  generatedAt: new Date().toISOString(),
  manifest: absoluteManifest,
  recordings: rows,
  aggregate: aggregate(rows)
};
const outputPath = path.resolve(process.argv[3] ?? path.join(root, "camera-bakeoff-report.json"));
await writeFile(outputPath, `${JSON.stringify(report, null, 2)}\n`);
await writeFile(outputPath.replace(/\.json$/, ".md"), markdown(report));
console.log(`camera bake-off report=${outputPath}`);

function summarize(audit, annotations) {
  const structural = structuralCameraMetrics(audit);
  const editorial = annotations ? scoreCameraAudit(audit, annotations) : null;
  return {
    planner: audit.planner,
    feasible: audit.planFeasible !== false,
    ...structural,
    passed: editorial?.passed ?? null,
    total: editorial?.total ?? null,
    falseEmphasis: editorial?.falseEmphasis ?? null
  };
}

function aggregate(recordings) {
  const variants = ["normal", "experimental"];
  return Object.fromEntries(variants.map(variant => [variant, recordings.reduce((sum, row) => {
    const value = row[variant];
    sum.moves += value.moveCount;
    sum.travel += value.travel;
    sum.continuity += value.continuityViolations.length;
    sum.factual += value.factualViolations;
    sum.causal += value.causalOrderingViolations;
    sum.emergency += value.emergencyCorrections;
    if (value.passed != null) {
      sum.passed += value.passed;
      sum.total += value.total;
      sum.annotatedRecordings += 1;
    }
    return sum;
  }, {
    moves: 0, travel: 0, continuity: 0, factual: 0, causal: 0,
    emergency: 0, passed: 0, total: 0, annotatedRecordings: 0
  })]));
}

function markdown(report) {
  const lines = [
    "# Production-evidence camera bake-off", "",
    "No oracle support is supplied to either planner.", "",
    "| Recording | Kind | Normal beats | Experimental beats | Moves N→E | Travel N→E | Continuity N→E | Hard violations N→E |",
    "|---|---|---:|---:|---:|---:|---:|---:|"
  ];
  for (const row of report.recordings) {
    const beat = value => value.total == null ? "unannotated" : `${value.passed}/${value.total}`;
    const hard = value => value.factualViolations + value.causalOrderingViolations
      + value.emergencyCorrections;
    lines.push(`| ${row.id} | ${row.kind ?? ""} | ${beat(row.normal)} | ${beat(row.experimental)} | ${row.normal.moveCount}→${row.experimental.moveCount} | ${row.normal.travel.toFixed(1)}→${row.experimental.travel.toFixed(1)} | ${row.normal.continuityViolations.length}→${row.experimental.continuityViolations.length} | ${hard(row.normal)}→${hard(row.experimental)} |`);
  }
  lines.push("", "Structural metrics are gates; unannotated recordings still require visual review.", "");
  return lines.join("\n");
}

async function readJSON(file) {
  return JSON.parse(await readFile(file, "utf8"));
}
