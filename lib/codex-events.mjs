import { createReadStream } from "node:fs";
import { open, readdir, stat } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { parse } from "acorn";

const CONTEXT_METHODS = new Set(["get_app_state", "list_apps"]);
const KNOWN_ACTIONS = new Set([
  "click",
  "drag",
  "perform_secondary_action",
  "press_key",
  "scroll",
  "select_text",
  "set_value",
  "type_text"
]);
const METHOD_ALIASES = new Map([
  ["getAppState", "get_app_state"],
  ["listApps", "list_apps"],
  ["pressKey", "press_key"],
  ["typeText", "type_text"],
  ["setValue", "set_value"],
  ["selectText", "select_text"],
  ["performSecondaryAction", "perform_secondary_action"]
]);

// Computer Use renders native AX roles as lower-case human phrases. This is
// the role vocabulary from AXRoleConstants.h and NSAccessibilityConstants.h,
// plus the web roles emitted by the Computer Use serializer. Labels remain
// app-defined and are deliberately not enumerated here.
export const COMPUTER_USE_ROLE_PHRASES = [
  "application dock item", "busy indicator", "check box", "close button",
  "color well", "combo box", "content list", "date field", "date time area",
  "decorative", "decrement arrow", "decrement page", "definition list",
  "description list", "disclosure triangle", "dock extra dock item", "dock item",
  "document dock item", "floating window", "folder dock item", "full screen button",
  "grow area", "html content", "increment arrow", "increment page", "layout area",
  "layout item", "level indicator", "list marker", "menu bar item", "menu bar",
  "menu button", "menu item", "minimize button", "minimized window dock item",
  "outline row", "pop up button", "process switcher list", "progress indicator",
  "radio button", "radio group", "rating indicator", "relevance indicator",
  "ruler marker", "scroll area", "scroll bar", "search field", "secure text field",
  "separator dock item", "sort button", "split group", "standard window",
  "static text", "system dialog", "system floating window", "system wide",
  "tab group", "table row", "text area", "text field", "time field",
  "toggle button", "toolbar button", "trash dock item", "url dock item",
  "value indicator", "web area", "zoom button",
  "application", "browser", "button", "cell", "column", "container", "dialog",
  "checkbox", "collection", "drawer", "editor", "element", "graphics symbol", "grid",
  "group", "handle", "heading", "help tag", "image",
  "incrementor", "link", "list", "matte", "menu", "outline", "page", "popover",
  "row", "ruler", "scrollbar", "search text field", "section", "sheet", "slider",
  "sortable", "splitter", "stepper", "switch", "tab", "table", "text", "timeline",
  "toggle", "toolbar", "unknown", "window"
].sort((left, right) => right.length - left.length);

export async function findActiveCodexSession({
  cwd,
  sessionsRoot = path.join(process.env.HOME, ".codex", "sessions")
}) {
  const files = await collectJsonlFiles(sessionsRoot);
  const candidates = [];

  for (const file of files) {
    const metadata = await stat(file).catch(() => undefined);
    if (!metadata) continue;
    candidates.push({ file, mtimeMs: metadata.mtimeMs });
  }
  candidates.sort((left, right) => right.mtimeMs - left.mtimeMs);

  for (const candidate of candidates.slice(0, 80)) {
    const firstLine = await readFirstLine(candidate.file);
    if (!firstLine) continue;
    try {
      const record = JSON.parse(firstLine);
      if (record.type !== "session_meta") continue;
      if (path.resolve(record.payload?.cwd ?? "") !== path.resolve(cwd)) continue;
      return {
        file: candidate.file,
        threadId: record.payload?.id ?? record.payload?.session_id ?? null,
        cwd: record.payload?.cwd,
        mtimeMs: candidate.mtimeMs
      };
    } catch {
      // Ignore incomplete or unrelated session files.
    }
  }

  throw new Error(`Could not find an active Codex session for ${cwd}`);
}

