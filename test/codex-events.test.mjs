import assert from "node:assert/strict";
import test from "node:test";
import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  extractComputerUseEvents,
  extractSkyCalls,
  mergeAccessibilityState,
  parseAccessibilityElements
} from "../lib/codex-events.mjs";
import { resolveAccessibilityTarget } from "../lib/accessibility-resolver.mjs";

test("extracts unchanged sky x-y actions through local variables", () => {
  const calls = extractSkyCalls(`
    const target = { app: "com.apple.Safari", x: 640, y: 430 };
    await sky.get_app_state({ app: target.app });
    await sky.click(target);
  `);
  assert.deepEqual(calls.map(({ method, args }) => ({ method, args })), [
    { method: "get_app_state", args: { app: "com.apple.Safari" } },
    { method: "click", args: { app: "com.apple.Safari", x: 640, y: 430 } }
  ]);
});

test("parses Computer Use element-index descriptors without requiring coordinates", () => {
  const elements = parseAccessibilityElements(`
    11 link Start practicing, Value: tracecode.app/dashboard
    12 button Open settings, Help: Settings
    13 text field (settable, string) Description: Search problems...
  `);
  assert.deepEqual(elements.get(11), {
    elementIndex: 11,
    role: "link",
    roleKnown: true,
    rawDescriptor: "link Start practicing, Value: tracecode.app/dashboard",
    label: "Start practicing",
    value: "tracecode.app/dashboard"
  });
  assert.equal(elements.get(12).label, "Open settings");
  assert.equal(elements.get(13).description, "Search problems...");
});

test("parses compound Computer Use roles and merges partial and diff state", () => {
  let state = mergeAccessibilityState(undefined, `
Window: "TraceCode", App: Safari.
  31 pop up button Playback speed
  32 button Play trace
  33 slider (settable, float) 1
`);
  assert.equal(state.elements.get(31).role, "pop up button");
  assert.equal(state.elements.get(31).label, "Playback speed");

  state = mergeAccessibilityState(state, "32 button Pause trace");
  assert.equal(state.elements.get(31).label, "Playback speed");
  assert.equal(state.elements.get(32).label, "Pause trace");

  state = mergeAccessibilityState(state, `
The following is a diff from the previous accessibility tree.
Removed element IDs: 33
Window: "TraceCode", App: Safari.
+\t\t34 text 2x
~\t\t32 button Pause trace
`);
  assert.equal(state.elements.get(31).label, "Playback speed");
  assert.equal(state.elements.get(32).label, "Pause trace");
  assert.equal(state.elements.has(33), false);
  assert.equal(state.elements.get(34).label, "2x");

  const variants = parseAccessibilityElements(`
    40 AXListMarker •
    41 checkbox (settable, integer) Description: Include archived, Help: Toggles archived rows, ID: archive-toggle
    42 section (disabled)
    43 Edit
  `);
  assert.equal(variants.get(40).role, "list marker");
  assert.equal(variants.get(40).label, "•");
  assert.deepEqual(variants.get(41).qualifiers, ["settable", "integer"]);
  assert.equal(variants.get(41).help, "Toggles archived rows");
  assert.equal(variants.get(41).identifier, "archive-toggle");
  assert.equal(variants.get(43).roleKnown, false);
  assert.equal(variants.get(43).label, "Edit");
  assert.equal(variants.get(43).rawDescriptor, "Edit");

  const signature = parseAccessibilityElements(`
    44 button function bfs(graph, start)
  `);
  assert.equal(signature.get(44).label, "function bfs(graph, start)");
  assert.equal(signature.get(44).qualifiers, undefined);
});

