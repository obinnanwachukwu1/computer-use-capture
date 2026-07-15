#!/usr/bin/env node
import { execFile } from "node:child_process";
import { access, mkdtemp, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { promisify } from "node:util";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

const run = promisify(execFile);
const tarball = path.resolve(process.argv[2] ?? "");
if (!tarball) throw new Error("usage: node scripts/smoke-package.mjs <package.tgz>");
await access(tarball);

const temporary = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-package-"));
try {
  await run("npm", ["install", "--ignore-scripts", "--prefix", temporary, tarball], {
    maxBuffer: 16 * 1024 * 1024,
  });
  const packageRoot = path.join(temporary, "node_modules", "computer-use-capture");
  for (const forbidden of ["Package.swift", "Sources", "Tests", "test", "demo", ".git"]) {
    await access(path.join(packageRoot, forbidden)).then(() => {
      throw new Error(`Development-only path leaked into npm package: ${forbidden}`);
    }).catch((error) => {
      if (error?.code !== "ENOENT") throw error;
    });
  }
  await access(path.join(temporary, "node_modules", ".bin", "computer-use-capture"));
  const store = path.join(temporary, "store");
  const transport = new StdioClientTransport({
    command: "npx",
    args: ["--yes", "--package", tarball, "computer-use-capture"],
    cwd: temporary,
    env: { ...process.env, AGENTRECORDER_STORE: store },
  });
  const client = new Client({ name: "computer-use-capture-package-smoke", version: "1.0.0" });
  await client.connect(transport);
  try {
    const listed = await client.listTools();
    if (listed.tools.length !== 7) throw new Error(`Expected 7 MCP tools, found ${listed.tools.length}`);
    const capabilities = await client.callTool({ name: "recorder_capabilities", arguments: {} });
    if (capabilities.isError || capabilities.structuredContent?.contractVersion !== "1.0.0") {
      throw new Error("Packaged MCP capabilities smoke failed");
    }
  } finally {
    await client.close();
  }
  process.stdout.write(`packaged MCP smoke passed: ${tarball}\n`);
} finally {
  await rm(temporary, { recursive: true, force: true });
}
