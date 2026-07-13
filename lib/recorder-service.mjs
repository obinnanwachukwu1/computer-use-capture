import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createWriteStream } from "node:fs";
import { access, mkdir, open, readFile, readdir, rename, rm, stat, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import readline from "node:readline";
import { pathToFileURL } from "node:url";
import { findCodexSessions, probeCodexSessionFormat } from "./codex-events.mjs";
import { findScreenshotCoordinateSpace } from "./codex-screenshots.mjs";

export class RecorderError extends Error {
  constructor(code, message, { retryable = false, data } = {}) {
    super(message);
    this.code = code;
    this.retryable = retryable;
    this.data = data;
  }
}

export class RecorderService {
  constructor({
    repoRoot = path.resolve(import.meta.dirname, ".."),
    storeRoot = process.env.AGENTRECORDER_STORE
      ?? path.join(os.homedir(), "Library", "Application Support", "AgentRecorder", "projects"),
    workingDirectory = process.env.AGENTRECORDER_WORKING_DIRECTORY ?? process.cwd()
  } = {}) {
    this.repoRoot = repoRoot;
    this.storeRoot = path.resolve(storeRoot);
    this.workingDirectory = path.resolve(workingDirectory);
    this.recordingProcesses = new Map();
    this.renderProcesses = new Map();
    this.cancelRequests = new Set();
    this.discardingRecordings = new Set();
    this.buildPromise = undefined;
    this.manifestMutations = new Map();
    this.recordingOperations = new Map();
    this.startOperation = Promise.resolve();
    this.storeLockPath = path.join(this.storeRoot, ".server.lock");
    this.ownsStoreLock = false;
  }

  async initialize() {
    await mkdir(this.storeRoot, { recursive: true, mode: 0o700 });
    await this.#acquireStoreLock();
    await this.#recoverInterruptedJobs();
  }

  async start(options = {}) {
    const operation = this.startOperation.catch(() => {}).then(() => this.#startInternal(options));
    this.startOperation = operation;
    return operation;
  }

  async #startInternal({ app = "com.apple.Safari", maxDurationSeconds = 1800, label, idempotencyKey, threadId } = {}) {
    if (app !== "com.apple.Safari") {
      throw new RecorderError("invalid_argument", "Only com.apple.Safari is supported by this build");
    }
    const active = await this.#activeRecording();
    if (active) {
      if (idempotencyKey && active.idempotencyKey === idempotencyKey) return startResult(active);
      throw new RecorderError("active_recording_exists", "A recording is already active", {
        data: { activeRecordingId: active.recordingId }
      });
    }
    await this.#ensureBinaries();
    const preflight = await this.#preflight();
    if (preflight.permissions?.screenRecording !== "granted") {
      throw new RecorderError("permission_missing", "Screen Recording permission is required", {
        data: { permission: "screen_recording" }
      });
    }
    if (preflight.permissions?.accessibility !== "granted") {
      throw new RecorderError("permission_missing", "Accessibility permission is required", {
        data: { permission: "accessibility" }
      });
    }
    const target = preflight.targets?.find(candidate => candidate.app === app);
    if (!target?.available) {
      throw new RecorderError(
        "target_window_not_found",
        target?.windowCount > 1
          ? `Exactly one eligible Safari window is required; found ${target.windowCount}`
          : "No eligible on-screen Safari window is available",
        { data: { windowCount: target?.windowCount ?? 0 } }
      );
    }
    const adapterProbe = (await this.#adapterProbes()).codexRollout;
    const recordingId = makeId("rec");
    const projectDir = this.#projectDir(recordingId);
    const base = path.join(projectDir, "source");
    await mkdir(path.join(projectDir, "renders"), { recursive: true, mode: 0o700 });
    let manifest = {
      version: 1,
      kind: "recording",
      recordingId,
      state: "starting",
      app,
      label,
      idempotencyKey,
      threadId,
      createdAt: new Date().toISOString(),
      maxDurationSeconds,
      base,
      renders: [],
      effectiveIntents: defaultIntents(),
      retention: {
        policy: "until-discarded",
        accessibilitySidecar: "values-redacted",
        privateSessionPaths: "omitted",
        rawAccessibilityTemporary: true
      }
    };
    await this.#writeManifest(manifest);

    const child = spawn(process.execPath, [
      path.join(this.repoRoot, "scripts", "record-session.mjs"), base, String(maxDurationSeconds)
    ], {
      cwd: this.workingDirectory,
      env: {
        ...process.env,
        AGENTRECORDER_PERSIST_PRIVATE_PATHS: "0",
        AGENTRECORDER_PARENT_PID: String(process.pid),
        ...(threadId ? { AGENTRECORDER_THREAD_ID: threadId } : {})
      },
      stdio: ["pipe", "pipe", "pipe"],
      detached: true
    });
    const tracked = trackChild(child, path.join(projectDir, "capture.log"));
    this.recordingProcesses.set(recordingId, tracked);
    tracked.finished.then(
      () => this.#withRecordingOperation(recordingId, () => this.#captureExited(recordingId)),
      () => this.#withRecordingOperation(recordingId, () => this.#captureExited(recordingId))
    ).catch(() => {});

    const readyLine = await waitForLine(tracked, line => line.startsWith("RECORDING_READY"), 45_000)
      .catch(async error => {
        terminateProcessGroup(child, "SIGTERM");
        manifest = { ...manifest, state: "failed", error: serializeError(error) };
        await this.#writeManifest(manifest);
        throw new RecorderError("storage_unavailable", `Recorder failed to start: ${error.message}`, { retryable: true });
      });
    const startedAt = readyLine.match(/startedAt=([^\s]+)/)?.[1] ?? new Date().toISOString();
    const captureLine = tracked.lines.find(line => line.startsWith("CAPTURE_READY"));
    const size = captureLine?.match(/size=(\d+)x(\d+)/);
    const scale = captureLine?.match(/scale=([\d.]+)/);
    const codec = captureLine?.match(/codec=([^\s]+)/)?.[1];
    manifest = {
      ...manifest,
      state: "recording",
      startedAt,
      capture: size ? {
        width: Number(size[1]), height: Number(size[2]),
        ...(scale ? { pixelsPerPoint: Number(scale[1]) } : {}),
        ...(codec ? { codec } : {})
      } : undefined,
      introspection: {
        codexSession: threadId || adapterProbe?.status === "ok" ? "attached" : "degraded",
        ...(adapterProbe?.formatFingerprint ? { formatFingerprint: adapterProbe.formatFingerprint } : {})
      }
    };
    await this.#writeManifest(manifest);
    return startResult(manifest);
  }

  async stop({ recordingId, render = "auto" }) {
    return this.#withRecordingOperation(recordingId, () => this.#stopInternal({ recordingId, render }));
  }

  async #stopInternal({ recordingId, render }) {
    let manifest = await this.#requireRecording(recordingId);
    if (manifest.state === "stopped") {
      const originalRender = manifest.renders.find(candidate => candidate.renderId === manifest.stopRenderId);
      return this.#stopResult(manifest, originalRender);
    }
    if (manifest.state !== "recording") {
      throw new RecorderError("invalid_state", `Recording is ${manifest.state}, not recording`);
    }
    manifest = { ...manifest, state: "stopping" };
    await this.#writeManifest(manifest);
    const tracked = this.recordingProcesses.get(recordingId);
    if (!tracked) throw new RecorderError("invalid_state", "Capture process is no longer attached", { retryable: true });
    tracked.child.stdin.end("\n");
    const exit = await withTimeout(tracked.finished, 60_000, "Capture finalization timed out").catch(async error => {
      await terminateTracked(tracked);
      manifest = {
        ...manifest,
        state: "failed",
        error: { code: "reconstruction_failed", message: error.message }
      };
      await this.#writeManifest(manifest);
      throw new RecorderError("reconstruction_failed", error.message, { retryable: true });
    });
    this.recordingProcesses.delete(recordingId);
    if (exit.code !== 0) {
      manifest = { ...manifest, state: "failed", error: { code: "reconstruction_failed", message: exit.stderr.slice(-2000) } };
      await this.#writeManifest(manifest);
      throw new RecorderError("reconstruction_failed", "Capture finalization failed", { data: manifest.error });
    }
    const timeline = await this.#readTimeline(manifest);
    manifest = {
      ...manifest,
      state: "stopped",
      stoppedAt: timeline.capture?.endedAt ?? new Date().toISOString(),
      durationSeconds: durationSeconds(timeline.capture?.startedAt, timeline.capture?.endedAt),
      provenanceSummary: provenanceSummary(timeline.events ?? []),
      actionCount: timeline.events?.length ?? 0,
      warningCount: timeline.warnings?.length ?? 0,
      reconstruction: normalizeReconstruction(timeline.introspection?.reconstruction?.status)
    };
    await this.#writeManifest(manifest);
    const renderJob = render === "auto" ? await this.#startRender(manifest, manifest.effectiveIntents) : undefined;
    manifest = await this.#requireRecording(recordingId);
    if (renderJob) {
      manifest = await this.#mutateManifest(recordingId, current => ({
        ...current,
        stopRenderId: renderJob.renderId
      }));
    }
    return this.#stopResult(manifest, renderJob);
  }

  async edit({ recordingId, intents = {} }) {
    return this.#withRecordingOperation(recordingId, () => this.#editInternal({ recordingId, intents }));
  }

  async #editInternal({ recordingId, intents }) {
    let manifest = await this.#requireRecording(recordingId);
    if (manifest.state !== "stopped") throw new RecorderError("invalid_state", `Recording is ${manifest.state}, not stopped`);
    const running = manifest.renders.find(render => ["queued", "analyzing", "rendering"].includes(render.state));
    if (running) {
      throw new RecorderError("render_in_progress", "A render is already running", { data: { runningRenderId: running.renderId } });
    }
    const effectiveIntents = mergeIntents(manifest.effectiveIntents, intents);
    const notes = await this.#applyTimelineIntents(manifest, effectiveIntents);
    manifest = { ...manifest, effectiveIntents };
    await this.#writeManifest(manifest);
    const renderJob = await this.#startRender(manifest, effectiveIntents);
    return { recordingId, renderId: renderJob.renderId, state: "queued", effectiveIntents, notes };
  }

  async get({ id, include = [] }) {
    if (id.startsWith("rec_")) {
      const manifest = await this.#requireRecording(id);
      const result = await this.#recordingResult(manifest);
      if (!include.includes("actions")) delete result.actions;
      if (!include.includes("warnings")) delete result.warnings;
      return result;
    }
    if (id.startsWith("ren_")) return renderResult(await this.#requireRender(id));
    throw new RecorderError("invalid_argument", "id must begin with rec_ or ren_");
  }

  async cancel({ renderId }) {
    const render = await this.#requireRender(renderId);
    return this.#withRecordingOperation(render.recordingId, () => this.#cancelInternal(renderId));
  }

  async #cancelInternal(renderId) {
    const render = await this.#requireRender(renderId);
    if (["completed", "failed", "canceled"].includes(render.state)) return { renderId, state: render.state };
    const tracked = this.renderProcesses.get(renderId);
    this.cancelRequests.add(renderId);
    let exit;
    if (tracked) {
      exit = await terminateTracked(tracked, 15_000);
    }
    if (exit?.code === 0 && await exists(render.output)) {
      this.cancelRequests.delete(renderId);
      await this.#renderExited(render.recordingId, renderId, exit);
      const completed = await this.#requireRender(renderId);
      return { renderId, state: completed.state };
    }
    await cleanupPartialOutputs(render.output);
    await this.#updateRender(render.recordingId, renderId, { state: "canceled", finishedAt: new Date().toISOString() });
    this.cancelRequests.delete(renderId);
    return { renderId, state: "canceled" };
  }

  async discard({ recordingId }) {
    if (!/^rec_[0-9A-Za-z]{10,}$/.test(recordingId ?? "")) {
      throw new RecorderError("invalid_argument", "Invalid recordingId");
    }
    return this.#withRecordingOperation(recordingId, () => this.#discardInternal(recordingId));
  }

  async #discardInternal(recordingId) {
    const manifest = await this.#requireRecording(recordingId).catch(error => {
      if (error instanceof RecorderError && error.code === "not_found") return undefined;
      throw error;
    });
    if (!manifest) return { recordingId, state: "discarded", freedBytes: 0 };
    this.discardingRecordings.add(recordingId);
    try {
      const capture = this.recordingProcesses.get(recordingId);
      if (capture) await terminateTracked(capture);
      for (const render of manifest.renders) {
        const tracked = this.renderProcesses.get(render.renderId);
        if (tracked) {
          this.cancelRequests.add(render.renderId);
          await terminateTracked(tracked);
          this.renderProcesses.delete(render.renderId);
          this.cancelRequests.delete(render.renderId);
        }
      }
      this.recordingProcesses.delete(recordingId);
      const bytes = await directorySize(this.#projectDir(recordingId));
      await rm(this.#projectDir(recordingId), { recursive: true, force: true });
      return { recordingId, state: "discarded", freedBytes: bytes };
    } finally {
      this.discardingRecordings.delete(recordingId);
    }
  }

  async capabilities() {
    await this.#ensureBinaries();
    const active = await this.#activeRecording();
    const preflight = await this.#preflight();
    const adapterProbes = await this.#adapterProbes();
    return {
      contractVersion: "1.0.0",
      platform: preflight.platform ?? "macOS",
      permissions: preflight.permissions ?? { screenRecording: "unknown", accessibility: "unknown" },
      targets: preflight.targets ?? [{ app: "com.apple.Safari", available: false }],
      adapters: adapterProbes,
      presets: [{ name: "product-demo", default: true }],
      limits: { maxDurationSeconds: 7200, maxConcurrentRecordings: 1, maxConcurrentRendersPerRecording: 1 },
      defaults: defaultIntents(),
      activeRecordingId: active?.recordingId ?? null
    };
  }

  async shutdown() {
    const trackedChildren = [...this.recordingProcesses.values(), ...this.renderProcesses.values()];
    await Promise.allSettled(trackedChildren.map(tracked => terminateTracked(tracked, 5000)));
    if (this.ownsStoreLock) {
      await unlink(this.storeLockPath).catch(() => {});
      this.ownsStoreLock = false;
    }
  }

  async #startRender(manifest, intents) {
    const renderId = makeId("ren");
    const output = path.join(this.#projectDir(manifest.recordingId), "renders", `${renderId}.mp4`);
    const render = {
      kind: "render", renderId, recordingId: manifest.recordingId, state: "queued",
      createdAt: new Date().toISOString(), effectiveIntents: intents, output
    };
    manifest = { ...manifest, renders: [...manifest.renders, render] };
    await this.#writeManifest(manifest);
    const args = [path.join(this.repoRoot, "scripts", "compose-recording.mjs"), manifest.base, "--output", output];
    if (intents.waiting?.mode === "keep") args.push("--keep-waiting");
    if (Number.isFinite(intents.waiting?.retainMs)) args.push("--waiting-time", String(intents.waiting.retainMs));
    if (intents.cursor?.path) args.push("--cursor-path", intents.cursor.path);
    if (Number.isFinite(intents.cursor?.tiltStrength)) args.push("--cursor-tilt-strength", String(intents.cursor.tiltStrength));
    const env = {
      ...process.env,
      AGENTRECORDER_PARENT_PID: String(process.pid),
      ...motionBlurEnvironment(intents.motionBlur)
    };
    const child = spawn(process.execPath, args, {
      cwd: this.repoRoot, env, stdio: ["ignore", "pipe", "pipe"], detached: true
    });
    const tracked = trackChild(child, path.join(this.#projectDir(manifest.recordingId), "renders", `${renderId}.log`), line => {
      let payload;
      if (line.startsWith("AGENTRECORDER_PROGRESS ")) {
        try { payload = JSON.parse(line.slice("AGENTRECORDER_PROGRESS ".length)); } catch { /* malformed progress is non-fatal */ }
      }
      if (payload) this.#updateRender(manifest.recordingId, renderId, {
        state: payload.phase === "completed" ? "rendering" : payload.phase,
        progress: payload
      }).catch(() => {});
    });
    this.renderProcesses.set(renderId, tracked);
    await this.#updateRender(manifest.recordingId, renderId, { state: "analyzing", startedAt: new Date().toISOString() });
    tracked.finished.then(
      exit => this.#withRecordingOperation(manifest.recordingId, () => this.#renderExited(manifest.recordingId, renderId, exit)),
      error => this.#withRecordingOperation(manifest.recordingId, () =>
        this.#renderExited(manifest.recordingId, renderId, { code: 1, stderr: error.message })
      )
    ).catch(() => {});
    return render;
  }

  async #renderExited(recordingId, renderId, exit) {
    this.renderProcesses.delete(renderId);
    if (this.cancelRequests.has(renderId) || this.discardingRecordings.has(recordingId)) return;
    const current = await this.#requireRender(renderId).catch(() => undefined);
    if (!current || current.state === "canceled") return;
    if (exit.code !== 0) {
      await this.#updateRender(recordingId, renderId, {
        state: "failed", finishedAt: new Date().toISOString(),
        error: { code: "render_failed", message: exit.stderr.slice(-2000) }
      });
      return;
    }
    const metadata = await stat(current.output).catch(() => undefined);
    const reportPath = current.output.replace(/\.mp4$/, ".composition.json");
    const report = await readJson(reportPath).catch(() => undefined);
    if (!metadata?.isFile() || report?.state !== "completed") {
      await cleanupPartialOutputs(current.output);
      await this.#updateRender(recordingId, renderId, {
        state: "failed", finishedAt: new Date().toISOString(),
        error: { code: "render_failed", message: "Renderer exited without an atomically completed movie and composition report" }
      });
      return;
    }
    await this.#updateRender(recordingId, renderId, {
      state: "completed", finishedAt: new Date().toISOString(), progress: { phase: "completed", percent: 100 },
      artifact: metadata ? { uri: pathToFileURL(current.output).href, bytes: metadata.size, durationSeconds: report?.durationSeconds } : undefined,
      pointerRendering: report?.pointerRendering,
      pointerActions: report?.actions
    });
  }

  async #captureExited(recordingId) {
    if (this.discardingRecordings.has(recordingId)) return;
    const tracked = this.recordingProcesses.get(recordingId);
    if (!tracked) return;
    const manifest = await this.#requireRecording(recordingId).catch(() => undefined);
    if (!manifest || manifest.state === "stopping") return;
    const exit = await tracked.finished.catch(error => ({ code: 1, stderr: error.message }));
    this.recordingProcesses.delete(recordingId);
    if (this.discardingRecordings.has(recordingId)) return;
    if (manifest.state === "recording" && exit.code === 0) {
      const timeline = await this.#readTimeline(manifest).catch(() => undefined);
      if (timeline) {
        await this.#writeManifest({
          ...manifest,
          state: "stopped",
          stoppedAt: timeline.capture?.endedAt ?? new Date().toISOString(),
          durationSeconds: durationSeconds(timeline.capture?.startedAt, timeline.capture?.endedAt),
          provenanceSummary: provenanceSummary(timeline.events ?? []),
          actionCount: timeline.events?.length ?? 0,
          warningCount: timeline.warnings?.length ?? 0,
      reconstruction: normalizeReconstruction(timeline.introspection?.reconstruction?.status)
        });
      }
    } else if (manifest.state === "recording") {
      await this.#writeManifest({ ...manifest, state: "failed", error: { code: "reconstruction_failed", message: exit.stderr.slice(-2000) } });
    }
  }

  async #applyTimelineIntents(manifest, intents) {
    const timeline = await this.#readTimeline(manifest);
    timeline.composition ??= { preset: "product-demo", director: {} };
    timeline.composition.cursorScale = intents.cursor?.scale ?? timeline.composition.cursorScale ?? 3;
    timeline.composition.director ??= {};
    timeline.composition.director.zoomStrength = intents.zoom?.strength ?? 1;
    timeline.composition.director.cursorPath = intents.cursor?.path ?? "natural";
    timeline.composition.director.cursorTiltStrength = intents.cursor?.tiltStrength ?? 1;
    timeline.composition.director.allowInferredTargets = intents.cursor?.allowInferredTargets === true;
    const knownActionIds = new Set((timeline.events ?? []).map(event => event.actionId));
    const actionIntents = new Map((intents.actions ?? []).map(intent => [intent.actionId, intent]));
    timeline.events = (timeline.events ?? []).map(event => {
      const { editingIntent: _previousIntent, ...baseEvent } = event;
      const editingIntent = actionIntents.get(event.actionId);
      return editingIntent ? { ...baseEvent, editingIntent } : baseEvent;
    });
    await writeJsonAtomic(`${manifest.base}.timeline.json`, timeline);
    return [...actionIntents.keys()]
      .filter(actionId => !knownActionIds.has(actionId))
      .map(actionId => `Action ${actionId} was not found; its override was ignored`);
  }

  async #recordingResult(manifest) {
    const timeline = ["stopped", "failed"].includes(manifest.state)
      ? await this.#readTimeline(manifest).catch(() => undefined) : undefined;
    return {
      kind: "recording", recordingId: manifest.recordingId, state: manifest.state,
      label: manifest.label, startedAt: manifest.startedAt, stoppedAt: manifest.stoppedAt,
      durationSeconds: manifest.durationSeconds, provenanceSummary: manifest.provenanceSummary,
      actions: timeline?.events?.map(event => ({
        actionId: event.actionId, kind: event.action, atMs: Math.round(event.time * 1000),
        provenance: event.targetResolution?.provenance ?? "unresolved",
        confidence: event.targetResolution?.confidence ?? 0,
        unresolvedReason: event.targetResolution?.reason,
        target: event.semanticTarget ? { role: event.semanticTarget.role, title: event.semanticTarget.title } : undefined,
        renderedCursor: cursorDecisionForEvent(
          event,
          manifest.effectiveIntents?.cursor?.allowInferredTargets === true
        )
      })),
      warnings: normalizeWarnings(timeline?.warnings),
      renders: manifest.renders.toReversed().map(({ renderId, state, createdAt }) => ({ renderId, state, createdAt })),
      artifacts: timeline ? {
        sourceVideo: await artifact(`${manifest.base}.mov`),
        timeline: await artifact(`${manifest.base}.timeline.json`)
      } : undefined,
      error: manifest.error
    };
  }

  async #stopResult(manifest, render) {
    const recording = await this.#recordingResult(manifest);
    return {
      recordingId: manifest.recordingId,
      state: manifest.state,
      stoppedAt: manifest.stoppedAt,
      durationSeconds: manifest.durationSeconds,
      reconstruction: manifest.reconstruction,
      provenanceSummary: manifest.provenanceSummary,
      actions: recording.actions,
      warnings: recording.warnings ?? [],
      ...(render ? { render: { renderId: render.renderId, state: "queued" } } : {})
    };
  }

  async #preflight() {
    const binary = path.join(this.repoRoot, ".build", "release", "recorder-preflight");
    if (!await exists(binary)) return {};
    const result = await runToCompletion(binary, [], { cwd: this.repoRoot, timeoutMs: 5000 }).catch(() => undefined);
    return result?.code === 0 ? JSON.parse(result.stdout) : {};
  }

  async #adapterProbes() {
    const sessions = await findCodexSessions({ cwd: this.workingDirectory }).catch(() => []);
    const screenshot = await findScreenshotCoordinateSpace({
      appName: "Safari", referenceTime: Date.now()
    }).catch(() => undefined);
    const rolloutProbe = sessions.length
      ? await probeCodexSessionFormat(sessions[0].file).catch(() => undefined)
      : undefined;
    return {
      codexRollout: rolloutProbe ? {
        status: sessions.length === 1 && rolloutProbe.status === "ok" ? "ok" : "degraded",
        ...(rolloutProbe.formatFingerprint ? { formatFingerprint: rolloutProbe.formatFingerprint } : {}),
        detail: [
          rolloutProbe.detail,
          ...(sessions.length > 1 ? [`${sessions.length} matching tasks; bind threadId at start`] : [])
        ].filter(Boolean).join("; ")
      } : {
        status: "unavailable",
        detail: `No Codex task found for ${this.workingDirectory}`
      },
      screenshotCache: screenshot ? {
        status: screenshot.confidence === "stale" ? "degraded" : "ok",
        detail: screenshot.confidence === "stale"
          ? "Only stale screenshot evidence is currently available; direct coordinates will fail closed"
          : `Current Safari screenshot evidence is readable (${screenshot.width}x${screenshot.height}); capture compatibility is validated per action`
      } : {
        status: "unavailable",
        detail: "No Computer Use screenshot evidence is currently available"
      }
    };
  }

  async #ensureBinaries() {
    if (!this.buildPromise) {
      this.buildPromise = runToCompletion("swift", ["build", "-c", "release"], {
        cwd: this.repoRoot, timeoutMs: 180_000
      }).then(result => {
        if (result.code !== 0) throw new RecorderError("storage_unavailable", `Swift build failed: ${result.stderr.slice(-2000)}`);
      }).catch(error => {
        this.buildPromise = undefined;
        throw error;
      });
    }
    return this.buildPromise;
  }

  async #activeRecording() {
    const manifests = await this.#allManifests();
    return manifests.find(manifest => ["starting", "recording", "stopping"].includes(manifest.state));
  }

  async #requireRecording(recordingId) {
    if (!/^rec_[0-9A-Za-z]{10,}$/.test(recordingId ?? "")) throw new RecorderError("invalid_argument", "Invalid recordingId");
    const projectDir = this.#projectDir(recordingId);
    const manifest = await readJson(path.join(projectDir, "manifest.json")).catch(() => {
      throw new RecorderError("not_found", `Recording ${recordingId} was not found`);
    });
    if (manifest.recordingId !== recordingId || path.resolve(manifest.base ?? "") !== path.join(projectDir, "source")) {
      throw new RecorderError("storage_unavailable", `Recording ${recordingId} has an invalid manifest`);
    }
    return manifest;
  }

  async #requireRender(renderId) {
    for (const manifest of await this.#allManifests()) {
      const render = manifest.renders.find(candidate => candidate.renderId === renderId);
      if (render) return render;
    }
    throw new RecorderError("not_found", `Render ${renderId} was not found`);
  }

  async #updateRender(recordingId, renderId, patch) {
    return this.#mutateManifest(recordingId, manifest => ({
      ...manifest,
      renders: manifest.renders.map(render => render.renderId === renderId ? { ...render, ...patch } : render)
    }));
  }

  async #mutateManifest(recordingId, transform) {
    const previous = this.manifestMutations.get(recordingId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(async () => {
      const manifest = await this.#requireRecording(recordingId);
      const updated = await transform(manifest);
      await this.#writeManifest(updated);
      return updated;
    });
    this.manifestMutations.set(recordingId, next);
    return next.finally(() => {
      if (this.manifestMutations.get(recordingId) === next) this.manifestMutations.delete(recordingId);
    });
  }

  async #allManifests() {
    const entries = await readdir(this.storeRoot, { withFileTypes: true }).catch(() => []);
    return (await Promise.all(entries.filter(entry => entry.isDirectory() && entry.name.startsWith("rec_"))
      .map(entry => readJson(path.join(this.storeRoot, entry.name, "manifest.json")).catch(() => undefined))))
      .filter(Boolean);
  }

  async #recoverInterruptedJobs() {
    for (const manifest of await this.#allManifests()) {
      await rm(`${manifest.base}.accessibility.private.tmp`, { force: true }).catch(() => {});
      let changed = false;
      if (["starting", "recording", "stopping"].includes(manifest.state)) {
        manifest.state = "failed";
        manifest.error = { code: "reconstruction_failed", message: "Recorder server restarted during capture" };
        changed = true;
      }
      manifest.renders = manifest.renders.map(render => {
        if (!["queued", "analyzing", "rendering"].includes(render.state)) return render;
        changed = true;
        return { ...render, state: "failed", error: { code: "render_failed", message: "Recorder server restarted during render" } };
      });
      if (changed) await this.#writeManifest(manifest);
    }
  }

  async #withRecordingOperation(recordingId, operation) {
    const previous = this.recordingOperations.get(recordingId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(operation);
    this.recordingOperations.set(recordingId, next);
    return next.finally(() => {
      if (this.recordingOperations.get(recordingId) === next) this.recordingOperations.delete(recordingId);
    });
  }

  async #acquireStoreLock() {
    const attempt = async () => {
      const handle = await open(this.storeLockPath, "wx", 0o600);
      await handle.writeFile(`${JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })}\n`);
      await handle.close();
      this.ownsStoreLock = true;
    };
    try {
      await attempt();
      return;
    } catch (error) {
      if (error?.code !== "EEXIST") throw error;
    }
    const lock = await readJson(this.storeLockPath).catch(() => undefined);
    if (Number.isInteger(lock?.pid) && processIsAlive(lock.pid)) {
      throw new RecorderError("storage_unavailable", `Recorder store is already owned by process ${lock.pid}`, {
        retryable: true
      });
    }
    await unlink(this.storeLockPath).catch(() => {});
    await attempt().catch(error => {
      throw new RecorderError("storage_unavailable", `Could not acquire recorder store: ${error.message}`, {
        retryable: true
      });
    });
  }

  #projectDir(recordingId) {
    const resolved = path.join(this.storeRoot, recordingId);
    if (path.dirname(resolved) !== this.storeRoot) throw new RecorderError("invalid_argument", "Unsafe recording ID");
    return resolved;
  }

  async #writeManifest(manifest) {
    await writeJsonAtomic(path.join(this.#projectDir(manifest.recordingId), "manifest.json"), manifest);
  }

  #readTimeline(manifest) { return readJson(`${manifest.base}.timeline.json`); }
}