test("resolves native geometry by identity, post-action focus, and structural anchors", () => {
  const base = {
    timestamp: "2026-07-13T14:09:55.500Z",
    action: "click",
    args: { app: "Safari", element_index: 25 },
    timing: {
      toolCallStartedAt: "2026-07-13T14:09:54.900Z",
      toolCallEndedAt: "2026-07-13T14:09:56.300Z"
    }
  };
  const windowBounds = { x: 100, y: 50, width: 1000, height: 800 };
  const identity = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "button", label: "Play trace" } },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [{ index: 38, role: "AXButton", title: "Play trace", bounds: { x: 200, y: 700, width: 30, height: 30 } }]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(identity.targetResolution.provenance, "ax-identity");
  assert.equal(identity.semanticTarget.nativeElementIndex, 38);

  const stablePage = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "link", label: "Start practicing" } },
    observations: [{
      // Change-driven AX snapshots describe state intervals. This snapshot is
      // old in wall time but remains the latest tree before the action.
      observedAt: "2026-07-13T14:09:40.000Z", windowBounds,
      elements: [{ index: 11, role: "AXLink", title: "Start practicing", bounds: { x: 600, y: 600, width: 120, height: 40 } }]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(stablePage.targetResolution.provenance, "ax-identity");
  assert.equal(stablePage.semanticTarget.nativeElementIndex, 11);

  const subroleIdentity = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "standard window", label: "TraceCode" } },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [{
        index: 0, role: "AXWindow", subrole: "AXStandardWindow",
        roleDescription: "standard window", title: "TraceCode",
        bounds: { x: 200, y: 150, width: 400, height: 300 }
      }]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  // The match is valid even though Computer Use serialized the subrole while
  // native AX reports AXWindow as the primary role.
  assert.equal(subroleIdentity.targetResolution.provenance, "ax-identity");

  const focused = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "button", label: "Play trace" } },
    observations: [{
      observedAt: "2026-07-13T14:09:56.350Z", windowBounds, focused: true,
      role: "AXButton", title: "Play trace", bounds: { x: 200, y: 700, width: 30, height: 30 }, elements: []
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(focused.targetResolution.provenance, "ax-focus");

  const unrelatedFocus = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: undefined },
    observations: [{
      observedAt: "2026-07-13T14:09:56.350Z", windowBounds, focused: true,
      role: "AXButton", title: "Play trace", bounds: { x: 200, y: 700, width: 30, height: 30 }, elements: []
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(unrelatedFocus.targetResolution.provenance, "unresolved");
  assert.equal(unrelatedFocus.targetResolution.reason, "computer-use-identity-unavailable");

  const duplicateIdentity = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "link", label: "Start practicing" } },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [
        { index: 10, role: "AXLink", title: "Start practicing", bounds: { x: 100, y: 50, width: 1000, height: 800 } },
        { index: 11, role: "AXLink", title: "Start practicing", bounds: { x: 600, y: 600, width: 120, height: 40 } }
      ]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(duplicateIdentity.targetResolution.provenance, "ax-identity");
  assert.equal(duplicateIdentity.semanticTarget.nativeElementIndex, 11);

  const structural = resolveAccessibilityTarget({
    event: {
      ...base,
      args: { app: "Safari", element_index: 86 },
      accessibilityTarget: { elementIndex: 86, role: "button" },
      accessibilityContext: {
        targetIndex: 86,
        before: { elementIndex: 84, role: "slider", label: "(settable, float) 1" },
        after: { elementIndex: 90, role: "button", label: "Page Menu" }
      }
    },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [
        { index: 40, role: "AXSlider", title: "(settable, float) 1", bounds: { x: 1000, y: 650, width: 20, height: 80 } },
        { index: 42, role: "AXButton", title: "", bounds: { x: 1000, y: 630, width: 20, height: 20 } },
        { index: 46, role: "AXButton", title: "Page Menu", bounds: { x: 500, y: 50, width: 20, height: 20 } }
      ]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(structural.targetResolution.provenance, "ax-structural");
  assert.equal(structural.semanticTarget.nativeElementIndex, 42);
});

test("retains unknown future sky actions for fail-open compatibility", () => {
  const [call] = extractSkyCalls(`await sky.future_action({ x: 12, y: 34 });`);
  assert.equal(call.method, "future_action");
  assert.deepEqual(call.args, { x: 12, y: 34 });
});

test("normalizes both historical direct MCP and current node_repl envelopes", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-events-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const records = [
    {
      timestamp: "2026-06-17T00:00:02.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "computer-use", tool: "click", arguments: { app: "Safari", x: 10, y: 20 } },
        duration: { secs: 1, nanos: 0 }
      }
    },
    {
      timestamp: "2026-06-17T00:00:04.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: {
          server: "node_repl",
          tool: "js",
          arguments: { code: "await sky.press_key({app:'Safari', key:'Return'})" }
        },
        duration: { secs: 1, nanos: 0 }
      }
    }
  ];
  await writeFile(sessionFile, records.map(record => JSON.stringify(record)).join("\n"));
  const result = await extractComputerUseEvents({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureEndedAt: "2026-06-17T00:00:06.000Z"
  });
  assert.deepEqual(result.events.map(event => [event.action, event.timing.transport]), [
    ["click", "direct-mcp"],
    ["press_key", "node-repl-sky"]
  ]);
});

test("joins element-index actions to the preceding Computer Use accessibility state", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-index-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const records = [
    {
      timestamp: "2026-06-17T00:00:01.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "node_repl", tool: "js", arguments: {
          code: "await sky.get_app_state({app:'com.apple.Safari'})"
        } },
        duration: { secs: 0, nanos: 200_000_000 },
        result: { Ok: { content: [{ type: "text", text: "11 link Start practicing, Value: tracecode.app/dashboard" }] } }
      }
    },
    {
      timestamp: "2026-06-17T00:00:03.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "node_repl", tool: "js", arguments: {
          code: "await sky.click({app:'com.apple.Safari', element_index:11})"
        } },
        duration: { secs: 0, nanos: 400_000_000 }
      }
    }
  ];
  await writeFile(sessionFile, records.map(record => JSON.stringify(record)).join("\n"));
  const result = await extractComputerUseEvents({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureEndedAt: "2026-06-17T00:00:04.000Z"
  });
  assert.deepEqual(result.events[0].accessibilityTarget, {
    elementIndex: 11,
    role: "link",
    roleKnown: true,
    rawDescriptor: "link Start practicing, Value: tracecode.app/dashboard",
    label: "Start practicing",
    value: "tracecode.app/dashboard"
  });
});

test("does not invent actions for failed Computer Use calls", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "agentrecorder-failed-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const record = {
    timestamp: "2026-06-17T00:00:02.000Z",
    type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      invocation: { server: "node_repl", tool: "js", arguments: {
        code: "await sky.click({app:'com.apple.Safari', element_index:13})"
      } },
      duration: { secs: 0, nanos: 100_000_000 },
      result: { Ok: { isError: true, content: [{ type: "text", text: "element ID is no longer valid" }] } }
    }
  };
  await writeFile(sessionFile, JSON.stringify(record));
  const result = await extractComputerUseEvents({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureEndedAt: "2026-06-17T00:00:04.000Z"
  });
  assert.equal(result.events.length, 0);
  assert.equal(result.warnings[0].type, "tool_call_failed");
});
