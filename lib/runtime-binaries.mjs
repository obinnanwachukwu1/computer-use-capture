import { createHash } from "node:crypto";
import { constants, existsSync } from "node:fs";
import { access, readFile, stat } from "node:fs/promises";
import path from "node:path";

export const runtimeProducts = Object.freeze([
  "capture-app",
  "inspect-focused-element",
  "native-compose",
  "recorder-preflight",
  "export-macos-cursor",
]);

export function runtimeMode(repoRoot) {
  const explicit = process.env.COMPUTER_USE_CAPTURE_BINARY_MODE;
  if (explicit && !["source", "prebuilt"].includes(explicit)) {
    throw new Error("COMPUTER_USE_CAPTURE_BINARY_MODE must be source or prebuilt");
  }
  if (process.env.COMPUTER_USE_CAPTURE_BINARY_DIR) return "prebuilt";
  if (explicit) return explicit;
  return existsSync(path.join(repoRoot, ".git")) ? "source" : "prebuilt";
}

export function runtimeBinaryDirectory(repoRoot) {
  if (process.env.COMPUTER_USE_CAPTURE_BINARY_DIR) {
    return path.resolve(process.env.COMPUTER_USE_CAPTURE_BINARY_DIR);
  }
  return runtimeMode(repoRoot) === "prebuilt"
    ? path.join(repoRoot, "vendor", "darwin-arm64")
    : path.join(repoRoot, ".build", "release");
}

export function runtimeBinaryPath(repoRoot, product) {
  if (!runtimeProducts.includes(product)) throw new Error(`Unknown runtime product: ${product}`);
  return path.join(runtimeBinaryDirectory(repoRoot), product);
}

export async function verifyPrebuiltRuntime(repoRoot) {
  if (process.platform !== "darwin" || process.arch !== "arm64") {
    throw new Error(`Computer Use Capture requires Apple Silicon macOS; found ${process.platform}/${process.arch}`);
  }
  const directory = runtimeBinaryDirectory(repoRoot);
  const manifestPath = path.join(directory, "manifest.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8").catch(() => {
    throw new Error(`Prebuilt runtime manifest is missing: ${manifestPath}`);
  }));
  if (manifest.version !== 1 || manifest.platform !== "darwin" || manifest.arch !== "arm64") {
    throw new Error("Prebuilt runtime manifest is incompatible with Apple Silicon macOS");
  }
  for (const product of runtimeProducts) {
    const binary = path.join(directory, product);
    await access(binary, constants.X_OK).catch(() => {
      throw new Error(`Prebuilt runtime binary is missing or not executable: ${product}`);
    });
    const metadata = await stat(binary);
    const expected = manifest.products?.[product];
    if (!expected || expected.bytes !== metadata.size) {
      throw new Error(`Prebuilt runtime size check failed: ${product}`);
    }
    const digest = createHash("sha256").update(await readFile(binary)).digest("hex");
    if (digest !== expected.sha256) throw new Error(`Prebuilt runtime integrity check failed: ${product}`);
  }
  return directory;
}
