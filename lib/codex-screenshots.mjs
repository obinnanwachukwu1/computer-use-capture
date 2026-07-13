import { readFile, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const SCREENSHOT_DIRECTORY = path.join(os.tmpdir(), "com.openai.sky.CUAService");

export async function findScreenshotCoordinateSpace({ appName, referenceTime }) {
  const entries = await readdir(SCREENSHOT_DIRECTORY, { withFileTypes: true }).catch(() => []);
  const candidates = [];
  for (const entry of entries) {
    if (!entry.isFile() || !entry.name.startsWith(`${appName} Screenshot `)) continue;
    const file = path.join(SCREENSHOT_DIRECTORY, entry.name);
    const metadata = await stat(file).catch(() => undefined);
    if (metadata) candidates.push({ file, distance: Math.abs(metadata.mtimeMs - referenceTime) });
  }
  candidates.sort((left, right) => left.distance - right.distance);

  for (const candidate of candidates) {
    const dimensions = await readJpegDimensions(candidate.file).catch(() => undefined);
    if (!dimensions) continue;
    return {
      ...dimensions,
      evidence: candidate.file,
      confidence: candidate.distance <= 60_000 ? "near_capture" : "nearest_cached_screenshot",
      ageMs: Math.round(candidate.distance)
    };
  }
  return undefined;
}

async function readJpegDimensions(file) {
  const bytes = await readFile(file);
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
