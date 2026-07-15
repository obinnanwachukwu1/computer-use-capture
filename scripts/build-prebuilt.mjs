#!/usr/bin/env node
import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import { chmod, copyFile, mkdir, readFile, rm, stat, writeFile } from "node:fs/promises";
import path from "node:path";
import { promisify } from "node:util";
import { runtimeProducts } from "../lib/runtime-binaries.mjs";

const run = promisify(execFile);
const repoRoot = path.resolve(import.meta.dirname, "..");
const output = path.join(repoRoot, "vendor", "darwin-arm64");

if (process.platform !== "darwin" || process.arch !== "arm64") {
  throw new Error(`Prebuilt releases must be created on Apple Silicon macOS; found ${process.platform}/${process.arch}`);
}

await run("swift", ["build", "-c", "release"], { cwd: repoRoot, maxBuffer: 16 * 1024 * 1024 });
await rm(output, { recursive: true, force: true });
await mkdir(output, { recursive: true });

const products = {};
for (const product of runtimeProducts) {
  const source = path.join(repoRoot, ".build", "release", product);
  const destination = path.join(output, product);
  await copyFile(source, destination);
  await chmod(destination, 0o755);
  await run("strip", ["-x", destination]);
  await run("codesign", [
    "--force", "--sign", "-",
    "--identifier", `app.computerusecapture.${product}`,
    destination,
  ]);
  await run("codesign", ["--verify", "--strict", destination]);
  const { stdout: architectures } = await run("lipo", ["-archs", destination]);
  if (architectures.trim() !== "arm64") throw new Error(`${product} is not an arm64-only binary: ${architectures.trim()}`);
  const { stdout: embeddedStrings } = await run("strings", [destination], { maxBuffer: 64 * 1024 * 1024 });
  if (/\/Users\/|\/var\/folders\//.test(embeddedStrings)) {
    throw new Error(`${product} embeds a machine-local build path`);
  }
  const bytes = (await stat(destination)).size;
  const sha256 = createHash("sha256").update(await readFile(destination)).digest("hex");
  products[product] = { bytes, sha256 };
}

await writeFile(path.join(output, "manifest.json"), `${JSON.stringify({
  version: 1,
  platform: "darwin",
  arch: "arm64",
  products,
}, null, 2)}\n`);
process.stdout.write(`built ${runtimeProducts.length} ad-hoc-signed arm64 binaries in ${output}\n`);
