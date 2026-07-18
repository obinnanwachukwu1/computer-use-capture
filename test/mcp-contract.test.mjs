import assert from "node:assert/strict";
import test from "node:test";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { captureModeFor, RecorderService, renderQuality } from "../lib/recorder-service.mjs";
import { codexThreadId } from "../lib/codex-request-context.mjs";

test("Codex request metadata binds recorder_start to the calling task", () => {
  assert.equal(codexThreadId({
    "x-codex-turn-metadata": {
      thread_id: "thread-fixture-primary",
      session_id: "fallback"
    }
  }), "thread-fixture-primary");
  assert.equal(codexThreadId({
    "x-codex-turn-metadata": { session_id: "session-fallback" }
  }), "session-fallback");
  assert.equal(codexThreadId({}), undefined);
});

test("apps use selected-window display filtering unless an operator explicitly overrides it", () => {
  assert.equal(captureModeFor("com.apple.TextEdit"), "window-crop");
  assert.equal(captureModeFor("com.google.Chrome"), "window-crop");
  assert.equal(captureModeFor("com.apple.TextEdit", "window"), "window");
  assert.equal(captureModeFor("com.apple.TextEdit", "application"), "application");
});

test("render quality rejects causal-order inversions", () => {
  assert.deepEqual(renderQuality(
    { pointerRendering: { omittedUnresolved: 0 } },
    {
      semanticCoverage: { unframedSustainedResponses: 0 },
      causalOrdering: { violations: 1 }
    }
  ), {
    status: "degraded",
    issues: ["1 action was rendered after its visual response began"]
  });
});

test("render quality exposes a failed global camera plan", () => {
  const quality = renderQuality(
    { pointerRendering: { omittedUnresolved: 0 } },
    {
      planFeasible: false,
      planFailure: "global production search exhausted at action 2",
      semanticCoverage: { unframedSustainedResponses: 0 },
      causalOrdering: { violations: 0 }
    }
  );
  assert.equal(quality.status, "degraded");
  assert.deepEqual(quality.issues, [
    "camera planner failed: global production search exhausted at action 2"
  ]);
});

test("render quality exposes low-density source enlargement", () => {
  assert.deepEqual(renderQuality(
    {
      pointerRendering: { omittedUnresolved: 0 },
      sourceRaster: { baseUpscaleFactor: 1.75 }
    },
    {
      planFeasible: true,
      semanticCoverage: { unframedSustainedResponses: 0 },
      causalOrdering: { violations: 0 }
    }
  ), {
    status: "degraded",
    issues: ["source raster was enlarged 1.75× before camera zoom"]
  });
});

test("recorder_start contract accepts the adapter fingerprint it emits", async () => {
  const contract = JSON.parse(await readFile(path.resolve("docs/mcp-tools.schema.json"), "utf8"));
  const startTool = contract.tools.find(tool => tool.name === "recorder_start");
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(startTool.outputSchema);
  assert.equal(validate({
    recordingId: "rec_contractfingerprint",
    state: "recording",
    startedAt: "2026-07-13T20:12:15.098Z",
    capture: {
      width: 2560,
      height: 1440,
      pixelsPerPoint: 2,
      codec: "hevc",
      mode: "window-crop"
    },
    introspection: {
      codexSession: "attached",
      formatFingerprint: "d2bcf99da22c6aeb"
    }
  }), true, JSON.stringify(validate.errors));
});

test("recorder_edit accepts system, custom, and solid render assets", async () => {
  const contract = JSON.parse(await readFile(path.resolve("docs/mcp-tools.schema.json"), "utf8"));
  const editTool = contract.tools.find(tool => tool.name === "recorder_edit");
  const ajv = new Ajv2020({ allErrors: true, strict: false });
  addFormats(ajv);
  const validate = ajv.compile(editTool.inputSchema);
  const recordingId = "rec_assetcontract";
  const review = {
    sourceRenderId: "ren_reviewsourcefixture",
    reason: "The inspected render crops the activated control."
  };
  assert.equal(validate({ recordingId, review, intents: {
    background: { type: "system-wallpaper" }, cursor: { asset: { type: "system" } }
  } }), true, JSON.stringify(validate.errors));
  assert.equal(validate({ recordingId, review, intents: {
    background: { type: "image", path: "/tmp/wallpaper.png" },
    cursor: { asset: { type: "image", path: "/tmp/cursor.png", metadataPath: "/tmp/cursor.json" } }
  } }), true, JSON.stringify(validate.errors));
  assert.equal(validate({ recordingId, review, intents: {
    background: { type: "solid", color: "#F6F7F9" }
  } }), true, JSON.stringify(validate.errors));
  assert.equal(validate({ recordingId, review, intents: {
    background: { type: "solid", color: "white" }
  } }), false);
  assert.equal(validate({ recordingId, intents: { zoom: { strength: 0.8 } } }), false);
});

