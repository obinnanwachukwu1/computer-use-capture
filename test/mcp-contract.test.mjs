import assert from "node:assert/strict";
import test from "node:test";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import Ajv2020 from "ajv/dist/2020.js";
import addFormats from "ajv-formats";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { RecorderService } from "../lib/recorder-service.mjs";

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
      mode: "application"
    },
    introspection: {
      codexSession: "attached",
      formatFingerprint: "d2bcf99da22c6aeb"
    }
  }), true, JSON.stringify(validate.errors));
});

test("MCP server publishes the reviewed seven-tool contract", async () => {
  const store = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-mcp-"));
  const transport = new StdioClientTransport({
    command: process.execPath,
    args: [path.resolve("scripts/mcp-server.mjs")],
    env: { ...process.env, COMPUTER_USE_CAPTURE_STORE: store }
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
      mode: "reduce", retainMs: 100
    });

    const invalid = await client.callTool({ name: "recorder_get", arguments: { id: "not-an-id" } });
    assert.equal(invalid.isError, true);
    assert.equal(invalid.structuredContent, undefined);
    assert.equal(JSON.parse(invalid.content[0].text).code, "invalid_argument");

    const recordingId = "rec_contractfixture";
    const projectDir = path.join(store, recordingId);
    const base = path.join(projectDir, "source");
    await mkdir(path.join(projectDir, "renders"), { recursive: true });
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
      renders: [],
      effectiveIntents: {
        waiting: { mode: "reduce", retainMs: 100 },
        zoom: { strength: 1 },
        cursor: { scale: 3, path: "natural", tiltStrength: 1, allowInferredTargets: false },
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

    const stopped = await client.callTool({ name: "recorder_stop", arguments: { recordingId, render: "auto" } });
    assert.equal(stopped.isError, undefined);
    assert.equal(stopped.structuredContent.state, "stopped");
    assert.equal(stopped.structuredContent.actions[0].renderedCursor, true);
    const concurrentEdits = await Promise.all([
      client.callTool({
        name: "recorder_edit",
        arguments: { recordingId, intents: { zoom: { strength: 1.2 }, motionBlur: "none" } }
      }),
      client.callTool({
        name: "recorder_edit",
        arguments: { recordingId, intents: { zoom: { strength: 1.1 } } }
      })
    ]);
    const [edited] = concurrentEdits.filter(result => result.isError !== true);
    const [rejectedEdit] = concurrentEdits.filter(result => result.isError === true);
    assert.ok(edited);
    assert.equal(JSON.parse(rejectedEdit.content[0].text).code, "render_in_progress");
    assert.equal(edited.isError, undefined);
    assert.equal(edited.structuredContent.state, "queued");
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
