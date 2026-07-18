#!/usr/bin/env node

import {execFileSync} from "node:child_process";
import {readFileSync} from "node:fs";
import path from "node:path";

const [diagnosticArg, reportArg, outputArg] = process.argv.slice(2);
if (!diagnosticArg || !reportArg || !outputArg) {
  console.error("usage: render-dense-motion-objects <dense-field.mp4> <motion-field.json> <output.mp4>");
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
const trackColors = ["0xff4c24", "0x00c4ff", "0xbe50ff", "0x45e08c", "0xffd24a", "0xff78c6", "0x8d7dff", "0x72e6d1"];
const objectStyles = {
  compactObject: {color: "0x33f59b", prefix: "OBJECT"},
  broadContext: {color: "0xffb52e", prefix: "CONTEXT"},
  correlatedChange: {color: "0xaab4c8", prefix: "EVENT"},
};
const filters = [];
const surfaces = new Map((report.objectSurfaces ?? []).map((surface) => [surface.objectID, surface]));

// Exact atomic trajectories remain visible on the evidence half. Their held
// union is deliberately faint; current changed components are bright.
for (const track of report.objectTracks.filter((track) => track.components.length >= 2)) {
  const color = trackColors[track.id % trackColors.length];
  const bounds = track.bounds;
  const x = Math.round(bounds.x * panelWidth);
  const y = Math.round(bounds.y * panelHeight + legendHeight);
  const w = Math.max(2, Math.round(bounds.width * panelWidth));
  const h = Math.max(2, Math.round(bounds.height * panelHeight));
  filters.push(`drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=${color}@0.20:t=2:enable='between(t,${track.startTime},${track.endTime})'`);
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
      `drawtext=text='T${track.id}':x=${Math.max(2, cx)}:y=${Math.max(42, cy - 18)}:fontsize=15:fontcolor=${color}:borderw=2:bordercolor=black:enable='between(t,${begin},${end})'`
    );
  }
}

// Whole-lifecycle ensembles are shown on the source half. These are evidence
// labels, not camera decisions: green is a compact object, amber is broad
// context, and gray is synchronized but too sparse to claim object geometry.
for (const ensemble of report.objectEnsembles) {
  const style = objectStyles[ensemble.kind];
  if (!style) continue;
  const surface = surfaces.get(ensemble.id);
  // Compact-object geometry must be supported by a bidirectional foreground
  // veil. A lifecycle union is identity evidence, not a drawable pose.
  if (ensemble.kind === "compactObject" && (!surface || surface.confidence < 0.55)) continue;
  if (ensemble.kind !== "compactObject" && ensemble.trackIDs.length < 2) continue;
  const bounds = surface?.bounds ?? ensemble.bounds;
  const x = Math.round(panelWidth + bounds.x * panelWidth);
  const y = Math.round(bounds.y * panelHeight + legendHeight);
  const w = Math.max(2, Math.round(bounds.width * panelWidth));
  const h = Math.max(2, Math.round(bounds.height * panelHeight));
  const begin = Math.max(0, ensemble.startTime - 0.11);
  const end = ensemble.endTime + 0.11;
  filters.push(
    `drawbox=x=${x}:y=${y}:w=${w}:h=${h}:color=${style.color}@0.92:t=4:enable='between(t,${begin},${end})'`,
    `drawtext=text='${surface ? "SURFACE" : style.prefix} ${ensemble.id} [${ensemble.trackIDs.join("+")}]':x=${Math.max(panelWidth + 2, x)}:y=${Math.max(42, y - 21)}:fontsize=16:fontcolor=${style.color}:borderw=2:bordercolor=black:enable='between(t,${begin},${end})'`
  );
}

execFileSync("ffmpeg", [
  "-hide_banner", "-loglevel", "error", "-i", diagnostic,
  "-vf", filters.join(","),
  "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
  "-movflags", "+faststart", "-an", "-y", output
]);
console.log(`wrote dense motion objects to ${output}`);
