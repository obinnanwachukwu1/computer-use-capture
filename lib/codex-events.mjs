import { createReadStream } from "node:fs";
import { createHash } from "node:crypto";
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
  "text entry area",
  "toggle button", "toolbar button", "trash dock item", "url dock item",
  "value indicator", "web area", "zoom button",
  "application", "browser", "button", "cell", "column", "container", "dialog",
  "checkbox", "collection", "drawer", "editor", "element", "graphics symbol", "grid",
  "group", "handle", "heading", "help tag", "image", "list box",
  "incrementor", "link", "list", "matte", "menu", "outline", "page", "popover",
  "row", "ruler", "scrollbar", "search text field", "section", "sheet", "slider",
  "sortable", "splitter", "stepper", "switch", "tab", "table", "text", "timeline",
  "toggle", "toolbar", "unknown", "window"
].sort((left, right) => right.length - left.length);

export async function findActiveCodexSession({
  cwd,
  threadId,
  sessionsRoot = path.join(process.env.HOME, ".codex", "sessions")
}) {
  const matches = await findCodexSessions({ cwd, threadId, sessionsRoot });
  if (matches.length) return matches[0];
  throw new Error(`Could not find an active Codex session for ${cwd}`);
}

export async function findCodexSessions({
  cwd,
  threadId,
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

  const matches = [];
  for (const candidate of candidates.slice(0, 160)) {
    const firstLine = await readFirstLine(candidate.file);
    if (!firstLine) continue;
    try {
      const record = JSON.parse(firstLine);
      if (record.type !== "session_meta") continue;
      if (path.resolve(record.payload?.cwd ?? "") !== path.resolve(cwd)) continue;
      const candidateThreadId = record.payload?.id ?? record.payload?.session_id ?? null;
      if (threadId && candidateThreadId !== threadId) continue;
      matches.push({
        file: candidate.file,
        threadId: candidateThreadId,
        cwd: record.payload?.cwd,
        mtimeMs: candidate.mtimeMs
      });
    } catch {
      // Ignore incomplete or unrelated session files.
    }
  }

  return matches;
}

export async function extractComputerUseEvents({ sessionFile, captureStartedAt, captureEndedAt }) {
  const accumulator = createComputerUseEventAccumulator({ captureStartedAt });
  const input = createReadStream(sessionFile, { encoding: "utf8" });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });

  for await (const line of lines) {
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      continue;
    }
    accumulator.ingest(record);
  }
  return accumulator.snapshot({ captureEndedAt });
}

/**
 * Stateful rollout adapter used by both one-shot reconstruction and the live
 * file tailer. It intentionally consumes every earlier record so JavaScript
 * variables and incremental Accessibility snapshots remain available when a
 * later action refers to them.
 */
