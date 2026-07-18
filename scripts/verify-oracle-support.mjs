#!/usr/bin/env node
import {mkdir, readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import {spawn} from "node:child_process";

const args = process.argv.slice(2);
const source = args[0] && path.resolve(args[0]);
const fixturePath = args[1] && path.resolve(args[1]);
const outputIndex = args.indexOf("--output");
const output = path.resolve(outputIndex >= 0 ? args[outputIndex + 1] : "oracle-support-overlays");
if (!source || !fixturePath) {
  throw new Error("usage: npm run verify:oracle -- source.mov oracle.json [--output directory]");
}

const fixture = JSON.parse(await readFile(fixturePath, "utf8"));
if (fixture.version !== 1
    || fixture.coordinateSpace !== "source-window-normalized-top-left"
    || !Array.isArray(fixture.observations)) {
  throw new Error("unsupported oracle fixture contract");
}
const probe = JSON.parse(await capture("ffprobe", [
  "-v", "error", "-select_streams", "v:0",
  "-show_entries", "stream=width,height,duration",
  "-of", "json", source
]));
const stream = probe.streams?.[0];
if (!stream?.width || !stream?.height) throw new Error("source video has no visual stream");
await mkdir(output, {recursive: true});

const entries = [];
for (const observation of fixture.observations) {
  if (observation.abstained) continue;
  const {x, y, width, height} = observation.bounds;
  if (![x, y, width, height].every(Number.isFinite)) {
    throw new Error(`${observation.id} has invalid bounds`);
  }
  const pixels = {
    x: Math.round(x * stream.width),
    y: Math.round(y * stream.height),
    width: Math.round(width * stream.width),
    height: Math.round(height * stream.height)
  };
  const time = (observation.startTime + observation.endTime) / 2;
  const image = path.join(output, `${safeName(observation.id)}.png`);
  const label = `${observation.id}  source=${pixels.x},${pixels.y} ${pixels.width}x${pixels.height}`
    .replaceAll(":", "\\:").replaceAll("'", "\\'");
  const filter = [
    `drawbox=x=${pixels.x}:y=${pixels.y}:w=${pixels.width}:h=${pixels.height}:color=0x00ff66@0.95:t=4`,
    `drawbox=x=0:y=0:w=iw:h=46:color=black@0.72:t=fill`,
    `drawtext=fontfile=/System/Library/Fonts/SFNS.ttf:text='${label}':x=16:y=11:fontsize=22:fontcolor=white`
  ].join(",");
  await run("ffmpeg", [
    "-loglevel", "error", "-y", "-ss", String(time), "-i", source,
    "-frames:v", "1", "-update", "1", "-vf", filter, image
  ]);
  entries.push({id: observation.id, time, bounds: observation.bounds, pixels, image});
}

const manifest = path.join(output, "manifest.json");
await writeFile(manifest, `${JSON.stringify({
  version: 1,
  source,
  fixture: fixturePath,
  sourceSize: {width: stream.width, height: stream.height},
  entries
}, null, 2)}\n`);
console.log(`oracle support overlays=${output}`);

function safeName(value) {
  return String(value).replaceAll(/[^a-zA-Z0-9._-]/g, "-");
}

function run(command, commandArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, {stdio: ["ignore", "ignore", "inherit"]});
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve() : reject(new Error(`${command} exited with ${code}`)));
  });
}

function capture(command, commandArgs) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, commandArgs, {stdio: ["ignore", "pipe", "inherit"]});
    let stdout = "";
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", chunk => { stdout += chunk; });
    child.once("error", reject);
    child.once("exit", code => code === 0 ? resolve(stdout) : reject(new Error(`${command} exited with ${code}`)));
  });
}
