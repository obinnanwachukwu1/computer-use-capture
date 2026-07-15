import { execFileSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";

const forbiddenPaths = [
  /(^|\/)artifacts\//,
  /\.(?:mov|mp4|m4v|jsonl)$/i,
  new RegExp(`(^|/)(?:${["fa", "ble"].join("")}|${["clau", "de"].join("")})(?:[-_.]|$)`, "i"),
  /(^|\/)(?:release-and-rename-plan|launch-announcement|architecture-review)(?:[-_.]|$)/i,
  /(^|\/)(?:\.env(?:\.|$)|id_rsa$|id_ed25519$|credentials?\b|secrets?\b)/i,
];

const forbiddenContent = [
  { label: "macOS user home path", pattern: /\/Users\/[^/\s"']+/ },
  { label: "macOS private temporary path", pattern: /\/var\/folders\// },
  { label: "Codex task identifier", pattern: /\b019[a-f0-9]{5,}-[a-f0-9-]{12,}\b/i },
  {
    label: "personal email address",
    pattern: /\b[A-Z0-9._%+-]+@(?!users\.noreply\.github\.com\b)[A-Z0-9.-]+\.[A-Z]{2,}\b/i,
  },
];

const tracked = execFileSync(
  "git", ["ls-files", "--cached", "--others", "--exclude-standard", "-z"],
  { encoding: "utf8" },
)
  .split("\0")
  .filter(Boolean);
const failures = [];

for (const file of tracked) {
  if (!existsSync(file)) continue;
  if (forbiddenPaths.some((pattern) => pattern.test(file))) {
    failures.push(`${file}: forbidden private or generated path`);
    continue;
  }
  let content;
  try {
    content = readFileSync(file, "utf8");
  } catch {
    continue;
  }
  for (const { label, pattern } of forbiddenContent) {
    const match = content.match(pattern);
    if (match) failures.push(`${file}: ${label} (${match[0]})`);
  }
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exit(1);
}

try {
  execFileSync("gitleaks", [
    "dir", ".", "--config", ".gitleaks.toml", "--redact", "--no-banner"
  ], { stdio: "inherit" });
} catch (error) {
  if (error?.code === "ENOENT") {
    process.stderr.write("gitleaks is required; install it with `brew install gitleaks`.\n");
  }
  process.exit(1);
}

process.stdout.write(`repository hygiene passed for ${tracked.length} tracked files\n`);
