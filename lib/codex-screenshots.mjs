import { readFile, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const SCREENSHOT_DIRECTORY = path.join(os.tmpdir(), "com.openai.sky.CUAService");

export async function findScreenshotCoordinateSpace({ appName, referenceTime }) {
  return (await findScreenshotCoordinateSpaces({ appName, referenceTimes: [referenceTime] }))[0];
}

export async function findScreenshotCoordinateSpaces({ appName, referenceTimes }) {
  const entries = await readdir(SCREENSHOT_DIRECTORY, { withFileTypes: true }).catch(() => []);
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.startsWith(`${appName} Screenshot `)) continue;
    const file = path.join(SCREENSHOT_DIRECTORY, entry.name);
    const metadata = await stat(file).catch(() => undefined);
    if (metadata) candidates.push({ file, mtimeMs: metadata.mtimeMs });
  }
  const measured = (await Promise.all(candidates.map(async candidate => ({
    ...candidate,
    dimensions: await readImageDimensions(candidate.file).catch(() => undefined)
  })))).filter(candidate => candidate.dimensions);
  return referenceTimes.map(referenceTime => {
    const candidate = measured.toSorted((left, right) =>
      Math.abs(left.mtimeMs - referenceTime) - Math.abs(right.mtimeMs - referenceTime)
    )[0];
    if (!candidate) return undefined;
    const distance = Math.abs(candidate.mtimeMs - referenceTime);
    return {
      ...candidate.dimensions,
      observedAt: new Date(candidate.mtimeMs).toISOString(),
      evidence: candidate.file,
      confidence: distance <= 5_000 ? "event_nearby" : distance <= 60_000 ? "capture_nearby" : "stale",
      ageMs: Math.round(distance)
    };
  });
}

async function readImageDimensions(file) {
  const bytes = await readFile(file);
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))) {
    return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
  }
  if (bytes[0] !== 0xff || bytes[1] !== 0xd8) return undefined;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = bytes[offset + 1];
    if (marker === 0xd9 || marker === 0xda) break;
    const length = bytes.readUInt16BE(offset + 2);
    if (length < 2) break;
    if ([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf].includes(marker)) {
      return {
        width: bytes.readUInt16BE(offset + 7),
        height: bytes.readUInt16BE(offset + 5)
      };
    }
    offset += 2 + length;
  }
  return undefined;
}