export async function extractComputerUseEvents({ sessionFile, captureStartedAt, captureEndedAt }) {
  const captureStartMs = new Date(captureStartedAt).getTime();
  const captureEndMs = new Date(captureEndedAt).getTime();
  const events = [];
  const warnings = [];
  const accessibilityByApp = new Map();
  const input = createReadStream(sessionFile, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });

  for await (const line of lines) {
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    if (record.type !== "event_msg" || record.payload?.type !== "mcp_tool_call_end") continue;
    const invocation = record.payload.invocation;
    const endMs = new Date(record.timestamp).getTime();
    const durationMs = durationToMilliseconds(record.payload.duration);
    const startMs = endMs - durationMs;
    let calls;
    let transport;
    if (invocation?.server === "computer-use" && typeof invocation.tool === "string") {
      calls = [{ method: invocation.tool, args: invocation.arguments ?? {} }];
      transport = "direct-mcp";
    } else if (invocation?.server === "node_repl" && invocation?.tool === "js") {
      const code = invocation.arguments?.code;
      if (typeof code !== "string" || !code.includes("sky.")) continue;
      try {
        calls = extractSkyCalls(code);
        transport = "node-repl-sky";
      } catch (error) {
        if (endMs >= captureStartMs && startMs <= captureEndMs) {
          warnings.push({
            type: "parse_failed",
            timestamp: record.timestamp,
            message: error instanceof Error ? error.message : String(error)
          });
        }
        continue;
      }
    } else {
      continue;
    }

    if (computerUseResultFailed(record.payload?.result)) {
      if (endMs >= captureStartMs && startMs <= captureEndMs) {
        warnings.push({
          type: "tool_call_failed",
          timestamp: record.timestamp,
          message: computerUseResultText(record.payload?.result) || "Computer Use call failed"
        });
      }
      continue;
    }

    calls.forEach((call, index) => {
      const normalizedMethod = METHOD_ALIASES.get(call.method) ?? call.method;
      if (CONTEXT_METHODS.has(normalizedMethod)) return;
      const progress = calls.length === 1 ? 0.5 : (index + 0.5) / calls.length;
      const estimatedMs = startMs + durationMs * progress;
      if (estimatedMs < captureStartMs || estimatedMs > captureEndMs) return;
      const elementIndex = Number(call.args?.element_index);
      const accessibilityState = accessibilityByApp.get(call.args?.app);
      const accessibilityTarget = Number.isInteger(elementIndex)
        ? accessibilityState?.elements.get(elementIndex)
        : undefined;
      const accessibilityContext = Number.isInteger(elementIndex) && accessibilityState
        ? accessibilityContextFor(accessibilityState.elements, elementIndex)
        : undefined;
      events.push({
        time: Number(((estimatedMs - captureStartMs) / 1000).toFixed(6)),
        timestamp: new Date(estimatedMs).toISOString(),
        action: KNOWN_ACTIONS.has(normalizedMethod) ? normalizedMethod : "unknown",
        method: call.method,
        args: sanitizeArguments(normalizedMethod, call.args),
        ...(accessibilityTarget ? { accessibilityTarget } : {}),
        ...(accessibilityContext ? { accessibilityContext } : {}),
        timing: {
          confidence: "estimated_within_tool_call",
          transport,
          actionIsFinalSkyCall: index === calls.length - 1,
          toolCallStartedAt: new Date(startMs).toISOString(),
          toolCallEndedAt: new Date(endMs).toISOString(),
          toolCallDurationMs: durationMs
        }
      });
    });

    // Tool output reflects the state after every action in this invocation.
    // Update only after extracting actions so an element index resolves
    // against the state from which the agent selected it.
    const stateText = computerUseResultText(record.payload?.result);
    if (calls.some(call => (METHOD_ALIASES.get(call.method) ?? call.method) === "get_app_state") && stateText) {
      const app = [...calls].reverse().find(call =>
        (METHOD_ALIASES.get(call.method) ?? call.method) === "get_app_state"
      )?.args?.app;
      if (app) {
        const previous = accessibilityByApp.get(app);
        const updated = mergeAccessibilityState(previous, stateText);
        if (updated.elements.size) accessibilityByApp.set(app, updated);
      }
    }
  }

  events.sort((left, right) => left.time - right.time);
  return { events, warnings };
}

export function parseAccessibilityElements(text) {
  const elements = new Map();
  for (const line of String(text).split("\n")) {
    // Diff snapshots prefix changed/added tree rows with `~`/`+` before the
    // indentation. The marker is transport syntax, not part of the element.
    const match = line.match(/^\s*[+~-]?\s*(\d+)\s+(.+?)\s*$/);
    if (!match) continue;
    const index = Number(match[1]);
    const description = match[2];
    const metadata = parseDescriptorMetadata(description);
    let roleAndLabel = metadata.primary;
    const canonicalRole = roleAndLabel.match(/^(AX[A-Za-z0-9]+)(?:\s|$)/)?.[1];
    if (canonicalRole) {
      roleAndLabel = `${humanizeAXRole(canonicalRole)}${roleAndLabel.slice(canonicalRole.length)}`;
    }
    // Longest-first: compound roles must be consumed before their first word.
    const normalizedRoleAndLabel = roleAndLabel.toLowerCase();
    const role = COMPUTER_USE_ROLE_PHRASES.find(candidate =>
      normalizedRoleAndLabel === candidate || normalizedRoleAndLabel.startsWith(`${candidate} `)
    );
    const rawLabel = roleAndLabel.slice(role?.length ?? 0).trim();
    // Computer Use emits control state/type qualifiers as a leading group,
    // e.g. `(settable, string)`. Parentheses later in a label are content
    // (function signatures are common in code editors) and must be preserved.
    const qualifierPrefix = rawLabel.match(/^(?:\([^)]+\)\s*)+/)?.[0] ?? "";
    const qualifiers = [...qualifierPrefix.matchAll(/\(([^)]+)\)/g)]
      .flatMap(match => match[1].split(",").map(value => value.trim()).filter(Boolean));
    const label = rawLabel.slice(qualifierPrefix.length).trim()
      .replace(/,$/, "");
    elements.set(index, {
      elementIndex: index,
      role: role ?? "unknown",
      roleKnown: role != null,
      rawDescriptor: description,
      ...(label ? { label } : {}),
      ...(qualifiers.length ? { qualifiers } : {}),
      ...metadata.fields
    });
  }
  return elements;
}

