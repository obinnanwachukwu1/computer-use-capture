#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {mkdirSync, readFileSync, writeFileSync} from "node:fs";
import path from "node:path";

const [sourceArg, reportArg, outputArg] = process.argv.slice(2);
if (!sourceArg || !reportArg || !outputArg) {
  console.error("usage: render-foreground-support-blame <source.mov> <motion-field.json> <output-dir>");
  process.exit(2);
}

const source = path.resolve(sourceArg);
const reportPath = path.resolve(reportArg);
const output = path.resolve(outputArg);
mkdirSync(output, {recursive: true});
const report = JSON.parse(readFileSync(reportPath, "utf8"));
const ownership = report.foregroundOwnership;
if (!ownership) throw new Error("report does not contain foregroundOwnership");

const tracks = new Map((report.objectTracks ?? []).map(track => [track.id, track]));
const tileBounds = new Map();
for (const frame of report.frames ?? []) {
  for (const tile of frame.materialTiles ?? []) tileBounds.set(tile.index, tile.bounds);
}

const rows = [];
for (const lifecycle of ownership.lifecycles ?? []) {
  const before = frameBefore(lifecycle.birthTime);
  const birth = frameAfter(lifecycle.birthTime);
  const held = frameNearest(lifecycle.heldTime);
  const release = frameAfter(lifecycle.releaseTime);
  const samples = [
    {name: "BEFORE", frame: before, time: before.time},
    {name: "BIRTH", frame: birth, time: birth.time},
    {name: "HELD", frame: held, time: held.time},
    {name: "AFTER RELEASE", frame: release, time: release.time}
  ];
  const supportArea = lifecycle.bounds.width * lifecycle.bounds.height;
  const provenanceTracks = lifecycle.motionTrackIDs
    .map(id => tracks.get(id))
    .filter(Boolean);
  const widestTrack = provenanceTracks.reduce((best, track) => {
    const area = track.bounds.width * track.bounds.height;
    return !best || area > best.area ? {track, area} : best;
  }, null);
  const trackArea = widestTrack?.area ?? 0;
  const symptoms = [];
  if (supportArea < 0.002) symptoms.push("microscopic-support");
  if (lifecycle.supportConfidence < 0.25) symptoms.push("low-confidence");
  if (widestTrack && ((widestTrack.track.bounds.width > 0.72 && widestTrack.track.bounds.height < 0.30)
      || (widestTrack.track.bounds.height > 0.72 && widestTrack.track.bounds.width < 0.30))) {
    symptoms.push("thin-context-strip");
  }
  if (trackArea > 0 && supportArea / trackArea < 0.14) symptoms.push("support-track-geometry-mismatch");
  if (lifecycle.supportingEvidenceStart < lifecycle.birthTime - 0.5
      || lifecycle.supportingEvidenceEnd > lifecycle.releaseTime + 0.5) {
    symptoms.push("ownership-extends-lifecycle");
  }

  const file = `support-${String(lifecycle.id).padStart(2, "0")}-t${lifecycle.birthTime.toFixed(3)}.jpg`;
  const inputs = samples.flatMap(sample => ["-ss", sample.frame.sourceTime.toFixed(6), "-i", source]);
  const filters = samples.map((sample, index) => {
    const provenanceTiles = provenanceTracks.flatMap(track => nearestComponents(track, sample.time)
      .flatMap(component => component.tileIndices ?? []));
    const overlay = [
      ...drawTiles(provenanceTiles, "0x66ff82", 2),
      ...drawTiles(lifecycle.tileIndices, "0xff54df", 3),
      drawBox(lifecycle.bounds, "0xff54df", 4),
      `drawtext=text='${escapeText(`${sample.name} ${sample.time.toFixed(3)}s`)}':x=16:y=12:fontsize=22:fontcolor=white:borderw=2:bordercolor=black`,
      `drawtext=text='support ${lifecycle.id} conf ${lifecycle.supportConfidence.toFixed(2)}':x=16:y=444:fontsize=18:fontcolor=0xff54df:borderw=2:bordercolor=black`
    ].filter(Boolean).join(",");
    return `[${index}:v]${overlay},scale=640:-2,pad=640:482:0:40:black[p${index}]`;
  });
  filters.push("[p0][p1][p2][p3]xstack=inputs=4:layout=0_0|640_0|0_482|640_482[out]");
  execFileSync("ffmpeg", [
    "-hide_banner", "-loglevel", "error", ...inputs,
    "-filter_complex", filters.join(";"),
    "-map", "[out]", "-frames:v", "1", "-q:v", "2", "-y", path.join(output, file)
  ]);
  rows.push({
    id: lifecycle.id,
    birthTime: lifecycle.birthTime,
    heldTime: lifecycle.heldTime,
    releaseTime: lifecycle.releaseTime,
    supportConfidence: lifecycle.supportConfidence,
    supportArea,
    supportTileCount: lifecycle.tileIndices.length,
    motionTrackIDs: lifecycle.motionTrackIDs,
    transportTrackIDs: lifecycle.transportTrackIDs,
    largestProvenanceTrackArea: trackArea,
    symptoms,
    image: file
  });
}