function defaultIntents() {
  return {
    waiting: { mode: "reduce", retainMs: 100 },
    zoom: { strength: 1 },
    cursor: { scale: 3, path: "natural", tiltStrength: 1, allowInferredTargets: false },
    motionBlur: "standard",
    actions: []
  };
}

function mergeIntents(current, patch) {
  return {
    ...current, ...patch,
    waiting: { ...current.waiting, ...patch.waiting },
    zoom: { ...current.zoom, ...patch.zoom },
    cursor: { ...current.cursor, ...patch.cursor },
    actions: patch.actions ?? current.actions
  };
}

function startResult(manifest) {
  return {
    recordingId: manifest.recordingId, state: manifest.state, startedAt: manifest.startedAt,
    ...(manifest.capture ? { capture: manifest.capture } : {}),
    ...(manifest.introspection ? { introspection: manifest.introspection } : {})
  };
}

function renderResult(render) {
  return {
    kind: "render",
    renderId: render.renderId,
    recordingId: render.recordingId,
    state: render.state,
    ...(render.progress ? { progress: render.progress } : {}),
    ...(render.startedAt ? { startedAt: render.startedAt } : {}),
    ...(render.finishedAt ? { finishedAt: render.finishedAt } : {}),
    ...(render.artifact ? { artifact: render.artifact } : {}),
    ...(render.pointerRendering ? { pointerRendering: render.pointerRendering } : {}),
    ...(render.pointerActions ? { actions: render.pointerActions } : {}),
    ...(render.error ? { error: render.error } : {})
  };
}

