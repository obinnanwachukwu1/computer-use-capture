#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {mkdirSync, readFileSync, writeFileSync} from "node:fs";
import path from "node:path";

const [sourceArg, reportArg, outputArg] = process.argv.slice(2);
if (!sourceArg || !reportArg || !outputArg) {
  console.error("usage: render-object-birth-blame <source.mov> <object-births.json> <output-dir>");
  process.exit(2);
}

const source = path.resolve(sourceArg);
const reportPath = path.resolve(reportArg);
const output = path.resolve(outputArg);
mkdirSync(output, {recursive: true});

const probe = JSON.parse(execFileSync("ffprobe", [
  "-v", "error", "-select_streams", "v:0",
  "-show_entries", "stream=width,height,avg_frame_rate",
  "-of", "json", source
], {encoding: "utf8"}));
const stream = probe.streams[0];
const averageFPS = parseRate(stream.avg_frame_rate);
const report = JSON.parse(readFileSync(reportPath, "utf8"));
const unsupported = report.births.filter((birth) => birth.status === "unsupported");
const rows = [];

for (const birth of unsupported) {
  const rect = pixelRect(birth.normalizedBounds, stream.width, stream.height);
  const before = Math.max(0, birth.birthTime - 0.15);
  const after = birth.birthTime + 0.15;
  const filename = `candidate-${birth.candidateID}-t${birth.birthTime.toFixed(3)}.jpg`;
  const target = path.join(output, filename);
  const box = `drawbox=x=${rect.x}:y=${rect.y}:w=${rect.width}:h=${rect.height}:color=red@0.95:t=6`;
  const labels = [
    `drawtext=text='BEFORE ${before.toFixed(3)}s':x=18:y=18:fontsize=30:fontcolor=yellow:borderw=2:bordercolor=black`,
    `drawtext=text='AFTER ${after.toFixed(3)}s':x=18:y=18:fontsize=30:fontcolor=yellow:borderw=2:bordercolor=black`,
    `drawtext=text='ABS DIFF x6':x=18:y=18:fontsize=30:fontcolor=yellow:borderw=2:bordercolor=black`
  ];
  const filter = [
    `[0:v]split=2[b0][bd]`,
    `[1:v]split=2[a0][ad]`,
    `[b0]${box},${labels[0]}[b]`,
    `[a0]${box},${labels[1]}[a]`,
    `[bd][ad]blend=all_mode=difference,eq=contrast=6:brightness=0.03,${box},${labels[2]}[d]`,
    `[b][a][d]hstack=inputs=3,scale=1800:-2[out]`
  ].join(";");
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error",
    "-ss", before.toFixed(6), "-i", source,
    "-ss", after.toFixed(6), "-i", source,
    "-filter_complex", filter,
    "-map", "[out]", "-frames:v", "1", "-q:v", "2", "-y", target
  ]);

  const metricsOutput = execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error",
    "-ss", before.toFixed(6), "-i", source,
    "-ss", after.toFixed(6), "-i", source,
    "-filter_complex",
    `[0:v][1:v]blend=all_mode=difference,crop=${rect.width}:${rect.height}:${rect.x}:${rect.y},signalstats,metadata=print:file=-`,
    "-frames:v", "1", "-f", "null", "-"
  ], {encoding: "utf8"});
  const metrics = Object.fromEntries(
    [...metricsOutput.matchAll(/lavfi\.signalstats\.(YAVG|YMAX|YDIF)=([^\s]+)/g)]
      .map((match) => [match[1], Number(match[2])])
  );
  rows.push({
    ...birth,
    sourceFrameIndex: Math.round(birth.birthTime * averageFPS),
    image: filename,
    pixelBounds: rect,
    rawDelta: metrics
  });
}

writeFileSync(path.join(output, "manifest.json"), JSON.stringify({
  version: 1,
  source,
  report: reportPath,
  frameSize: {width: stream.width, height: stream.height},
  averageFPS,
  sampleOffsetSeconds: 0.15,
  births: rows
}, null, 2));

writeFileSync(path.join(output, "index.html"), `<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Object birth blame</title>
<style>
body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#09090b;color:#fafafa;margin:0}main{max-width:1200px;margin:auto;padding:24px}h1{margin:0 0 8px}p{color:#a1a1aa}article{border-top:1px solid #27272a;padding:22px 0}img{width:100%;height:auto;border-radius:12px;border:1px solid #27272a}code{color:#fbbf24}dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 12px}dt{color:#a1a1aa}
</style><main><h1>Unsupported visual object births</h1>
<p>Every row failed the declarative detector-evidence join. The image compares raw source frames 150 ms before and after the declared birth; the red rectangle is the blamed object region.</p>
${rows.map((row) => `<article><h2>#${row.candidateID} at ${row.birthTime.toFixed(3)}s (source frame ${row.sourceFrameIndex})</h2><dl><dt>Source</dt><dd><code>${row.source}</code></dd><dt>Actions</dt><dd>${row.actionIDs.join(", ") || "visual-only"}</dd><dt>YAVG delta</dt><dd>${row.rawDelta.YAVG ?? "n/a"}</dd><dt>YMAX delta</dt><dd>${row.rawDelta.YMAX ?? "n/a"}</dd></dl><img loading="lazy" src="${row.image}"></article>`).join("\n")}
</main>`);

console.log(`wrote ${rows.length} blamed births to ${output}`);

function pixelRect(bounds, width, height) {
  const x = clamp(Math.floor(bounds.x * width), 0, width - 1);
  const y = clamp(Math.floor(bounds.y * height), 0, height - 1);
  const right = clamp(Math.ceil((bounds.x + bounds.width) * width), x + 1, width);
  const bottom = clamp(Math.ceil((bounds.y + bounds.height) * height), y + 1, height);
  return {x, y, width: right - x, height: bottom - y};
}

function clamp(value, minimum, maximum) {
  return Math.max(minimum, Math.min(maximum, value));
}

function parseRate(value) {
  const [numerator, denominator] = String(value).split("/").map(Number);
  return denominator ? numerator / denominator : numerator;
}