writeFileSync(path.join(output, "manifest.json"), JSON.stringify({
  version: 1,
  source,
  report: reportPath,
  legend: {green: "provenance motion tiles", magenta: "accepted visible-support tiles and bounds"},
  rows
}, null, 2));
writeFileSync(path.join(output, "index.html"), `<!doctype html>
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Foreground-support blame</title>
<style>
body{font:15px -apple-system,BlinkMacSystemFont,sans-serif;background:#09090b;color:#fafafa;margin:0}main{max-width:1300px;margin:auto;padding:24px}h1{margin:0 0 8px}p{color:#a1a1aa;line-height:1.45}article{border-top:1px solid #27272a;padding:22px 0}img{width:100%;height:auto;border-radius:12px;border:1px solid #27272a}code{color:#fbbf24}dl{display:grid;grid-template-columns:max-content 1fr;gap:4px 12px}dt{color:#a1a1aa}.bad{color:#fb7185}
</style><main><h1>Foreground-support blame</h1>
<p>Every accepted lifecycle at before, birth, held, and release. Green is the exact provenance motion mask; magenta is the exact accepted visible-support mask and its derived bounds. Symptom labels are declarative audit findings, not detector corrections.</p>
${rows.map(row => `<article><h2>Support ${row.id}: ${row.birthTime.toFixed(3)}–${row.releaseTime.toFixed(3)}s</h2><dl><dt>Confidence</dt><dd>${row.supportConfidence.toFixed(3)}</dd><dt>Support area</dt><dd>${(row.supportArea * 100).toFixed(3)}% (${row.supportTileCount} tiles)</dd><dt>Provenance tracks</dt><dd><code>${row.motionTrackIDs.join(", ") || "none"}</code></dd><dt>Symptoms</dt><dd class="${row.symptoms.length ? "bad" : ""}">${row.symptoms.join(", ") || "none"}</dd></dl><img loading="lazy" src="${row.image}"></article>`).join("\n")}
</main>`);
console.log(`wrote ${rows.length} foreground-support blame rows to ${output}`);

function frameBefore(time) {
  return [...report.frames].reverse().find(frame => frame.time < time - 0.0001) ?? report.frames[0];
}
function frameAfter(time) {
  return report.frames.find(frame => frame.time > time + 0.0001) ?? report.frames.at(-1);
}
function frameNearest(time) {
  return report.frames.reduce((best, frame) => Math.abs(frame.time - time) < Math.abs(best.time - time) ? frame : best);
}
function nearestComponents(track, time) {
  if (!track.components?.length) return [];
  const distance = Math.min(...track.components.map(component => Math.abs(component.time - time)));
  if (distance > 0.12) return [];
  return track.components.filter(component => Math.abs(component.time - time) <= distance + 0.0001);
}
function drawTiles(indices, color, thickness) {
  return [...new Set(indices)].map(index => tileBounds.get(index)).filter(Boolean).map(bounds => drawBox(bounds, color, thickness));
}
function drawBox(bounds, color, thickness) {
  if (!bounds) return "";
  return `drawbox=x=iw*${bounds.x}:y=ih*${bounds.y}:w=iw*${bounds.width}:h=ih*${bounds.height}:color=${color}@0.96:t=${thickness}`;
}
function escapeText(value) {
  return value.replaceAll("\\", "\\\\").replaceAll(":", "\\:").replaceAll("'", "\\'");
}
