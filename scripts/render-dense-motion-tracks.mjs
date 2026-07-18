#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
import path from "node:path";

const [diagnosticArg, reportArg, outputArg] = process.argv.slice(2);
if (!diagnosticArg || !reportArg || !outputArg) {
  console.error("usage: render-dense-motion-tracks <dense-field.mp4> <motion-field.json> <output.mp4>");
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
const colors = ["0xff4c24", "0x00c4ff", "0xbe50ff", "0x45e08c", "0xffd24a", "0xff78c6", "0x8d7dff", "0x72e6d1"];
const filters = [];

for (const track of report.objectTracks.filter((track) => track.components.length >= 2)) {
  const color = colors[track.id % colors.length];
  const bounds = track.bounds;
  const x = Math.round(bounds.x * panelWidth);
  const y = Math.round(bounds.y * panelHeight + legendHeight);
  const w = Math.max(2, Math.round(bounds.width * panelWidth));
  const h = Math.max(2, Math.round(bounds.height * panelHeight));
  filters.push(
    `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=${color}@0.30:t=2:enable='between(t,${track.startTime},${track.endTime})'`
  );
  for (const component of track.components) {
    const box = component.bounds;
    const cx = Math.round(box.x * panelWidth);
    const cy = Math.round(box.y * panelHeight + legendHeight);
    const cw = Math.max(2, Math.round(box.width * panelWidth));
    const ch = Math.max(2, Math.round(box.height * panelHeight));
    const begin = Math.max(0, component.time - 0.10);
    const end = component.time + 0.10;
    filters.push(
      `drawbox=x=${cx}:y=${cy}:w=${cw}:h=${ch}:color=${color}@0.95:t=3:enable='between(t,${begin},${end})'`,
      `drawtext=text='T${track.id}':x=${Math.max(2, cx)}:y=${Math.max(42, cy - 18)}:fontsize=16:fontcolor=${color}:borderw=2:bordercolor=black:enable='between(t,${begin},${end})'`
    );
  }
}

execFileSync("ffmpeg", [
  "-hide_banner", "-loglevel", "error", "-i", diagnostic,
  "-vf", filters.join(","),
  "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", "-an", "-y", output
]);
console.log(`wrote dense motion tracks to ${output}`);
