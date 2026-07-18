#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
import path from "node:path";

const [diagnosticArg, reportArg, outputArg] = process.argv.slice(2);
if (!diagnosticArg || !reportArg || !outputArg) {
  console.error("usage: render-dense-motion-transport <dense-field.mp4> <motion-field.json> <output.mp4>");
  process.exit(2);
}
const diagnostic = path.resolve(diagnosticArg);
const report = JSON.parse(readFileSync(path.resolve(reportArg), "utf8"));
const output = path.resolve(outputArg);
const probe = JSON.parse(execFileSync("ffprobe", [
  "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height", "-of", "json", diagnostic
], {encoding: "utf8"}));
const width = probe.streams[0].width;
const height = probe.streams[0].height;
const panelWidth = width / 2;
const legendHeight = 40;
const panelHeight = height - legendHeight;
const colors = ["0x32f5b5", "0x45c8ff", "0xffd24a", "0xff78c6", "0xa68cff"];
const filters = [];

for (const track of report.transportTracks ?? []) {
  const color = colors[track.id % colors.length];
  const samples = track.components;
  for (let index = 0; index < samples.length; index++) {
    const sample = samples[index];
    const previousTime = samples[index - 1]?.time;
    const nextTime = samples[index + 1]?.time;
    const begin = previousTime == null ? sample.time : (previousTime + sample.time) / 2;
    const end = nextTime == null ? sample.time + 1 / 24 : (sample.time + nextTime) / 2;
    const box = sample.bounds;
    const leftX = Math.round(box.x * panelWidth);
    const rightX = Math.round(panelWidth + box.x * panelWidth);
    const y = Math.round(box.y * panelHeight + legendHeight);
    const w = Math.max(2, Math.round(box.width * panelWidth));
    const h = Math.max(2, Math.round(box.height * panelHeight));
    filters.push(
      `drawbox=x=${leftX}:y=${y}:w=${w}:h=${h}:color=${color}@0.22:t=fill:enable='between(t,${begin},${end})'`,
      `drawbox=x=${leftX}:y=${y}:w=${w}:h=${h}:color=${color}@0.92:t=3:enable='between(t,${begin},${end})'`,
      `drawbox=x=${rightX}:y=${y}:w=${w}:h=${h}:color=${color}@0.96:t=4:enable='between(t,${begin},${end})'`,
      `drawtext=text='MOVE ${track.id} CONF ${Math.round(track.confidence * 100)}':x=${Math.max(panelWidth + 2, rightX)}:y=${Math.max(42, y - 20)}:fontsize=15:fontcolor=${color}:borderw=2:bordercolor=black:enable='between(t,${begin},${end})'`
    );
  }
}

execFileSync("ffmpeg", [
  "-hide_banner", "-loglevel", "error", "-i", diagnostic,
  "-vf", filters.join(","),
  "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", "-an", "-y", output
]);
console.log(`wrote dense motion transport to ${output}`);