export function createComputerUseEventAccumulator({ captureStartedAt }) {
  const captureStartMs = new Date(captureStartedAt).getTime();
  const events = [];
  const warnings = [];
  const adapterShape = new Set();
  const accessibilityByApp = new Map();
  let replEnvironment = new Map();

  function ingest(record) {
    if (record.type !== "event_msg" || record.payload?.type !== "mcp_tool_call_end") return;
    const invocation = record.payload.invocation;
    const endMs = new Date(record.timestamp).getTime();
    const durationMs = durationToMilliseconds(record.payload.duration);
    const startMs = endMs - durationMs;
    let calls;
    let transport;
    let nextReplEnvironment;
    if (invocation?.server === "computer-use" && typeof invocation.tool === "string") {
      calls = [{ method: invocation.tool, args: invocation.arguments ?? {} }];
      transport = "direct-mcp";
    } else if (invocation?.server === "node_repl" && invocation?.tool === "js") {
      const code = invocation.arguments?.code;
      if (typeof code !== "string") return;
      try {
        nextReplEnvironment = new Map(replEnvironment);
        calls = extractSkyCalls(code, { environment: nextReplEnvironment });
        transport = "node-repl-sky";
      } catch (error) {
        if (endMs >= captureStartMs) {
          warnings.push({
            type: "parse_failed",
            timestamp: record.timestamp,
            message: error instanceof Error ? error.message : String(error)
          });
        }
        return;
      }
    } else {
      return;
    }
    if (!isCompatibleComputerUseRecord(record)) {
      if (calls?.length) {
        warnings.push({
          type: "adapter_incompatible",
          timestamp: typeof record.timestamp === "string" ? record.timestamp : undefined,
          message: "Computer Use rollout record is missing required timestamp, duration, or result fields"
        });
      }
      return;
    }
    if (computerUseResultFailed(record.payload?.result)) {
      if (calls.length && endMs >= captureStartMs) {
        warnings.push({
          type: "tool_call_failed",
          timestamp: record.timestamp,
          message: computerUseResultText(record.payload?.result) || "Computer Use call failed"
        });
      }
      return;
    }
    if (nextReplEnvironment) replEnvironment = nextReplEnvironment;
    if (!calls.length) return;
    adapterShape.add(recordShapeFingerprint(record));
    calls.forEach((call, index) => {
      const normalizedMethod = METHOD_ALIASES.get(call.method) ?? call.method;
      if (CONTEXT_METHODS.has(normalizedMethod)) return;
      const progress = calls.length === 1 ? 0.5 : (index + 0.5) / calls.length;
      const estimatedMs = startMs + durationMs * progress;
      if (estimatedMs < captureStartMs) return;
      if (call.executionUncertain || call.argumentsComplete === false) {
        warnings.push({
          type: "action_unverifiable",
          timestamp: record.timestamp,
          method: call.method,
          reason: call.executionUncertain ? "control-flow-not-observable" : "arguments-not-statically-resolved"
        });
        return;
      }
      const elementIndex = Number(call.args?.element_index);
      const accessibilityState = accessibilityByApp.get(normalizeAppIdentifier(call.args?.app));
      const accessibilityTarget = Number.isInteger(elementIndex)
        ? accessibilityState?.elements.get(elementIndex)
        : undefined;
      const accessibilityContext = Number.isInteger(elementIndex) && accessibilityState
        ? accessibilityContextFor(accessibilityState.elements, elementIndex)
        : undefined;
      events.push({
        actionId: stableActionId(record, index, call),
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
        const appKey = normalizeAppIdentifier(app);
        const previous = accessibilityByApp.get(appKey);
        const updated = mergeAccessibilityState(previous, stateText);
        if (updated.elements.size) accessibilityByApp.set(appKey, updated);
      }
    }
  }

  function snapshot({ captureEndedAt } = {}) {
    const captureEndMs = captureEndedAt == null ? Infinity : new Date(captureEndedAt).getTime();
    const boundedEvents = events.filter(event => Date.parse(event.timestamp) <= captureEndMs)
      .toSorted((left, right) => left.time - right.time);
    const boundedWarnings = warnings.filter(warning => {
      const timestamp = Date.parse(warning.timestamp);
      return !Number.isFinite(timestamp) || timestamp <= captureEndMs;
    });
    return {
      events: boundedEvents,
      warnings: boundedWarnings,
      adapter: {
        status: adapterShape.size ? "ok" : "unavailable",
        formatFingerprint: createHash("sha256").update([...adapterShape].sort().join("\n")).digest("hex").slice(0, 16),
        observedShapes: [...adapterShape].sort()
      }
    };
  }

  return { ingest, snapshot };
}

export function parseAccessibilityElements(text) {
  const elements = new Map();
  for (const line of String(text).split("\n")) {
    // Diff snapshots prefix changed/added tree rows with `~`/`+` before the
    // indentation. The marker is transport syntax, not part of the element.
    const match = line.match(/^\s*[+~]?\s*(\d+)\s+(.+?)\s*$/);
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
  const isFull = !isDiff && /^\s*(?:Accessibility Tree|Application|Browser|Focused Application|Window):/mi.test(source);
  const elements = isFull || !previous
    ? new Map(parsed)
    : new Map(previous.elements);

  if (!isFull && previous) {
    for (const range of parseRemovedElementRanges(source)) {
      for (let index = range.start; index <= range.end; index += 1) elements.delete(index);
    }
    for (const index of parseInlineRemovedElements(source)) elements.delete(index);
    for (const [index, element] of parsed) elements.set(index, element);
  }
  return { elements, complete: isFull || previous?.complete === true };
}

export async function probeCodexSessionFormat(sessionFile, { tailBytes = 2 * 1024 * 1024 } = {}) {
  const metadata = await stat(sessionFile);
  const start = Math.max(0, metadata.size - tailBytes);
  const input = createReadStream(sessionFile, { encoding: "utf8", start });
  const lines = readline.createInterface({ input, crlfDelay: Infinity });
  const shapes = new Set();
  let incompatible = 0;
  let first = true;
  for await (const line of lines) {
    if (first && start > 0) { first = false; continue; }
    first = false;
    let record;
    try { record = JSON.parse(line); } catch { continue; }
    if (record.type !== "event_msg" || record.payload?.type !== "mcp_tool_call_end") continue;
    const invocation = record.payload?.invocation;
    const direct = invocation?.server === "computer-use" && typeof invocation.tool === "string";
    const repl = invocation?.server === "node_repl" && invocation?.tool === "js"
      && typeof invocation.arguments?.code === "string" && invocation.arguments.code.includes("sky.");
    if (!direct && !repl) continue;
    if (!isCompatibleComputerUseRecord(record)) {
      incompatible += 1;
      continue;
    }
    shapes.add(recordShapeFingerprint(record));
  }
  if (!shapes.size) {
    return { status: "degraded", detail: "No recent Computer Use transport record was available for a shape probe" };
  }
  return {
    status: incompatible ? "degraded" : "ok",
    formatFingerprint: createHash("sha256").update([...shapes].sort().join("\n")).digest("hex").slice(0, 16),
    detail: `Observed ${shapes.size} compatible Computer Use record shape${shapes.size === 1 ? "" : "s"}`
      + (incompatible ? `; ${incompatible} recent record${incompatible === 1 ? " was" : "s were"} missing required timing or result fields` : "")
  };
}

function isCompatibleComputerUseRecord(record) {
  return Number.isFinite(Date.parse(record.timestamp))
    && Number.isFinite(Number(record.payload?.duration?.secs))
    && Number.isFinite(Number(record.payload?.duration?.nanos))
    && Object.hasOwn(record.payload ?? {}, "result")
    && record.payload.result != null
    && typeof record.payload.result === "object";
}

function recordShapeFingerprint(record) {
  const leaves = [];
  const visit = (value, prefix, depth) => {
    if (depth > 5 || value == null || typeof value !== "object") {
      leaves.push(`${prefix}:${value === null ? "null" : Array.isArray(value) ? "array" : typeof value}`);
      return;
    }
    if (Array.isArray(value)) {
      leaves.push(`${prefix}:array`);
      if (value[0] != null) visit(value[0], `${prefix}[]`, depth + 1);
      return;
    }
    for (const key of Object.keys(value).sort()) visit(value[key], prefix ? `${prefix}.${key}` : key, depth + 1);
  };
  visit(record, "", 0);
  return leaves.sort().join("|");
}

function parseInlineRemovedElements(text) {
  return String(text).split("\n").flatMap(line => {
    const match = line.match(/^\s*-\s*(\d+)(?:\s|$)/);
    return match ? [Number(match[1])] : [];
  });
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

export function extractSkyCalls(code, { environment = new Map() } = {}) {
  const ast = parse(code, {
    ecmaVersion: "latest",
    sourceType: "module",
    allowAwaitOutsideFunction: true
  });
  const nodes = [];
  walk(ast, (node, ancestors) => {
    if (node.type === "VariableDeclarator" || node.type === "AssignmentExpression") {
      nodes.push({
        ...node,
        executionUncertain: isStructurallyUncertain(ancestors)
      });
    }
    if (node.type === "CallExpression" && getSkyMethod(node.callee)) {
      nodes.push({
        ...node,
        executionUncertain: isStructurallyUncertain(ancestors)
      });
    }
  });
  nodes.sort((left, right) => left.start - right.start);

  const calls = [];
  for (const node of nodes) {
    if (node.type === "VariableDeclarator" && node.id.type === "Identifier") {
      if (node.executionUncertain) {
        environment.delete(node.id.name);
        continue;
      }
      const value = evaluateStatic(node.init, environment);
      if (value !== undefined) environment.set(node.id.name, value);
      else environment.delete(node.id.name);
      continue;
    }
    if (
      node.type === "AssignmentExpression" &&
      node.operator === "=" &&
      node.left.type === "Identifier"
    ) {
      if (node.executionUncertain) {
        environment.delete(node.left.name);
        continue;
      }
      const value = evaluateStatic(node.right, environment);
      if (value !== undefined) environment.set(node.left.name, value);
      else environment.delete(node.left.name);
      continue;
    }
    if (node.type === "CallExpression") {
      const method = getSkyMethod(node.callee);
      if (!method) continue;
      const evaluated = evaluateStaticDetailed(node.arguments[0], environment);
      calls.push({
        method,
        args: evaluated.value ?? {},
        argumentsComplete: evaluated.complete,
        executionUncertain: node.executionUncertain === true,
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
  return evaluateStaticDetailed(node, environment).value;
}

function evaluateStaticDetailed(node, environment) {
  const incomplete = value => ({ value, complete: false });
  const complete = value => ({ value, complete: true });
  if (!node) return incomplete(undefined);
  if (node.type === "Literal") return complete(node.value);
  if (node.type === "Identifier") {
    return environment.has(node.name) ? complete(environment.get(node.name)) : incomplete(undefined);
  }
  if (node.type === "MemberExpression") {
    const objectResult = evaluateStaticDetailed(node.object, environment);
    const key = node.computed
      ? evaluateStatic(node.property, environment)
      : node.property.type === "Identifier" ? node.property.name : undefined;
    if (objectResult.complete && objectResult.value && (typeof key === "string" || typeof key === "number")
      && key in Object(objectResult.value)) return complete(objectResult.value[key]);
    return incomplete(undefined);
  }
  if (node.type === "UnaryExpression" && ["+", "-"].includes(node.operator)) {
    const result = evaluateStaticDetailed(node.argument, environment);
    return result.complete && typeof result.value === "number"
      ? complete(node.operator === "-" ? -result.value : result.value) : incomplete(undefined);
  }
  if (node.type === "BinaryExpression" && ["+", "-", "*", "/", "%", "**"].includes(node.operator)) {
    const left = evaluateStaticDetailed(node.left, environment);
    const right = evaluateStaticDetailed(node.right, environment);
    if (!left.complete || !right.complete) return incomplete(undefined);
    if (node.operator === "+") return complete(left.value + right.value);
    if (typeof left.value !== "number" || typeof right.value !== "number") return incomplete(undefined);
    return complete({ "-": left.value - right.value, "*": left.value * right.value,
      "/": left.value / right.value, "%": left.value % right.value, "**": left.value ** right.value }[node.operator]);
  }
  if (node.type === "TemplateLiteral" && node.expressions.length === 0) {
    return complete(node.quasis[0]?.value?.cooked ?? "");
  }
  if (node.type === "ArrayExpression") {
    const results = node.elements.map(element => evaluateStaticDetailed(element, environment));
    return { value: results.map(result => result.value), complete: results.every(result => result.complete) };
  }
  if (node.type === "ObjectExpression") {
    const value = {};
    for (const property of node.properties) {
      if (property.type !== "Property" || property.computed || property.kind !== "init") {
        return incomplete(value);
      }
      const key = property.key.type === "Identifier" ? property.key.name : property.key.value;
      if (typeof key !== "string" && typeof key !== "number") continue;
      const propertyValue = evaluateStaticDetailed(property.value, environment);
      if (!propertyValue.complete) return incomplete(value);
      value[key] = propertyValue.value;
    }
    return complete(value);
  }
  return incomplete(undefined);
}

function isStructurallyUncertain(ancestors) {
  return ancestors.some(parent => [
    "IfStatement", "ConditionalExpression", "SwitchStatement", "ForStatement",
    "ForInStatement", "ForOfStatement", "WhileStatement", "DoWhileStatement",
    "TryStatement", "CatchClause", "FunctionDeclaration", "FunctionExpression",
    "ArrowFunctionExpression"
  ].includes(parent.type));
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
  for (const [field, value] of Object.entries(sanitized)) {
    if (sensitiveFields.includes(field) || typeof value !== "string") continue;
    if (!/^(app|key|direction|role|element_index|x|y|from_x|from_y|to_x|to_y)$/i.test(field)) {
      sanitized[`${field}_length`] = value.length;
      delete sanitized[field];
    }
  }
  return sanitized;
}

function normalizeAppIdentifier(value) {
  const normalized = String(value ?? "").trim().toLowerCase();
  if (["safari", "com.apple.safari"].includes(normalized)) return "com.apple.safari";
  return normalized;
}

function stableActionId(record, index, call) {
  const seed = [record.payload?.call_id, record.timestamp, index, call.method, call.sourceStart].join(":");
  return `act_${createHash("sha256").update(seed).digest("hex").slice(0, 16)}`;
}

function durationToMilliseconds(duration) {
  return (Number(duration?.secs ?? 0) * 1000) + (Number(duration?.nanos ?? 0) / 1_000_000);
}

function walk(node, visit, ancestors = []) {
  if (!node || typeof node !== "object") return;
  visit(node, ancestors);
  for (const [key, value] of Object.entries(node)) {
    if (["start", "end", "loc"].includes(key)) continue;
    if (Array.isArray(value)) {
      for (const child of value) walk(child, visit, [...ancestors, node]);
    } else if (value && typeof value === "object" && typeof value.type === "string") {
      walk(value, visit, [...ancestors, node]);
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
