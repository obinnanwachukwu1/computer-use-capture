#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {mkdirSync, readFileSync, writeFileSync} from "node:fs";
import path from "node:path";

const [sourceArg, reportArg, diagnosticArg, outputArg, timelineArg, offsetArg = "0"] = process.argv.slice(2);
if (!sourceArg || !reportArg || !diagnosticArg || !outputArg) {
  console.error("usage: render-motion-field-blame <source> <motion-field.json> <diagnostic.mp4> <output-dir> [timeline.json] [source-offset-seconds]");
  process.exit(2);
}

const source = path.resolve(sourceArg);
const reportPath = path.resolve(reportArg);
const diagnostic = path.resolve(diagnosticArg);
const output = path.resolve(outputArg);
const sourceOffset = Number(offsetArg);
if (!Number.isFinite(sourceOffset)) throw new Error("source offset must be numeric");
mkdirSync(output, {recursive: true});

const report = JSON.parse(readFileSync(reportPath, "utf8"));
const frames = report.frames.filter((frame) => frame.materialTiles?.length);
const episodes = cluster(frames, 0.36).map((episode, index) => {
  const peak = episode.reduce((best, frame) => score(frame) > score(best) ? frame : best);
  return {index: index + 1, start: episode[0].time, end: episode.at(-1).time, peak, frames: episode};
});
const actions = timelineArg ? loadActions(path.resolve(timelineArg), sourceOffset) : [];
const rows = [];

for (const episode of episodes) {
  const frameIndex = report.frames.findIndex((frame) => frame.time === episode.peak.time);
  const before = report.frames[Math.max(0, frameIndex - 1)]?.time ?? Math.max(0, episode.peak.time - 1 / report.fps);
  const after = episode.peak.time;
  const sourceBefore = report.frames[Math.max(0, frameIndex - 1)]?.sourceTime ?? before;
  const sourceAfter = episode.peak.sourceTime ?? after;
  const nearest = actions
    .map((action) => ({...action, distance: Math.abs(action.time - episode.peak.time)}))
    .sort((left, right) => left.distance - right.distance)[0];
  const attribution = nearest && nearest.distance <= 1.25 ? `${nearest.action} @ ${nearest.time.toFixed(3)}s` : "no nearby Computer Use action";
  const file = `episode-${String(episode.index).padStart(2, "0")}-t${episode.peak.time.toFixed(3)}.jpg`;
  const boxes = episode.peak.materialTiles.map((tile) => {
    const color = ({structural: "red", translation: "cyan", photometric: "magenta", backdrop: "blue"})[tile.channel] ?? "yellow";
    const bounds = tile.bounds;
    return `drawbox=x=iw*${bounds.x}:y=ih*${bounds.y}:w=iw*${bounds.width}:h=ih*${bounds.height}:color=${color}@0.95:t=3`;
  }).join(",");
  const boxed = boxes || "null";
  const label = (text) => `drawtext=text='${escapeText(text)}':x=18:y=14:fontsize=24:fontcolor=white:borderw=2:bordercolor=black`;
  const filter = [
    `[0:v]${boxed},scale=640:-2,pad=640:482:0:40:black,${label(`BEFORE ${before.toFixed(3)}s`)}[before]`,
    `[1:v]split=2[after0][diff1]`,
    `[after0]${boxed},scale=640:-2,pad=640:482:0:40:black,${label(`AFTER ${after.toFixed(3)}s`)}[after]`,
    `[0:v][diff1]blend=all_mode=difference,format=gray,eq=contrast=5:brightness=0.02,format=rgb24,${boxed},scale=640:-2,pad=640:482:0:40:black,${label("RAW ABS DIFF x5")}[diff]`,
    `[2:v]crop=iw/2:ih:0:0,scale=640:482,${label("CLASSIFIED FIELD")}[field]`,
    `[before][after][diff][field]xstack=inputs=4:layout=0_0|640_0|0_482|640_482[out]`
  ].join(";");
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error",
    "-ss", sourceBefore.toFixed(6), "-i", source,
    "-ss", sourceAfter.toFixed(6), "-i", source,
    "-ss", after.toFixed(6), "-i", diagnostic,
    "-filter_complex", filter,
    "-map", "[out]", "-frames:v", "1", "-q:v", "2", "-y", path.join(output, file)
  ]);
  const channelCounts = Object.fromEntries(Object.entries(episode.peak.tileCounts).filter(([key]) => key !== "unchanged-or-subthreshold"));
  rows.push({
    episode: episode.index,
    start: episode.start,
    end: episode.end,
    peak: episode.peak.time,
    score: score(episode.peak),
    attribution,
    nearestActionDistance: nearest?.distance ?? null,
    channelCounts,
    image: file
  });
}

writeFileSync(path.join(output, "manifest.json"), JSON.stringify({version: 1, source, report: reportPath, diagnostic, sourceOffset, rows}, null, 2));
writeFileSync(path.join(output, "index.html"), `<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Dense motion-field blame</title>
<style>
body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#09090b;color:#fafafa;margin:0}main{max-width:1300px;margin:auto;padding:24px}h1{margin:0 0 8px}p{color:#a1a1aa;line-height:1.45}article{border-top:1px solid #27272a;padding:22px 0}img{width:100%;height:auto;border-radius:12px;border:1px solid #27272a}code{color:#fbbf24}dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 12px}dt{color:#a1a1aa}.unattributed{color:#fb7185}
</style><main><h1>Dense motion-field blame</h1>
<p>Every contiguous colored episode is reduced to its strongest frame. This is evidence diagnosis, not a camera result. Boxes show the exact material tiles; the raw difference panel lets us distinguish real pixels from classification or grouping errors.</p>
${rows.map((row) => `<article><h2>Episode ${row.episode}: ${row.start.toFixed(3)}–${row.end.toFixed(3)}s</h2><dl><dt>Peak</dt><dd>${row.peak.toFixed(3)}s</dd><dt>Channels</dt><dd><code>${escapeHTML(JSON.stringify(row.channelCounts))}</code></dd><dt>Attribution</dt><dd class="${row.attribution.startsWith("no nearby") ? "unattributed" : ""}">${row.attribution}</dd></dl><img loading="lazy" src="${row.image}"></article>`).join("\n")}
</main>`);

console.log(`wrote ${rows.length} motion-field blame episodes to ${output}`);

function score(frame) {
  return frame.materialTiles.reduce((total, tile) => total + Math.max(0.05, tile.energy) * Math.max(0.02, tile.changedFraction) * Math.max(0.2, tile.confidence), 0);
}

function cluster(values, maximumGap) {
  const result = [];
  for (const value of values) {
    const current = result.at(-1);
    if (!current || value.time - current.at(-1).time > maximumGap) result.push([value]);
    else current.push(value);
  }
  return result;
}

function loadActions(file, offset) {
  const timeline = JSON.parse(readFileSync(file, "utf8"));
  return (timeline.events ?? [])
    .filter((event) => Number.isFinite(event.time))
    .map((event) => ({action: event.action ?? "action", time: event.time - offset}))
    .filter((event) => event.time >= -2 && event.time <= report.frames.at(-1).time + 2);
}

function escapeText(value) {
  return value.replaceAll("\\", "\\\\").replaceAll(":", "\\:").replaceAll("'", "\\'");
}

function escapeHTML(value) {
  return value.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}