function cursorDecisionForEvent(event, allowInferredTargets) {
  if (!["click", "drag"].includes(event.action)) return false;
  const provenance = event.targetResolution?.provenance ?? event.coordinateResolution?.provenance;
  const confidence = event.targetResolution?.confidence ?? event.coordinateResolution?.confidence ?? 0;
  if (["direct", "ax-identity", "ax-focus"].includes(provenance)) return true;
  if (provenance === "ax-structural") return confidence >= 0.75;
  return allowInferredTargets && provenance === "visual-inferred";
}

function makeId(prefix) {
  return `${prefix}_${Date.now().toString(36)}${randomBytes(8).toString("hex")}`;
}

function provenanceSummary(events) {
  const summary = { direct: 0, axIdentity: 0, axFocus: 0, axStructural: 0, unresolved: 0 };
  for (const event of events) {
    const key = ({ "ax-identity": "axIdentity", "ax-focus": "axFocus", "ax-structural": "axStructural" })[
      event.targetResolution?.provenance
    ] ?? (event.targetResolution?.provenance === "direct" ? "direct" : "unresolved");
    summary[key] += 1;
  }
  return summary;
}

function motionBlurEnvironment(value) {
  if (value === "none") return { AGENTRECORDER_MOTION_SAMPLES: "1", AGENTRECORDER_SHUTTER: "0" };
  if (value === "strong") return { AGENTRECORDER_MOTION_SAMPLES: "10", AGENTRECORDER_SHUTTER: "0.75" };
  return { AGENTRECORDER_MOTION_SAMPLES: "8", AGENTRECORDER_SHUTTER: "0.55" };
}

