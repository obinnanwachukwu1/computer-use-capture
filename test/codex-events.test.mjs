import assert from "node:assert/strict";
import test from "node:test";
import { appendFile, mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  extractComputerUseEvents,
  extractSkyCalls,
  mergeAccessibilityState,
  parseAccessibilityElements
} from "../lib/codex-events.mjs";
import {
  resolveAccessibilityTarget,
  resolveAccessibilityTargets
} from "../lib/accessibility-resolver.mjs";
import { mapEventCoordinates, validateCoordinateSpace } from "../lib/coordinate-mapper.mjs";
import { redactEventForPersistence } from "../lib/redaction.mjs";
import { CodexEventTailer } from "../lib/codex-event-tailer.mjs";

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

test("persistence redaction removes screenshot cache paths", () => {
  const redacted = redactEventForPersistence({
    action: "click",
    coordinateResolution: {
      provenance: "direct",
      screenshot: { width: 1000, height: 800, evidence: "/private/var/com.openai.sky/screenshot.png" }
    }
  });
  assert.deepEqual(redacted.coordinateResolution.screenshot, { width: 1000, height: 800 });
  assert.equal(JSON.stringify(redacted).includes("com.openai.sky"), false);
});

test("evaluates arithmetic coordinates but marks calls inside control flow uncertain", () => {
  const calls = extractSkyCalls(`
    const rect = { x: 100, width: 80 };
    await sky.click({ app: "Safari", x: rect.x + rect.width / 2, y: 200 });
    if (false) await sky.click({ app: "Safari", x: 1, y: 2 });
  `);
  assert.equal(calls[0].args.x, 140);
  assert.equal(calls[0].argumentsComplete, true);
  assert.equal(calls[0].executionUncertain, false);
  assert.equal(calls[1].executionUncertain, true);
});

