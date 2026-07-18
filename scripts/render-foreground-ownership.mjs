#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
import path from "node:path";

const [diagnosticArg, reportArg, outputArg] = process.argv.slice(2);
if (!diagnosticArg || !reportArg || !outputArg) {
  console.error("usage: render-foreground-ownership <dense-field.mp4> <motion-field.json> <output.mp4>");
  process.exit(2);
}

const diagnostic = path.resolve(diagnosticArg);
const report = JSON.parse(readFileSync(path.resolve(reportArg), "utf8"));
const ownership = report.foregroundOwnership;
if (!ownership) throw new Error("report does not contain foregroundOwnership");
const output = path.resolve(outputArg);
const probe = JSON.parse(execFileSync("ffprobe", [
  "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", diagnostic
], {encoding: "utf8"}));
const width = probe.streams[0].width;
const height = probe.streams[0].height;
const panelWidth = width / 2;
const legendHeight = 40;
const panelHeight = height - legendHeight;
const frameDuration = 1 / (report.fps || 24);
const filters = [];
const colors = {
  provenance: "0x66ff82",
  inferred: "0x42d7ff",
  ambiguous: "0xffd84a"
};

const motionByID = new Map((report.objectTracks ?? []).map(track => [track.id, track]));
const transportByID = new Map((report.transportTracks ?? []).map(track => [track.id, track]));

for (const lifecycle of ownership.lifecycles ?? []) {
  const box = lifecycle.bounds;
  const x = Math.round(panelWidth + box.x * panelWidth);
  const y = Math.round(legendHeight + box.y * panelHeight);
  const w = Math.max(2, Math.round(box.width * panelWidth));
  const h = Math.max(2, Math.round(box.height * panelHeight));
  filters.push(
    `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=0xff54df@0.96:t=4:enable='between(t,${lifecycle.birthTime},${lifecycle.releaseTime})'`,
    `drawtext=text='SUPPORT ${lifecycle.id}':x=${Math.max(panelWidth + 2, x)}:y=${Math.max(42, y - 20)}:fontsize=15:fontcolor=0xff54df:borderw=2:bordercolor=black:enable='between(t,${lifecycle.birthTime},${lifecycle.releaseTime})'`
  );
}

for (const assignment of ownership.motionAssignments ?? []) {
  if (!colors[assignment.status]) continue;
  const track = motionByID.get(assignment.trackID);
  if (!track) continue;
  drawSamples(track.components ?? [], assignment.status, assignment.lifecycleID, 3);
}
for (const assignment of ownership.transportAssignments ?? []) {
  if (!colors[assignment.status]) continue;
  const track = transportByID.get(assignment.trackID);
  if (!track) continue;
  drawSamples(track.components ?? [], assignment.status, assignment.lifecycleID, 2);
}

function drawSamples(samples, status, lifecycleID, thickness) {
  const color = colors[status];
  for (let index = 0; index < samples.length; index++) {
    const sample = samples[index];
    const previousTime = samples[index - 1]?.time;
    const nextTime = samples[index + 1]?.time;
    const begin = previousTime == null ? sample.time - frameDuration / 2 : (previousTime + sample.time) / 2;
    const end = nextTime == null ? sample.time + frameDuration / 2 : (sample.time + nextTime) / 2;
    const box = sample.bounds;
    const x = Math.round(box.x * panelWidth);
    const y = Math.round(legendHeight + box.y * panelHeight);
    const w = Math.max(2, Math.round(box.width * panelWidth));
    const h = Math.max(2, Math.round(box.height * panelHeight));
    filters.push(
      `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=${color}@0.18:t=fill:enable='between(t,${begin},${end})'`,
      `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=${color}@0.96:t=${thickness}:enable='between(t,${begin},${end})'`
    );
  }
}

filters.push(
  "drawtext=text='GREEN provenance   CYAN retrospective association   YELLOW ambiguous   MAGENTA accepted visible support':x=12:y=13:fontsize=15:fontcolor=white:borderw=2:bordercolor=black"
);

execFileSync("ffmpeg", [
  "-hide_banner", "-loglevel", "error", "-i", diagnostic,
  "-vf", filters.join(","),
  "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", "-an", "-y", output
]);
console.log(`wrote foreground ownership diagnostic to ${output}`);
