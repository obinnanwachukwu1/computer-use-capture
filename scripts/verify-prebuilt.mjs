#!/usr/bin/env node
import path from "node:path";
import { verifyPrebuiltRuntime } from "../lib/runtime-binaries.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
process.env.AGENTRECORDER_BINARY_MODE = "prebuilt";
const directory = await verifyPrebuiltRuntime(repoRoot);
process.stdout.write(`verified prebuilt runtime: ${directory}\n`);
