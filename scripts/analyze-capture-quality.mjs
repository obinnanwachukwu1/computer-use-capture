#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { summarizeCaptureLedger } from "../lib/capture-quality.mjs";

const source = path.resolve(process.argv[2] ?? "");
if (!process.argv[2]) {
  throw new Error("Usage: analyze-capture-quality <source.mov> [--output report.json]");
}
const outputIndex = process.argv.indexOf("--output");
const output = outputIndex >= 0 ? path.resolve(process.argv[outputIndex + 1]) : undefined;
const base = source.replace(/\.[^.]+$/, "");
const ledgerPath = `${base}.capture.json`;
const checkpointDirectory = `${base}.capture-checkpoints`;
const ledger = JSON.parse(await readFile(ledgerPath, "utf8"));
const report = {
  version: 1,
  source,
  provenance: ledgerPath,
  geometry: summarizeCaptureLedger(ledger),
  encodedStream: probeVideo(source),
  checkpointComparison: await compareCheckpoints(source, checkpointDirectory)
};
const formatted = `${JSON.stringify(report, null, 2)}\n`;
if (output) await writeFile(output, formatted);
process.stdout.write(formatted);

function probeVideo(file) {
  const result = run("ffprobe", [
    "-v", "error", "-select_streams", "v:0",
    "-show_entries",
    "stream=codec_name,pix_fmt,width,height,avg_frame_rate,r_frame_rate,bit_rate,color_space,color_transfer,color_primaries",
    "-of", "json", file
  ]);
  if (!result.ok) return { available: false, error: result.error };
  return { available: true, ...(JSON.parse(result.stdout).streams?.[0] ?? {}) };
}

async function compareCheckpoints(video, directory) {
  let manifest;
  try {
    manifest = JSON.parse(await readFile(path.join(directory, "checkpoints.json"), "utf8"));
  } catch (error) {
    return { available: false, error: `No checkpoint manifest: ${error.message}` };
  }
  if (!commandAvailable("ffmpeg") || !commandAvailable("magick")) {
    return { available: false, error: "ffmpeg and ImageMagick are required" };
  }
  const temporary = await mkdtemp(path.join(os.tmpdir(), "capture-quality-"));
  try {
    const comparisons = [];
    let previousRaw;
    for (const checkpoint of manifest.checkpoints ?? []) {
      const decoded = path.join(temporary, `decoded-${checkpoint.sequence}.png`);
      const extraction = run("ffmpeg", [
        "-v", "error", "-ss", String(checkpoint.sourceTime), "-i", video,
        "-frames:v", "1", "-y", decoded
      ]);
      if (!extraction.ok) {
        comparisons.push({ ...checkpoint, error: extraction.error });
        continue;
      }
      const raw = path.join(directory, checkpoint.file);
      let rawDeltaNormalized = null;
      if (previousRaw) {
        const rawComparison = run("magick", [
          "compare", "-metric", "RMSE", previousRaw, raw, "null:"
        ], { acceptFailure: true });
        rawDeltaNormalized = parseRMSE(rawComparison.stderr)?.normalized ?? null;
      }
      previousRaw = raw;
      const comparison = run("magick", [
        "compare", "-metric", "RMSE", raw, decoded, "null:"
      ], { acceptFailure: true });
      const rmse = parseRMSE(comparison.stderr);
      comparisons.push({
        sequence: checkpoint.sequence,
        sourceTime: checkpoint.sourceTime,
        raw: checkpoint.file,
        rawDeltaNormalized,
        rmseQuantum: rmse?.quantum ?? null,
        rmseNormalized: rmse?.normalized ?? null,
        ...(rmse ? {} : { error: comparison.error })
      });
    }
    const normalized = comparisons.map(item => item.rmseNormalized).filter(Number.isFinite);
    const rawDeltas = comparisons.map(item => item.rawDeltaNormalized).filter(Number.isFinite);
    return {
      available: true,
      checkpointCount: comparisons.length,
      skippedBusy: manifest.skippedBusy ?? 0,
      checkpointErrors: manifest.errors ?? [],
      rawDeltaNormalized: rawDeltas.length ? {
        min: Math.min(...rawDeltas),
        max: Math.max(...rawDeltas),
        mean: rawDeltas.reduce((sum, value) => sum + value, 0) / rawDeltas.length,
        changedCheckpoints: rawDeltas.filter(value => value > 0).length
      } : null,
      rmseNormalized: normalized.length ? {
        min: Math.min(...normalized),
        max: Math.max(...normalized),
        mean: normalized.reduce((sum, value) => sum + value, 0) / normalized.length
      } : null,
      comparisons
    };
  } finally {
    await rm(temporary, { recursive: true, force: true });
  }
}

function parseRMSE(output) {
  const match = output.match(/([\d.]+) \(([\deE+.-]+)\)/);
  return match ? { quantum: Number(match[1]), normalized: Number(match[2]) } : undefined;
}

function commandAvailable(command) {
  return spawnSync(command, ["-version"], { stdio: "ignore" }).status === 0;
}

function run(command, args, { acceptFailure = false } = {}) {
  const result = spawnSync(command, args, { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
  if (result.error) return { ok: false, error: result.error.message, stdout: "", stderr: "" };
  const ok = result.status === 0 || acceptFailure;
  return {
    ok,
    stdout: result.stdout ?? "",
    stderr: result.stderr ?? "",
    error: ok ? undefined : `${command} exited ${result.status}: ${(result.stderr ?? "").trim()}`
  };
}