function parseDescriptorMetadata(description) {
  const marker = /(?:^|,\s*|\s+)(Description|Value|Help|ID|URL|Secondary Actions):\s*/g;
  const matches = [...description.matchAll(marker)];
  const primary = description.slice(0, matches[0]?.index ?? description.length).replace(/,\s*$/, "").trim();
  const fields = {};
  const fieldNames = {
    Description: "description", Value: "value", Help: "help", ID: "identifier",
    URL: "url", "Secondary Actions": "secondaryActions"
  };
  for (let index = 0; index < matches.length; index += 1) {
    const match = matches[index];
    const start = match.index + match[0].length;
    const end = matches[index + 1]?.index ?? description.length;
    const value = description.slice(start, end).replace(/,\s*$/, "").trim();
    if (!value) continue;
    const name = fieldNames[match[1]];
    fields[name] = name === "secondaryActions"
      ? value.split(",").map(item => item.trim()).filter(Boolean)
      : value;
  }
  return { primary, fields };
}

function humanizeAXRole(value) {
  return value.replace(/^AX/, "")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/([A-Z])([A-Z][a-z])/g, "$1 $2")
    .toLowerCase();
}

export function mergeAccessibilityState(previous, text) {
  const source = String(text);
  const parsed = parseAccessibilityElements(source);
  const isDiff = /(?:diff[\s\S]{0,80}accessibility tree|accessibility tree[\s\S]{0,80}diff)/i.test(source)
    || /Removed element IDs:/i.test(source);
  const isFull = /^Window:/m.test(source) && !isDiff;
  const elements = isFull || !previous
    ? new Map(parsed)
    : new Map(previous.elements);

  if (!isFull && previous) {
    for (const range of parseRemovedElementRanges(source)) {
      for (let index = range.start; index <= range.end; index += 1) elements.delete(index);
    }
    for (const [index, element] of parsed) elements.set(index, element);
  }
  return { elements, complete: isFull || previous?.complete === true };
}

function parseRemovedElementRanges(text) {
  const summary = String(text).match(/Removed element IDs:\s*([^\n]+)/i)?.[1];
  if (!summary) return [];
  return summary.split(",").flatMap(part => {
    const match = part.trim().match(/^(\d+)(?:-(\d+))?$/);
    if (!match) return [];
    return [{ start: Number(match[1]), end: Number(match[2] ?? match[1]) }];
  });
}

function accessibilityContextFor(elements, targetIndex) {
  const target = elements.get(targetIndex);
  const ordered = [...elements.values()].sort((left, right) => left.elementIndex - right.elementIndex);
  const position = ordered.findIndex(element => element.elementIndex === targetIndex);
  if (position < 0) return undefined;
  const hasIdentity = element => [element?.label, element?.description, element?.value]
    .some(value => typeof value === "string" && value.trim());
  const before = ordered.slice(0, position).toReversed().find(hasIdentity);
  const after = ordered.slice(position + 1).find(hasIdentity);
  return {
    targetIndex,
    ...(target ? { target } : {}),
    ...(before ? { before } : {}),
    ...(after ? { after } : {})
  };
}

function computerUseResultText(result) {
  const content = result?.Ok?.content ?? result?.content ?? [];
  return content.filter(item => item?.type === "text" && typeof item.text === "string")
    .map(item => item.text).join("\n");
}

function computerUseResultFailed(result) {
  return result?.Ok?.isError === true || result?.isError === true || result?.Err != null;
}