function trackChild(child, logPath, onLine) {
  const stdout = [];
  const stderr = [];
  const listeners = new Set();
  const logStream = createWriteStream(logPath, { flags: "a", mode: 0o600 });
  let logError;
  logStream.on("error", error => { logError = error; });
  const lines = readline.createInterface({ input: child.stdout, crlfDelay: Infinity });
  lines.on("line", line => {
    stdout.push(line);
    if (stdout.length > 10_000) stdout.splice(0, stdout.length - 10_000);
    if (!logError) logStream.write(`${line}\n`);
    onLine?.(line);
    for (const listener of listeners) listener(line);
  });
  child.stderr.on("data", chunk => {
    stderr.push(String(chunk));
    if (!logError) logStream.write(String(chunk));
  });
  const finished = new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", (code, signal) => {
      logStream.end();
      if (logError) stderr.push(`\nRecorder log write failed: ${logError.message}`);
      resolve({ code: code ?? (signal ? 1 : 0), signal, stdout: stdout.join("\n"), stderr: stderr.join("") });
    });
  });
  return { child, finished, listeners, lines: stdout };
}

function waitForLine(tracked, predicate, timeoutMs) {
  return new Promise((resolve, reject) => {
    const existing = tracked.lines.find(predicate);
    if (existing) { resolve(existing); return; }
    const timeout = setTimeout(() => { cleanup(); reject(new Error("Timed out waiting for recorder readiness")); }, timeoutMs);
    const listener = line => { if (predicate(line)) { cleanup(); resolve(line); } };
    const cleanup = () => { clearTimeout(timeout); tracked.listeners.delete(listener); };
    tracked.listeners.add(listener);
    tracked.finished.then(exit => { cleanup(); reject(new Error(`Recorder exited before readiness (${exit.code})`)); }).catch(error => { cleanup(); reject(error); });
  });
}