test("does not let conditional assignments or object spreads masquerade as static facts", () => {
  const conditional = extractSkyCalls(`
    let point = { app: "Safari", x: 10, y: 20 };
    if (ready) point = { app: "Safari", x: 90, y: 100 };
    await sky.click(point);
  `);
  assert.equal(conditional[0].argumentsComplete, false);

  const spread = extractSkyCalls(`
    const point = { app: "Safari", x: 10, y: 20 };
    await sky.click({ ...point, x: 30 });
  `);
  assert.equal(spread[0].argumentsComplete, false);
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

  state = mergeAccessibilityState(state, `
The following is a diff from the previous accessibility tree.
- 34 text 2x
  `);
  assert.equal(state.elements.has(34), false);

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

  const nativeText = parseAccessibilityElements(`
    45 text entry area (settable, string) First Text View
    46 text entry area Description: Formula Bar. A,1, ID: XLFormulaEditor
    47 list box (settable, string) Selected account
  `);
  assert.equal(nativeText.get(45).role, "text entry area");
  assert.equal(nativeText.get(45).label, "First Text View");
  assert.deepEqual(nativeText.get(45).qualifiers, ["settable", "string"]);
  assert.equal(nativeText.get(46).role, "text entry area");
  assert.equal(nativeText.get(46).description, "Formula Bar. A,1");
  assert.equal(nativeText.get(47).role, "list box");
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

  const latestPartialTree = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "button", label: "24H" } },
    observations: [
      {
        observedAt: "2026-07-13T14:09:54.000Z", windowBounds, treeComplete: true,
        elements: [{ index: 42, role: "AXButton", title: "24H", bounds: { x: 800, y: 100, width: 36, height: 24 } }]
      },
      {
        observedAt: "2026-07-13T14:09:55.000Z", windowBounds, treeComplete: false,
        elements: [{ index: 12, role: "AXButton", title: "Page Menu", bounds: { x: 500, y: 50, width: 20, height: 20 } }]
      }
    ],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(latestPartialTree.targetResolution.provenance, "ax-identity");
  assert.equal(latestPartialTree.semanticTarget.nativeElementIndex, 42);

  const exactIdentityInPartialTree = resolveAccessibilityTarget({
    event: {
      ...base,
      accessibilityTarget: {
        role: "button",
        description: "New Tab",
        identifier: "NewTabButton"
      }
    },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z",
      windowBounds,
      treeComplete: false,
      elements: [{
        index: 50,
        role: "AXButton",
        description: "New Tab",
        identifier: "NewTabButton",
        bounds: { x: 950, y: 50, width: 37, height: 52 }
      }]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(exactIdentityInPartialTree.targetResolution.provenance, "ax-identity");
  assert.equal(exactIdentityInPartialTree.semanticTarget.nativeElementIndex, 50);

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

  const localizedRoleIdentity = resolveAccessibilityTarget({
    event: {
      ...base,
      accessibilityTarget: {
        role: "text entry area", label: "First Text View", roleKnown: true
      }
    },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [{
        index: 4, role: "AXTextArea", roleDescription: "text entry area",
        identifier: "First Text View",
        // Native editors commonly fill nearly the entire document window.
        bounds: { x: 120, y: 100, width: 900, height: 700 }
      }]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(localizedRoleIdentity.targetResolution.provenance, "ax-identity");
  assert.equal(localizedRoleIdentity.semanticTarget.nativeElementIndex, 4);

  const initialWatcherSnapshot = resolveAccessibilityTarget({
    event: {
      ...base,
      timestamp: "2026-07-13T14:09:55.800Z",
      accessibilityTarget: { role: "text entry area", identifier: "First Text View" }
    },
    observations: [{
      // The watcher intentionally starts before capture commits its first
      // frame, so the initial full tree can lead captureStartedAt slightly.
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [{
        index: 4, role: "AXTextArea", identifier: "First Text View",
        bounds: { x: 120, y: 100, width: 900, height: 700 }
      }]
    }],
    captureStartedAt: "2026-07-13T14:09:55.700Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(initialWatcherSnapshot.targetResolution.provenance, "ax-identity");

  const visibleIdentity = resolveAccessibilityTarget({
    event: { ...base, accessibilityTarget: { role: "button", label: "Create monitor" } },
    observations: [
      {
        observedAt: "2026-07-13T14:09:55.450Z", windowBounds,
        elements: [{
          index: 70, role: "AXButton", title: "Create monitor",
          bounds: { x: 1099, y: 849, width: 1, height: 1 }
        }]
      },
      {
        observedAt: "2026-07-13T14:09:54.900Z", windowBounds,
        elements: [{
          index: 70, role: "AXButton", title: "Create monitor",
          bounds: { x: 900, y: 650, width: 120, height: 36 }
        }]
      }
    ],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(visibleIdentity.semanticTarget.bounds.heightNorm, 0.045);

  const actionLocalFocus = resolveAccessibilityTarget({
    event: {
      ...base,
      action: "type_text",
      args: { app: "Chrome" },
      timestamp: "2026-07-13T14:09:55.500Z"
    },
    observations: [
      {
        observedAt: "2026-07-13T14:09:55.650Z", windowBounds, focused: true,
        role: "AXTextField", title: "Monitor name",
        bounds: { x: 300, y: 500, width: 300, height: 36 }, elements: []
      },
      {
        observedAt: "2026-07-13T14:09:56.250Z", windowBounds, focused: true,
        role: "AXButton", title: "Create monitor",
        bounds: { x: 800, y: 650, width: 120, height: 36 }, elements: []
      }
    ],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(actionLocalFocus.semanticTarget.title, "Monitor name");

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

  const namedMissingSibling = resolveAccessibilityTarget({
    event: {
      ...base,
      accessibilityTarget: { elementIndex: 94, role: "button", label: "1H" },
      accessibilityContext: {
        targetIndex: 94,
        before: { elementIndex: 93, role: "container", label: "Time range" },
        after: { elementIndex: 95, role: "button", label: "24H" }
      }
    },
    observations: [{
      observedAt: "2026-07-13T14:09:55.600Z", windowBounds,
      elements: [
        { index: 41, role: "AXGroup", title: "Time range", bounds: { x: 800, y: 100, width: 110, height: 32 } },
        { index: 42, role: "AXButton", title: "24H", bounds: { x: 840, y: 104, width: 36, height: 24 } }
      ]
    }],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(namedMissingSibling.targetResolution.provenance, "unresolved");
});

test("ordered Computer Use focus ownership outranks a lagging AX focus snapshot", () => {
  const windowBounds = { x: 100, y: 50, width: 1000, height: 800 };
  const timing = {
    toolCallStartedAt: "2026-07-13T14:09:55.000Z",
    toolCallEndedAt: "2026-07-13T14:09:56.300Z"
  };
  const events = [
    {
      actionId: "click-name", timestamp: "2026-07-13T14:09:55.200Z", action: "click",
      args: { element_index: 12 }, timing,
      accessibilityTarget: { role: "text entry area", label: "Monitor name" }
    },
    {
      actionId: "select-name", timestamp: "2026-07-13T14:09:55.400Z", action: "press_key",
      args: { key: "CMD+A" }, timing
    },
    {
      actionId: "newline-name", timestamp: "2026-07-13T14:09:55.500Z", action: "press_key",
      args: { key: "Return" }, timing
    },
    {
      actionId: "type-name", timestamp: "2026-07-13T14:09:55.600Z", action: "type_text",
      args: { text: "Production API" }, timing
    }
  ];
  const observations = [{
    observedAt: "2026-07-13T14:09:55.250Z", windowBounds, focused: true,
    role: "AXTextField", title: "Alert threshold",
    bounds: { x: 650, y: 650, width: 300, height: 36 },
    elements: [{
      index: 30, role: "AXTextArea", title: "Monitor name", identifier: "Monitor name",
      bounds: { x: 200, y: 650, width: 300, height: 36 }
    }]
  }];
  const resolved = resolveAccessibilityTargets({
    events, observations, captureStartedAt: "2026-07-13T14:00:00.000Z",
    captureWidth: 1000, captureHeight: 800
  });

  assert.equal(resolved[0].semanticTarget.nativeElementIndex, 30);
  assert.equal(resolved[1].semanticTarget.title, "Monitor name");
  assert.equal(resolved[2].semanticTarget.title, "Monitor name");
  assert.equal(resolved[3].semanticTarget.title, "Monitor name");
  assert.equal(resolved[3].targetResolution.focusOwnership, "computer-use-sequence");
  assert.equal(resolved[3].coordinates.captureX, resolved[0].coordinates.captureX);
});

test("an explicit non-text activation ends Computer Use focus ownership", () => {
  const windowBounds = { x: 0, y: 0, width: 1000, height: 800 };
  const timing = {
    toolCallStartedAt: "2026-07-13T14:09:55.000Z",
    toolCallEndedAt: "2026-07-13T14:09:56.300Z"
  };
  const observations = [{
    observedAt: "2026-07-13T14:09:55.100Z", windowBounds,
    elements: [
      { index: 1, role: "AXTextField", title: "Name", bounds: { x: 100, y: 100, width: 300, height: 36 } },
      { index: 2, role: "AXButton", title: "Save", bounds: { x: 800, y: 700, width: 100, height: 36 } }
    ]
  }];
  const resolved = resolveAccessibilityTargets({
    events: [
      { timestamp: "2026-07-13T14:09:55.100Z", action: "click", args: { element_index: 1 }, timing, accessibilityTarget: { role: "text field", label: "Name" } },
      { timestamp: "2026-07-13T14:09:55.300Z", action: "click", args: { element_index: 2 }, timing, accessibilityTarget: { role: "button", label: "Save" } },
      { timestamp: "2026-07-13T14:09:55.500Z", action: "type_text", args: { text: "must not inherit" }, timing }
    ],
    observations, captureStartedAt: "2026-07-13T14:00:00.000Z",
    captureWidth: 1000, captureHeight: 800
  });

  assert.equal(resolved[2].targetResolution.provenance, "unresolved");
  assert.equal(resolved[2].semanticTarget, undefined);
});

test("records a semantic viewport relocation when Computer Use brings an offscreen target into view", () => {
  const event = {
    timestamp: "2026-07-13T14:09:55.500Z",
    action: "click",
    args: { app: "Safari", element_index: 96 },
    accessibilityTarget: { role: "button", label: "30 days" },
    timing: {
      toolCallStartedAt: "2026-07-13T14:09:55.000Z",
      toolCallEndedAt: "2026-07-13T14:09:56.300Z"
    }
  };
  const windowBounds = { x: 100, y: 50, width: 1000, height: 800 };
  const resolved = resolveAccessibilityTarget({
    event,
    observations: [
      {
        observedAt: "2026-07-13T14:09:54.800Z", windowBounds, treeComplete: true,
        elements: [{ index: 105, role: "AXButton", title: "30 days", bounds: { x: 820, y: 900, width: 70, height: 32 } }]
      },
      {
        observedAt: "2026-07-13T14:09:55.900Z", windowBounds, treeComplete: true,
        elements: [{ index: 105, role: "AXButton", title: "30 days", bounds: { x: 820, y: 420, width: 70, height: 32 } }]
      }
    ],
    captureStartedAt: "2026-07-13T14:00:00.000Z", captureWidth: 1000, captureHeight: 800
  });
  assert.equal(resolved.semanticTarget.viewportRelocation.kind, "target-entered-viewport");
  assert.equal(resolved.semanticTarget.viewportRelocation.fromVisibleFraction, 0);
  assert.ok(Math.abs(resolved.semanticTarget.viewportRelocation.toVisibleFraction - 1) < 1e-9);
  assert.ok(resolved.semanticTarget.viewportRelocation.displacementNorm > 0.5);
  assert.equal(resolved.semanticTarget.viewportRelocation.postActionOffsetMs, 400);
});

test("retains unknown future sky actions for fail-open compatibility", () => {
  const [call] = extractSkyCalls(`await sky.future_action({ x: 12, y: 34 });`);
  assert.equal(call.method, "future_action");
  assert.deepEqual(call.args, { x: 12, y: 34 });
});

test("normalizes both historical direct MCP and current node_repl envelopes", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-events-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const records = [
    {
      timestamp: "2026-06-17T00:00:02.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "computer-use", tool: "click", arguments: { app: "Safari", x: 10, y: 20 } },
        duration: { secs: 1, nanos: 0 },
        result: { Ok: { content: [] } }
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
        duration: { secs: 1, nanos: 0 },
        result: { Ok: { content: [] } }
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

test("live tailing preserves prior AX state and waits for complete appended JSONL", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-live-tail-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const record = (timestamp, code, text = "") => JSON.stringify({
    timestamp,
    type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      invocation: { server: "node_repl", tool: "js", arguments: { code } },
      duration: { secs: 0, nanos: 100_000_000 },
      result: { Ok: { content: text ? [{ type: "text", text }] : [] } }
    }
  });
  const context = record(
    "2026-06-17T00:00:00.500Z",
    "await sky.get_app_state({app:'com.apple.Safari'})",
    "11 button Start practicing"
  );
  const action = record(
    "2026-06-17T00:00:02.000Z",
    "await sky.click({app:'com.apple.Safari', element_index:11})"
  );
  const split = Math.floor(action.length / 2);
  await writeFile(sessionFile, `${context}\n${action.slice(0, split)}`);
  const tailer = new CodexEventTailer({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:01.000Z"
  });
  await tailer.poll();
  assert.equal(tailer.snapshot().events.length, 0);

  await appendFile(sessionFile, `${action.slice(split)}\n`);
  await tailer.poll();
  const result = tailer.snapshot({ captureEndedAt: "2026-06-17T00:00:03.000Z" });
  assert.equal(result.events.length, 1);
  assert.equal(result.events[0].accessibilityTarget.label, "Start practicing");
  assert.equal(result.live.invalidCompleteLines, 0);
});

test("carries only statically proven values across persistent node_repl invocations", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-repl-env-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const resultEnvelope = { Ok: { content: [] } };
  const record = (timestamp, code, result = resultEnvelope) => ({
    timestamp,
    type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      invocation: { server: "node_repl", tool: "js", arguments: { code } },
      duration: { secs: 0, nanos: 100_000_000 },
      result
    }
  });
  const records = [
    record("2026-06-17T00:00:00.500Z", "var persistentApp = 'com.apple.Safari';"),
    record("2026-06-17T00:00:01.000Z", "await sky.get_app_state({app:persistentApp})", {
      Ok: { content: [{ type: "text", text: "11 button Refresh" }] }
    }),
    record("2026-06-17T00:00:02.000Z", "await sky.click({app:persistentApp, element_index:11})"),
    record("2026-06-17T00:00:02.500Z", "persistentApp = await discoverApp();"),
    record("2026-06-17T00:00:03.000Z", "await sky.click({app:persistentApp, element_index:11})")
  ];
  await writeFile(sessionFile, records.map(value => JSON.stringify(value)).join("\n"));
  const extracted = await extractComputerUseEvents({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureEndedAt: "2026-06-17T00:00:04.000Z"
  });
  assert.equal(extracted.events.length, 1);
  assert.equal(extracted.events[0].args.app, "com.apple.Safari");
  assert.equal(extracted.events[0].accessibilityTarget.label, "Refresh");
  assert.equal(extracted.warnings.filter(warning => warning.type === "action_unverifiable").length, 1);
});

test("joins element-index actions to the preceding Computer Use accessibility state", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-index-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const records = [
    {
      timestamp: "2026-06-17T00:00:01.000Z",
      type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "node_repl", tool: "js", arguments: {
          code: "await sky.get_app_state({app:'Safari'})"
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
        duration: { secs: 0, nanos: 400_000_000 },
        result: { Ok: { content: [] } }
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
  assert.match(result.events[0].actionId, /^act_[0-9a-f]{16}$/);
});

test("exact post-action focus overrides a stale same-number AX control", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-focus-transaction-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const records = [
    {
      timestamp: "2026-06-17T00:00:01.000Z", type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "node_repl", tool: "js", arguments: {
          code: "await sky.get_app_state({app:'com.apple.Safari'})"
        } },
        duration: { secs: 0, nanos: 100_000_000 },
        result: { Ok: { content: [{ type: "text", text: "185 full screen button" }] } }
      }
    },
    {
      timestamp: "2026-06-17T00:00:02.000Z", type: "event_msg",
      payload: {
        type: "mcp_tool_call_end",
        invocation: { server: "node_repl", tool: "js", arguments: {
          code: "await sky.click({app:'com.apple.Safari',element_index:185}); await sky.get_app_state({app:'com.apple.Safari',disableDiff:true})"
        } },
        duration: { secs: 0, nanos: 200_000_000 },
        result: { Ok: { content: [{ type: "text", text:
          "210 full screen button\nThe focused UI element is 186 button Next step"
        }] } }
      }
    }
  ];
  await writeFile(sessionFile, records.map(JSON.stringify).join("\n"));
  const result = await extractComputerUseEvents({
    sessionFile,
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureEndedAt: "2026-06-17T00:00:03.000Z"
  });
  assert.equal(result.events[0].accessibilityTarget.role, "full screen button");
  assert.equal(result.events[0].postActionFocus.label, "Next step");

  const resolved = resolveAccessibilityTarget({
    event: result.events[0],
    observations: [{
      observedAt: "2026-06-17T00:00:02.050Z",
      windowBounds: { x: 0, y: 0, width: 1000, height: 800 },
      elements: [
        { index: 318, role: "AXButton", title: "Next step", bounds: { x: 700, y: 700, width: 40, height: 30 } },
        { index: 319, role: "AXButton", title: "", bounds: { x: 40, y: 20, width: 15, height: 15 } }
      ]
    }],
    captureStartedAt: "2026-06-17T00:00:00.000Z",
    captureWidth: 1000,
    captureHeight: 800
  });
  assert.equal(resolved.semanticTarget.title, "Next step");
  assert.equal(resolved.coordinates.captureX, 720);
});

test("a corroborated clicked control outranks focus moved into its revealed surface", () => {
  const event = {
    timestamp: "2026-07-15T21:49:31.439Z",
    action: "click",
    args: { app: "com.google.Chrome", element_index: 167 },
    accessibilityTarget: {
      elementIndex: 167, role: "pop up button", roleKnown: true, label: "Pick a date"
    },
    postActionFocus: {
      elementIndex: 360, role: "button", roleKnown: true, label: "Go to the Previous Month"
    },
    timing: {
      toolCallStartedAt: "2026-07-15T21:49:30.918Z",
      toolCallEndedAt: "2026-07-15T21:49:33.002Z"
    }
  };
  const resolved = resolveAccessibilityTarget({
    event,
    observations: [{
      observedAt: "2026-07-15T21:49:25.319Z",
      treeComplete: true,
      windowBounds: { x: 3817, y: -239, width: 1406, height: 972 },
      elements: [{
        index: 439, role: "AXPopUpButton", roleDescription: "pop up button",
        title: "Pick a date", bounds: { x: 4406, y: 243, width: 213, height: 32 }
      }]
    }],
    captureStartedAt: "2026-07-15T21:49:04.000Z",
    captureWidth: 1406,
    captureHeight: 972
  });

  assert.equal(resolved.targetResolution.provenance, "ax-identity");
  assert.equal(resolved.semanticTarget.title, "Pick a date");
  assert.equal(resolved.semanticTarget.nativeElementIndex, 439);
});

test("does not invent actions for failed Computer Use calls", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-failed-"));
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

test("skips structurally uncertain calls instead of fabricating actions", async () => {
  const directory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-uncertain-"));
  const sessionFile = path.join(directory, "rollout.jsonl");
  const record = {
    timestamp: "2026-06-17T00:00:02.000Z", type: "event_msg",
    payload: {
      type: "mcp_tool_call_end",
      call_id: "call_uncertain",
      invocation: { server: "node_repl", tool: "js", arguments: {
        code: "if (ready) await sky.click({app:'Safari', x:10, y:20})"
      } },
      duration: { secs: 1, nanos: 0 }, result: { Ok: { content: [], isError: false } }
    }
  };
  await writeFile(sessionFile, JSON.stringify(record));
  const result = await extractComputerUseEvents({
    sessionFile, captureStartedAt: "2026-06-17T00:00:00.000Z", captureEndedAt: "2026-06-17T00:00:04.000Z"
  });
  assert.equal(result.events.length, 0);
  assert.equal(result.warnings[0].type, "action_unverifiable");
});

test("validates direct coordinate evidence per event and fails closed on window drift", () => {
  const event = {
    actionId: "act_aabbccddeeff0011", action: "click", timestamp: "2026-07-13T12:00:02.000Z",
    args: { x: 500, y: 400 }
  };
  const screenshotSpace = { width: 1000, height: 800, confidence: "event_nearby", ageMs: 50 };
  assert.equal(validateCoordinateSpace({ screenshotSpace, captureWidth: 2000, captureHeight: 1600 }).valid, true);
  const mapped = mapEventCoordinates({ event, screenshotSpace, captureWidth: 2000, captureHeight: 1600 });
  assert.equal(mapped.coordinates.captureX, 1000);
  assert.equal(mapped.coordinateResolution.confidence, 0.99);

  const drifted = mapEventCoordinates({
    event, screenshotSpace, captureWidth: 2000, captureHeight: 1600,
    observations: [
      { observedAt: "2026-07-13T12:00:00.000Z", targetIsFrontmost: true, windowBounds: { x: 0, y: 0, width: 1000, height: 800 } },
      { observedAt: "2026-07-13T12:00:02.000Z", targetIsFrontmost: true, windowBounds: { x: 50, y: 0, width: 1000, height: 800 } }
    ]
  });
  assert.equal(drifted.coordinates, undefined);
  assert.equal(drifted.coordinateResolution.reason, "capture-window-geometry-changed");
});

test("system-owned foreground UI blocks both direct and AX-inferred cursor targets", () => {
  const timestamp = "2026-07-13T12:00:02.000Z";
  const observations = [{
    observedAt: "2026-07-13T12:00:01.900Z",
    targetIsFrontmost: false,
    frontmostIsSystemSurface: true,
    frontmostBundleIdentifier: "com.apple.appkit.xpc.openAndSavePanelService",
    windowBounds: { x: 0, y: 0, width: 1000, height: 800 },
    elements: [{ index: 5, role: "AXButton", title: "Save", bounds: { x: 800, y: 700, width: 80, height: 30 } }]
  }];
  const direct = resolveAccessibilityTarget({
    event: {
      actionId: "act_aabbccddeeff0011", action: "click", timestamp,
      args: { x: 800, y: 700 },
      coordinateResolution: { provenance: "unresolved", reason: "target-app-not-frontmost" }
    },
    observations,
    captureStartedAt: "2026-07-13T12:00:00.000Z",
    captureWidth: 1000,
    captureHeight: 800
  });
  assert.equal(direct.targetResolution.provenance, "unresolved");
  assert.equal(direct.targetResolution.reason, "target-app-not-frontmost");

  const indexed = resolveAccessibilityTarget({
    event: {
      actionId: "act_bbccddee00112233", action: "click", timestamp,
      args: { element_index: 5 },
      accessibilityTarget: { role: "button", label: "Save" },
      timing: { toolCallStartedAt: timestamp, toolCallEndedAt: timestamp }
    },
    observations,
    captureStartedAt: "2026-07-13T12:00:00.000Z",
    captureWidth: 1000,
    captureHeight: 800
  });
  assert.equal(indexed.targetResolution.provenance, "unresolved");
  assert.equal(indexed.targetResolution.reason, "system-ui-frontmost");
});

test("an unrelated ordinary frontmost app does not invalidate application-filter capture", () => {
  const resolved = resolveAccessibilityTarget({
    event: {
      actionId: "act_ccddee0011223344", action: "click",
      timestamp: "2026-07-13T12:00:02.000Z",
      args: { element_index: 5 },
      accessibilityTarget: { role: "button", label: "Continue" },
      timing: {
        toolCallStartedAt: "2026-07-13T12:00:01.800Z",
        toolCallEndedAt: "2026-07-13T12:00:02.200Z"
      }
    },
    observations: [{
      observedAt: "2026-07-13T12:00:01.900Z",
      targetIsFrontmost: false,
      frontmostIsSystemSurface: false,
      frontmostBundleIdentifier: "com.openai.codex",
      windowBounds: { x: 0, y: 0, width: 1000, height: 800 },
      elements: [{ index: 5, role: "AXButton", title: "Continue", bounds: { x: 800, y: 700, width: 80, height: 30 } }]
    }],
    captureStartedAt: "2026-07-13T12:00:00.000Z",
    captureWidth: 1000,
    captureHeight: 800
  });
  assert.equal(resolved.targetResolution.provenance, "ax-identity");
});
