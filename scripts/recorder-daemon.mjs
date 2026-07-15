#!/usr/bin/env node
import { chmod, mkdir, readFile, unlink, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import path from "node:path";
import { RecorderError, RecorderService } from "../lib/recorder-service.mjs";
import { defaultStoreRoot, RECORDER_DAEMON_PROTOCOL_VERSION } from "../lib/recorder-daemon-client.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");
const runtimeVersion = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8")).version;
const storeRoot = path.resolve(defaultStoreRoot());
const socketPath = path.join(storeRoot, ".daemon.sock");
const pidPath = path.join(storeRoot, ".daemon.pid");
await mkdir(storeRoot, { recursive: true, mode: 0o700 });

const service = new RecorderService({ repoRoot, storeRoot });
await service.initialize();
// Only the process that owns the recorder store may replace a stale socket.
// This ordering prevents two simultaneously launched MCP clients from
// unlinking the winning daemon's live socket.
await unlink(socketPath).catch(() => {});
const methods = new Set([
  "start", "stop", "edit", "get", "cancel", "discard", "capabilities", "activeRecordingId"
]);
await writeFile(pidPath, `${process.pid}\n`, { mode: 0o600 });
const idleMs = Math.max(1000, Number(process.env.COMPUTER_USE_CAPTURE_DAEMON_IDLE_MS ?? 15 * 60_000));
let idleTimer;
let activeRequests = 0;
function touch() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(async () => {
    if (activeRequests > 0 || await service.hasActiveJobs()) { touch(); return; }
    await shutdown();
  }, idleMs);
  idleTimer.unref();
}
touch();

const server = createServer(socket => {
  touch();
  socket.setEncoding("utf8");
  let buffer = "";
  let handling = false;
  socket.on("data", chunk => {
    buffer += chunk;
    if (!handling && buffer.includes("\n")) handleRequest();
  });
  async function handleRequest() {
    handling = true;
    activeRequests += 1;
    let request;
    try {
      request = JSON.parse(buffer);
      if (request.method === "ping") {
        socket.end(`${JSON.stringify({
          id: request.id,
          result: { ok: true, protocolVersion: RECORDER_DAEMON_PROTOCOL_VERSION, runtimeVersion }
        })}\n`);
        return;
      }
      if (request.method === "shutdownIfIdle") {
        const busy = activeRequests > 1 || await service.hasActiveJobs();
        socket.end(`${JSON.stringify({ id: request.id, result: { stopped: !busy } })}\n`);
        if (!busy) setTimeout(shutdown, 0);
        return;
      }
      if (!methods.has(request.method)) throw new RecorderError("invalid_argument", "Unknown daemon method");
      const result = await service[request.method](request.args ?? {}, request.context ?? {});
      socket.end(`${JSON.stringify({ id: request.id, result })}\n`);
    } catch (error) {
      const normalized = error instanceof RecorderError ? error
        : new RecorderError("storage_unavailable", error instanceof Error ? error.message : String(error));
      socket.end(`${JSON.stringify({
        id: request?.id,
        error: {
          code: normalized.code,
          message: normalized.message,
          retryable: normalized.retryable,
          ...(normalized.data ? { data: normalized.data } : {})
        }
      })}\n`);
    } finally {
      activeRequests -= 1;
      touch();
    }
  }
});

await new Promise((resolve, reject) => {
  server.once("error", reject);
  server.listen(socketPath, resolve);
});
await chmod(socketPath, 0o600);

let stopping = false;
async function shutdown() {
  if (stopping) return;
  stopping = true;
  await new Promise(resolve => server.close(resolve));
  await service.shutdown();
  await unlink(socketPath).catch(() => {});
  await unlink(pidPath).catch(() => {});
  process.exit(0);
}
process.once("SIGINT", shutdown);
process.once("SIGTERM", shutdown);