export function extractSkyCalls(code) {
  const ast = parse(code, {
    ecmaVersion: "latest",
    sourceType: "module",
    allowAwaitOutsideFunction: true
  });
  const nodes = [];
  walk(ast, node => {
    if (node.type === "VariableDeclarator" || node.type === "AssignmentExpression") {
      nodes.push(node);
    }
    if (node.type === "CallExpression" && getSkyMethod(node.callee)) {
      nodes.push(node);
    }
  });
  nodes.sort((left, right) => left.start - right.start);

  const environment = new Map();
  const calls = [];
  for (const node of nodes) {
    if (node.type === "VariableDeclarator" && node.id.type === "Identifier") {
      const value = evaluateStatic(node.init, environment);
      if (value !== undefined) environment.set(node.id.name, value);
      continue;
    }
    if (
      node.type === "AssignmentExpression" &&
      node.operator === "=" &&
      node.left.type === "Identifier"
    ) {
      const value = evaluateStatic(node.right, environment);
      if (value !== undefined) environment.set(node.left.name, value);
      continue;
    }
    if (node.type === "CallExpression") {
      const method = getSkyMethod(node.callee);
      if (!method) continue;
      calls.push({
        method,
        args: evaluateStatic(node.arguments[0], environment) ?? {},
        sourceStart: node.start,
        sourceEnd: node.end
      });
    }
  }
  return calls;
}

function getSkyMethod(callee) {
  if (callee?.type !== "MemberExpression" || callee.computed) return null;
  if (callee.object?.type !== "Identifier" || callee.object.name !== "sky") return null;
  return callee.property?.type === "Identifier" ? callee.property.name : null;
}

function evaluateStatic(node, environment) {
  if (!node) return undefined;
  if (node.type === "Literal") return node.value;
  if (node.type === "Identifier") return environment.get(node.name);
  if (node.type === "MemberExpression") {
    const object = evaluateStatic(node.object, environment);
    const key = node.computed
      ? evaluateStatic(node.property, environment)
      : node.property.type === "Identifier" ? node.property.name : undefined;
    if (object && (typeof key === "string" || typeof key === "number")) return object[key];
    return undefined;
  }
  if (node.type === "UnaryExpression" && ["+", "-"].includes(node.operator)) {
    const value = evaluateStatic(node.argument, environment);
    return typeof value === "number" ? (node.operator === "-" ? -value : value) : undefined;
  }
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    return node.quasis[0]?.value?.cooked ?? "";
  }
  if (node.type === "ArrayExpression") {
    return node.elements.map(element => evaluateStatic(element, environment));
  }
  if (node.type === "ObjectExpression") {
    const value = {};
    for (const property of node.properties) {
      if (property.type !== "Property" || property.computed || property.kind !== "init") continue;
      const key = property.key.type === "Identifier" ? property.key.name : property.key.value;
      if (typeof key !== "string" && typeof key !== "number") continue;
      const propertyValue = evaluateStatic(property.value, environment);
      if (propertyValue !== undefined) value[key] = propertyValue;
    }
    return value;
  }
  return undefined;
}

function sanitizeArguments(method, args) {
  const sanitized = { ...args };
  const sensitiveFields = method === "set_value"
    ? ["value"]
    : method === "type_text"
      ? ["text"]
      : method === "select_text"
        ? ["text", "prefix", "suffix"]
        : [];
  for (const field of sensitiveFields) {
    if (typeof sanitized[field] !== "string") continue;
    sanitized[`${field}_length`] = sanitized[field].length;
    delete sanitized[field];
  }
  return sanitized;
}

function durationToMilliseconds(duration) {
  return (Number(duration?.secs ?? 0) * 1000) + (Number(duration?.nanos ?? 0) / 1_000_000);
}

function walk(node, visit) {
  if (!node || typeof node !== "object") return;
  visit(node);
  for (const [key, value] of Object.entries(node)) {
    if (["start", "end", "loc"].includes(key)) continue;
    if (Array.isArray(value)) {
      for (const child of value) walk(child, visit);
    } else if (value && typeof value === "object" && typeof value.type === "string") {
      walk(value, visit);
    }
  }
}

async function collectJsonlFiles(root) {
  const results = [];
  const stack = [root];
  while (stack.length) {
    const directory = stack.pop();
    const entries = await readdir(directory, { withFileTypes: true }).catch(() => []);
    for (const entry of entries) {
      const fullPath = path.join(directory, entry.name);
      if (entry.isDirectory()) stack.push(fullPath);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) results.push(fullPath);
    }
  }
  return results;
}

async function readFirstLine(file) {
  const handle = await open(file, "r").catch(() => undefined);
  if (!handle) return "";
  try {
    const chunk = Buffer.allocUnsafe(64 * 1024);
    const { bytesRead } = await handle.read(chunk, 0, chunk.length, 0);
    const contents = chunk.subarray(0, bytesRead).toString("utf8");
    const newline = contents.indexOf("\n");
    return newline === -1 ? contents : contents.slice(0, newline);
  } finally {
    await handle.close();
  }
}
