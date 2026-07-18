#!/usr/bin/env node
import { copyFile, mkdir, writeFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import { spawn } from "node:child_process";
import {
  artifactPaths, compareToBaseline, readJSON, scoreCameraAudit, validateAnnotations
} from "../lib/camera-evaluation.mjs";

const args = process.argv.slice(2);
const base = args.find(arg => !arg.startsWith("--"));
if (!base) usage("missing recording base path");
const value = flag => {
  const index = args.indexOf(flag);
  return index >= 0 ? args[index + 1] : undefined;
};
const oracle = value("--oracle");
const annotationsPath = value("--annotations");
if (!oracle || !annotationsPath) usage("--oracle and --annotations are required");
const outputDirectory = path.resolve(value("--output") ?? `${path.resolve(base)}.camera-factorial`);
const render = args.includes("--render");
const skipRun = args.includes("--skip-run");
await mkdir(outputDirectory, {recursive: true});
const annotations = validateAnnotations(await readJSON(path.resolve(annotationsPath)));
const allowedConditions = new Set(["a-current", "b-optional-motion", "c-oracle-current", "d-oracle-gated"]);
const conditions = (value("--conditions") ?? "a-current,b-optional-motion,c-oracle-current,d-oracle-gated")
  .split(",")
  .map(condition => condition.trim())
  .filter(Boolean);
if (!conditions.length || conditions.some(condition => !allowedConditions.has(condition))) {
  usage("--conditions must be a comma-separated subset of a-current,b-optional-motion,c-oracle-current,d-oracle-gated");
}
const baselineCondition = value("--baseline") ?? (conditions.includes("a-current") ? "a-current" : conditions[0]);
if (!conditions.includes(baselineCondition)) usage("--baseline must be one of --conditions");
const editorialBaselineCondition = value("--editorial-baseline")
  ?? (conditions.includes("b-optional-motion") ? "b-optional-motion" : baselineCondition);
if (!conditions.includes(editorialBaselineCondition)) {
  usage("--editorial-baseline must be one of --conditions");
}
const results = [];
for (const condition of conditions) {
  const output = path.join(outputDirectory, `${condition}.mp4`);
  let elapsedMs = null;
  if (!skipRun) {
    const composeArgs = [
      "scripts/compose-recording.mjs", path.resolve(base),
      "--output", output,
      "--camera-eval-condition", condition
    ];
    if (args.includes("--director-debug")) composeArgs.push("--director-debug");
    if (args.includes("--experimental-camera-planner")) composeArgs.push("--experimental-camera-planner");
    if (args.includes("--legacy-camera-planner")) composeArgs.push("--legacy-camera-planner");
    if (!render) composeArgs.push("--plan-only");
    if (condition.startsWith("c-") || condition.startsWith("d-")) {
      composeArgs.push("--oracle-support", path.resolve(oracle));
    }
    const started = performance.now();
    await run(process.execPath, composeArgs);
    elapsedMs = performance.now() - started;
  }
  const artifacts = artifactPaths(output);
  const [audit, plan] = await Promise.all([readJSON(artifacts.audit), readJSON(artifacts.plan)]);
  results.push({condition, output, artifacts, elapsedMs, plan, score: scoreCameraAudit(audit, annotations)});
}
const compared = compareToBaseline(results, baselineCondition, editorialBaselineCondition);
const blindConditions = (value("--blind-conditions") ?? "b-optional-motion,d-oracle-gated")
  .split(",").map(condition => condition.trim()).filter(condition => conditions.includes(condition));
const blindReview = render
  ? await prepareBlindReview(compared.filter(row => blindConditions.includes(row.condition)), outputDirectory)
  : null;
const report = {
  version: 1,
  generatedAt: new Date().toISOString(),
  recordingBase: path.resolve(base),
  oracle: path.resolve(oracle),
  annotations: path.resolve(annotationsPath),
  baselineCondition,
  editorialBaselineCondition,
  rendered: render,
  blindReview,
  conditions: compared
};
const reportPath = path.join(outputDirectory, "camera-factorial-report.json");
await writeFile(reportPath, `${JSON.stringify(report, null, 2)}\n`);
await writeFile(path.join(outputDirectory, "camera-factorial-report.md"), markdown(compared));
console.log(`camera factorial report=${reportPath}`);

function run(command, commandArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, {stdio: "inherit", cwd: path.resolve(import.meta.dirname, "..")});
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

function markdown(rows) {
  const lines = [
    "# Camera foreground-support factorial", "",
    `Travel baseline: \`${baselineCondition}\`. Editorial comparison: \`${editorialBaselineCondition}\`.`, "",
    "| Condition | Correct | Final action covered | False emphasis | Corrected editorial beats | Regressed acceptable | Factual violations | Continuity violations | Moves | Added moves/min | Travel vs A | Gate | Elapsed |",
    "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|"
  ];
  for (const row of rows) {
    const elapsed = row.elapsedMs == null ? "cached" : `${(row.elapsedMs / 1000).toFixed(2)}s`;
    lines.push(`| ${row.condition} | ${row.score.passed}/${row.score.total} | ${row.score.coverage.coversFinalAction ? "yes" : "no"} | ${row.score.falseEmphasis} | ${row.correctedBaselineBeats.length} | ${row.regressedAcceptableBeats.length} | ${row.score.factualViolations} | ${row.score.continuityViolations.length} | ${row.score.moveCount} | ${row.addedMovesPerMinute.toFixed(2)} | ${Number.isFinite(row.travelRatio) ? `${row.travelRatio.toFixed(2)}×` : "∞"} | ${row.deterministicGatePassed ? "pass" : "fail"} | ${elapsed} |`);
  }
  lines.push("", "Deterministic scores are a regression gate, not a substitute for blind camera preference review.", "");
  return lines.join("\n");
}

async function prepareBlindReview(rows, directory) {
  const blindDirectory = path.join(directory, "blind-review");
  await mkdir(blindDirectory, {recursive: true});
  const shuffled = [...rows];
  for (let index = shuffled.length - 1; index > 0; index -= 1) {
    const swap = randomBytes(4).readUInt32BE() % (index + 1);
    [shuffled[index], shuffled[swap]] = [shuffled[swap], shuffled[index]];
  }
  const key = [];
  for (const [index, row] of shuffled.entries()) {
    const label = `review-${index + 1}`;
    const destination = path.join(blindDirectory, `${label}.mp4`);
    await copyFile(row.output, destination);
    key.push({label, condition: row.condition, video: destination});
  }
  const keyPath = path.join(blindDirectory, "blind-key.json");
  await writeFile(keyPath, `${JSON.stringify({version: 1, entries: key}, null, 2)}\n`);
  return {directory: blindDirectory, key: keyPath};
}

function usage(message) {
  console.error(message);
  console.error("usage: npm run evaluate:camera -- <recording-base> --oracle fixture.json --annotations annotations.json [--conditions a-current,b-optional-motion,c-oracle-current,d-oracle-gated] [--baseline a-current] [--editorial-baseline b-optional-motion] [--blind-conditions b-optional-motion,d-oracle-gated] [--experimental-camera-planner] [--output directory] [--render] [--skip-run]");
  process.exit(2);
}