function terminateProcessGroup(child, signal) {
  if (child.exitCode !== null) return;
  try { process.kill(-child.pid, signal); } catch { child.kill(signal); }
}

async function terminateTracked(tracked, graceMs = 5000) {
  if (tracked.child.exitCode === null) terminateProcessGroup(tracked.child, "SIGTERM");
  const graceful = await withTimeout(tracked.finished, graceMs, "Child did not stop after SIGTERM")
    .catch(() => undefined);
  if (graceful) return graceful;
  if (tracked.child.exitCode === null) terminateProcessGroup(tracked.child, "SIGKILL");
  return withTimeout(tracked.finished, 3000, "Child did not stop after SIGKILL").catch(() => undefined);
}

function runToCompletion(command, args, { cwd, timeoutMs }) {
  const child = spawn(command, args, { cwd, stdio: ["ignore", "pipe", "pipe"] });
  const stdout = []; const stderr = [];
  child.stdout.on("data", chunk => stdout.push(String(chunk)));
  child.stderr.on("data", chunk => stderr.push(String(chunk)));
  return withTimeout(new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("exit", code => resolve({ code: code ?? 1, stdout: stdout.join(""), stderr: stderr.join("") }));
  }), timeoutMs, `${command} timed out`).catch(error => { child.kill("SIGKILL"); throw error; });
}

