import { execFileSync, spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import readline from "node:readline";
import { parseAccessibilityElements } from "../lib/codex-events.mjs";

const root = path.resolve(process.argv[2] ?? path.join(process.env.HOME, ".codex", "sessions"));
const sdk = macOSSDKVocabulary();
const roleCounts = new Map();
const unknownPrefixes = new Map();
const matchedFiles = new Set();
let snapshots = 0;
let elements = 0;

const search = spawn("rg", [
  "-F", '"mcp_tool_call_end"', root, "-g", "*.jsonl", "--with-filename"
], { stdio: ["ignore", "pipe", "inherit"] });
const lines = readline.createInterface({ input: search.stdout, crlfDelay: Infinity });
for await (const matchedLine of lines) {
    const separator = matchedLine.indexOf(":{");
    if (separator < 0) continue;
    const file = matchedLine.slice(0, separator);
    const line = matchedLine.slice(separator + 1);
    if (!line.includes("get_app_state")) continue;
    matchedFiles.add(file);
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    if (record.type !== "event_msg" || record.payload?.type !== "mcp_tool_call_end") continue;
    const invocation = record.payload.invocation;
    const isComputerUse = invocation?.server === "computer-use"
      || (invocation?.server === "node_repl" && String(invocation?.arguments?.code ?? "").includes("get_app_state"));
    if (!isComputerUse) continue;
    const text = resultText(record.payload.result);
    if (!/^Window:/m.test(text) && !/accessibility tree.*diff/i.test(text)) continue;
    snapshots += 1;
    for (const parsed of parseAccessibilityElements(text).values()) {
      elements += 1;
      roleCounts.set(parsed.role, (roleCounts.get(parsed.role) ?? 0) + 1);
      if (!parsed.roleKnown) {
        const prefix = parsed.rawDescriptor.split(/\s+/).slice(0, 4).join(" ");
        unknownPrefixes.set(prefix, (unknownPrefixes.get(prefix) ?? 0) + 1);
      }
    }
}
const searchExit = await new Promise(resolve => search.once("exit", resolve));
if (searchExit !== 0 && searchExit !== 1) throw new Error(`rg exited with ${searchExit}`);

const sortCounts = map => [...map].sort((left, right) => right[1] - left[1]);
process.stdout.write(`${JSON.stringify({
  root,
  sdk,
  files: matchedFiles.size,
  snapshots,
  elements,
  roles: Object.fromEntries(sortCounts(roleCounts)),
  unknownPrefixes: Object.fromEntries(sortCounts(unknownPrefixes).slice(0, 100))
}, null, 2)}\n`);

function resultText(result) {
  const content = result?.Ok?.content ?? result?.content ?? [];
  return content.filter(item => item?.type === "text" && typeof item.text === "string")
    .map(item => item.text).join("\n");
}

function macOSSDKVocabulary() {
  try {
    const sdkRoot = execFileSync("xcrun", ["--show-sdk-path"], { encoding: "utf8" }).trim();
    const roleHeader = readFileSync(path.join(
      sdkRoot,
      "System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/Headers/AXRoleConstants.h"
    ), "utf8");
    const appKitHeader = readFileSync(path.join(
      sdkRoot, "System/Library/Frameworks/AppKit.framework/Headers/NSAccessibilityConstants.h"
    ), "utf8");
    const unique = values => [...new Set(values)].sort();
    const names = (source, expression) => unique([...source.matchAll(expression)].map(match => match[0]));
    const axRoles = names(roleHeader, /\bkAX[A-Za-z0-9]+Role\b/g);
    const axSubroles = names(roleHeader, /\bkAX[A-Za-z0-9]+Subrole\b/g);
    const appKitRoles = names(appKitHeader, /\bNSAccessibility[A-Za-z0-9]+Role\b/g);
    const appKitSubroles = names(appKitHeader, /\bNSAccessibility[A-Za-z0-9]+Subrole\b/g);
    return {
      path: sdkRoot,
      counts: {
        axRoles: axRoles.length, axSubroles: axSubroles.length,
        appKitRoles: appKitRoles.length, appKitSubroles: appKitSubroles.length
      },
      axRoles, axSubroles, appKitRoles, appKitSubroles
    };
  } catch (error) {
    return { unavailable: true, reason: error instanceof Error ? error.message : String(error) };
  }
}