test("MCP server publishes the reviewed seven-tool contract", async () => {
  const store = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-mcp-"));
  const firstCallerDirectory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-caller-a-"));
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.resolve("scripts/mcp-server.mjs")],
    env: {
      ...process.env,
      COMPUTER_USE_CAPTURE_STORE: store,
      COMPUTER_USE_CAPTURE_DAEMON_IDLE_MS: "10000"
    },
    cwd: firstCallerDirectory
  });
  const client = new Client({ name: "computer-use-capture-test", version: "1.0.0" });
  await client.connect(transport);
  try {
    const listed = await client.listTools();
    assert.deepEqual(listed.tools.map(tool => tool.name), [
      "recorder_start", "recorder_stop", "recorder_edit", "recorder_get",
      "recorder_cancel", "recorder_discard", "recorder_capabilities"
    ]);
    for (const tool of listed.tools) {
      assert.equal(tool.inputSchema.type, "object");
      assert.ok(tool.outputSchema);
      assert.ok(tool.annotations);
    }
    const result = await client.callTool({ name: "recorder_capabilities", arguments: {} });
    assert.equal(result.isError, undefined);
    assert.equal(result.structuredContent.contractVersion, "1.0.0");
    assert.equal(result.structuredContent.limits.maxConcurrentRecordings, 1);
    assert.deepEqual(result.structuredContent.defaults.waiting, {
      mode: "reduce", retainMs: 100, motionRate: 2
    });
    assert.deepEqual(result.structuredContent.defaults.background, { type: "system-wallpaper" });
    assert.deepEqual(result.structuredContent.defaults.cursor.asset, { type: "system" });
    assert.match(
      result.structuredContent.adapters.codexRollout.detail,
      new RegExp(firstCallerDirectory.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
    );

    const metadataResult = await client.callTool({
      name: "recorder_capabilities",
      arguments: {},
      _meta: {
        "x-codex-turn-metadata": {
          thread_id: "thread-fixture-primary"
        }
      }
    });
    assert.equal(metadataResult.isError, undefined);

    const secondCallerDirectory = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-caller-b-"));
    const secondTransport = new StdioClientTransport({
      command: process.execPath,
      args: [path.resolve("scripts/mcp-server.mjs")],
      env: {
        ...process.env,
        COMPUTER_USE_CAPTURE_STORE: store,
        COMPUTER_USE_CAPTURE_DAEMON_IDLE_MS: "10000"
      },
      cwd: secondCallerDirectory
    });
    const secondClient = new Client({ name: "computer-use-capture-second-task", version: "1.0.0" });
    await secondClient.connect(secondTransport);
    try {
      const shared = await secondClient.callTool({ name: "recorder_capabilities", arguments: {} });
      assert.equal(shared.isError, undefined);
      assert.equal(shared.structuredContent.contractVersion, "1.0.0");
      assert.match(
        shared.structuredContent.adapters.codexRollout.detail,
        new RegExp(secondCallerDirectory.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"))
      );
    } finally {
      await secondClient.close();
    }

    const invalid = await client.callTool({ name: "recorder_get", arguments: { id: "not-an-id" } });
    assert.equal(invalid.isError, true);
    assert.equal(invalid.structuredContent, undefined);
    assert.equal(JSON.parse(invalid.content[0].text).code, "invalid_argument");

    const recordingId = "rec_contractfixture";
    const projectDir = path.join(store, recordingId);
    const base = path.join(projectDir, "source");
    await mkdir(path.join(projectDir, "renders"), { recursive: true });
    const reviewedRenderId = "ren_reviewsourcefixture";
    const reviewedOutput = path.join(projectDir, "renders", `${reviewedRenderId}.mp4`);
    const review = {
      sourceRenderId: reviewedRenderId,
      reason: "The inspected render crops the activated control."
    };
    await writeFile(reviewedOutput, Buffer.from("completed-render-fixture"));
    await writeFile(path.join(projectDir, "manifest.json"), JSON.stringify({
      version: 1,
      kind: "recording",
      recordingId,
      state: "stopped",
      app: "com.apple.Safari",
      label: "Contract fixture",
      createdAt: "2026-07-13T12:00:00.000Z",
      startedAt: "2026-07-13T12:00:00.000Z",
      stoppedAt: "2026-07-13T12:00:01.000Z",
      durationSeconds: 1,
      reconstruction: "settled",
      provenanceSummary: { direct: 1, axIdentity: 0, axFocus: 0, axStructural: 0, unresolved: 0 },
      actionCount: 1,
      warningCount: 0,
      base,
      renders: [{
        kind: "render", renderId: reviewedRenderId, recordingId,
        state: "completed", createdAt: "2026-07-13T12:00:00.000Z",
        finishedAt: "2026-07-13T12:00:01.000Z", output: reviewedOutput
      }],
      effectiveIntents: {
        waiting: { mode: "reduce", retainMs: 100, motionRate: 2 },
        zoom: { strength: 1 },
        background: { type: "system-wallpaper" },
        cursor: {
          scale: 3, path: "natural", tiltStrength: 1, allowInferredTargets: false,
          asset: { type: "system" }
        },
        motionBlur: "standard",
        actions: []
      }
    }));
    await writeFile(`${base}.timeline.json`, JSON.stringify({
      version: 3,
      capture: { startedAt: "2026-07-13T12:00:00.000Z", endedAt: "2026-07-13T12:00:01.000Z" },
      composition: { preset: "product-demo", director: {} },
      events: [{
        actionId: "act_0123456789abcdef",
        action: "click",
        time: 0.5,
        coordinates: { xNorm: 0.5, yNorm: 0.5 },
        targetResolution: { provenance: "direct", confidence: 0.99 },
        editingIntent: { emphasis: "strong", holdMs: 500 }
      }],
      warnings: []
    }));
    await writeFile(`${base}.capture.json`, JSON.stringify({
      version: 1,
      frames: [{ sequence: 0, presentationTime: 0 }]
    }));

    const recordingStatus = await client.callTool({
      name: "recorder_get", arguments: { id: recordingId, include: ["actions", "warnings"] }
    });
    assert.equal(recordingStatus.isError, undefined);
    assert.equal(recordingStatus.structuredContent.kind, "recording");
    assert.ok(recordingStatus.structuredContent.artifacts.frameProvenance.uri);
    assert.ok(recordingStatus.structuredContent.artifacts.frameProvenance.bytes > 0);

    const customWallpaper = path.join(store, "custom-wallpaper.png");
    await writeFile(customWallpaper, Buffer.from("project-owned-asset-fixture"));
    const importedEdit = await client.callTool({
      name: "recorder_edit",
      arguments: {
        recordingId,
        review,
        intents: { background: { type: "image", path: customWallpaper }, motionBlur: "none" }
      }
    });
    assert.equal(importedEdit.isError, undefined);
    const importedPath = importedEdit.structuredContent.effectiveIntents.background.path;
    assert.equal(path.dirname(importedPath), path.join(projectDir, "assets"));
    assert.equal(await readFile(importedPath, "utf8"), "project-owned-asset-fixture");
    await client.callTool({
      name: "recorder_cancel", arguments: { renderId: importedEdit.structuredContent.renderId }
    });

    const stopped = await client.callTool({ name: "recorder_stop", arguments: { recordingId, render: "auto" } });
    assert.equal(stopped.isError, undefined);
    assert.equal(stopped.structuredContent.state, "stopped");
    assert.equal(stopped.structuredContent.actions[0].renderedCursor, true);
    const concurrentEdits = await Promise.all([
      client.callTool({
        name: "recorder_edit",
        arguments: { recordingId, review, intents: { zoom: { strength: 1.2 }, motionBlur: "none" } }
      }),
      client.callTool({
        name: "recorder_edit",
        arguments: { recordingId, review, intents: { zoom: { strength: 1.1 } } }
      })
    ]);
    const [edited] = concurrentEdits.filter(result => result.isError !== true);
    const [rejectedEdit] = concurrentEdits.filter(result => result.isError === true);
    assert.ok(edited);
    assert.equal(JSON.parse(rejectedEdit.content[0].text).code, "render_in_progress");
    assert.equal(edited.isError, undefined);
    assert.equal(edited.structuredContent.state, "queued");
    assert.deepEqual(edited.structuredContent.review, review);
    assert.ok([1.1, 1.2].includes(edited.structuredContent.effectiveIntents.zoom.strength));
    const updatedTimeline = JSON.parse(await readFile(`${base}.timeline.json`, "utf8"));
    assert.equal(updatedTimeline.events[0].editingIntent, undefined);
    const canceled = await client.callTool({
      name: "recorder_cancel", arguments: { renderId: edited.structuredContent.renderId }
    });
    assert.equal(canceled.isError, undefined);
    assert.ok(["canceled", "failed"].includes(canceled.structuredContent.state));

    const discarded = await client.callTool({ name: "recorder_discard", arguments: { recordingId } });
    assert.equal(discarded.isError, undefined);
    assert.equal(discarded.structuredContent.state, "discarded");
    assert.ok(discarded.structuredContent.freedBytes > 0);
    const discardedAgain = await client.callTool({ name: "recorder_discard", arguments: { recordingId } });
    assert.deepEqual(discardedAgain.structuredContent, { recordingId, state: "discarded", freedBytes: 0 });
  } finally {
    await client.close();
  }
});

test("project store has one daemon writer and safely recovers stale locks", async () => {
  const store = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-lock-"));
  const first = new RecorderService({ storeRoot: store });
  const second = new RecorderService({ storeRoot: store });
  await first.initialize();
  try {
    await assert.rejects(second.initialize(), error => {
      assert.equal(error.code, "storage_unavailable");
      return true;
    });
  } finally {
    await first.shutdown();
  }
  await second.initialize();
  await second.shutdown();
});