async function writeJsonAtomic(file, value) {
  await mkdir(path.dirname(file), { recursive: true, mode: 0o700 });
  const temporary = `${file}.tmp-${process.pid}-${randomBytes(4).toString("hex")}`;
  await writeFile(temporary, `${JSON.stringify(value, null, 2)}\n`, { mode: 0o600 });
  await rename(temporary, file);
}

async function readJson(file) { return JSON.parse(await readFile(file, "utf8")); }
async function exists(file) { return access(file).then(() => true).catch(() => false); }
async function artifact(file) {
  const metadata = await stat(file).catch(() => undefined);
  return metadata ? { uri: pathToFileURL(file).href, bytes: metadata.size } : undefined;
}
function durationSeconds(start, end) { return start && end ? Math.max(0, (Date.parse(end) - Date.parse(start)) / 1000) : undefined; }
function serializeError(error) { return { code: error.code ?? "storage_unavailable", message: error.message }; }
function normalizeReconstruction(value) {
  return ["settled", "truncated", "ambiguous"].includes(value) ? value : "truncated";
}
function normalizeWarnings(warnings = []) {
  return warnings.map(warning => ({
    type: String(warning.type ?? "warning"),
    message: String(warning.message ?? warning.reason ?? "Recorder warning"),
    ...(Number.isFinite(warning.atMs) ? { atMs: Math.round(warning.atMs) }
      : Number.isFinite(warning.time) ? { atMs: Math.round(warning.time * 1000) } : {})
  }));
}
function processIsAlive(pid) {
  try { process.kill(pid, 0); return true; } catch { return false; }
}
function withTimeout(promise, ms, message) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(message)), ms);
    Promise.resolve(promise).then(
      value => { clearTimeout(timeout); resolve(value); },
      error => { clearTimeout(timeout); reject(error); }
    );
  });
}
async function directorySize(root) {
  let total = 0; const stack = [root];
  while (stack.length) {
    const current = stack.pop();
    for (const entry of await readdir(current, { withFileTypes: true }).catch(() => [])) {
      const full = path.join(current, entry.name);
      if (entry.isDirectory()) stack.push(full);
      else if (entry.isFile()) total += (await stat(full)).size;
    }
  }
  return total;
}
async function cleanupPartialOutputs(output) {
  const directory = path.dirname(output);
  const prefix = `.${path.basename(output)}.partial-`;
  for (const entry of await readdir(directory).catch(() => [])) {
    if (entry.startsWith(prefix)) await rm(path.join(directory, entry), { force: true }).catch(() => {});
  }
}
