import { spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { createConnection } from "node:net";
import os from "node:os";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { RecorderError } from "./recorder-service.mjs";

const START_TIMEOUT_MS = 10_000;
export const RECORDER_DAEMON_PROTOCOL_VERSION = 1;

export class RecorderDaemonClient {
  constructor({ socketPath, runtimeVersion, workingDirectory = process.cwd() }) {
    this.socketPath = socketPath;
    this.runtimeVersion = runtimeVersion;
    this.workingDirectory = path.resolve(workingDirectory);
  }

  static async connect({ repoRoot, storeRoot = defaultStoreRoot(), workingDirectory = process.cwd() }) {
    const socketPath = path.join(path.resolve(storeRoot), ".daemon.sock");
    const runtimeVersion = JSON.parse(await readFile(path.join(repoRoot, "package.json"), "utf8")).version;
    const client = new RecorderDaemonClient({ socketPath, runtimeVersion, workingDirectory });
    const existing = await client.pingStatus();
    if (existing?.protocolVersion === RECORDER_DAEMON_PROTOCOL_VERSION
        && existing.runtimeVersion === runtimeVersion) return client;
    if (existing) {
      const retired = await client.call("shutdownIfIdle", {}).catch(() => ({ stopped: false }));
      if (!retired?.stopped) {
        throw new RecorderError(
          "storage_unavailable",
          `Recorder daemon ${existing.runtimeVersion ?? "unknown"} is busy and cannot be replaced by ${runtimeVersion}. Stop its active recording or render and retry.`,
          { retryable: true }
        );
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    const child = spawn(process.execPath, [path.join(repoRoot, "scripts", "recorder-daemon.mjs")], {
      cwd: repoRoot,
      env: { ...process.env, COMPUTER_USE_CAPTURE_STORE: path.resolve(storeRoot) },
      detached: true,
      stdio: "ignore"
    });
    child.unref();

    const deadline = Date.now() + START_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 80));
      const status = await client.pingStatus();
      if (status?.protocolVersion === RECORDER_DAEMON_PROTOCOL_VERSION
          && status.runtimeVersion === runtimeVersion) return client;
    }
    throw new RecorderError(
      "storage_unavailable",
      "The shared recorder daemon did not become ready. Close any older Computer Use Capture MCP process and retry.",
      { retryable: true }
    );
  }

  async ping() {
    return this.pingStatus().then(result =>
      result?.protocolVersion === RECORDER_DAEMON_PROTOCOL_VERSION
        && result.runtimeVersion === this.runtimeVersion
    );
  }

  async pingStatus() {
    return this.call("ping", {}).then(result => result?.ok === true ? result : undefined).catch(() => undefined);
  }

  async call(method, args = {}, requestContext = {}) {
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      let buffer = "";
      let settled = false;
      const finish = (callback, value) => {
        if (settled) return;
        settled = true;
        socket.destroy();
        callback(value);
      };
      socket.setEncoding("utf8");
      socket.setTimeout(120_000, () => finish(reject, new RecorderError(
        "storage_unavailable", "Recorder daemon request timed out", { retryable: true }
      )));
      socket.once("error", error => finish(reject, error));
      socket.once("close", () => {
        if (!settled) finish(reject, new RecorderError(
          "storage_unavailable", "Recorder daemon closed the request without a response", { retryable: true }
        ));
      });
      socket.on("data", chunk => {
        buffer += chunk;
        const newline = buffer.indexOf("\n");
        if (newline < 0) return;
        try {
          const response = JSON.parse(buffer.slice(0, newline));
          if (response.id !== id) throw new Error("Recorder daemon returned a mismatched response");
          if (response.error) {
            finish(reject, new RecorderError(response.error.code, response.error.message, {
              retryable: response.error.retryable,
              data: response.error.data
            }));
          } else {
            finish(resolve, response.result);
          }
        } catch (error) {
          finish(reject, error);
        }
      });
      socket.once("connect", () => socket.write(`${JSON.stringify({
        id,
        method,
        args,
        context: { workingDirectory: this.workingDirectory, ...requestContext }
      })}\n`));
    });
  }
}

export function defaultStoreRoot() {
  return process.env.COMPUTER_USE_CAPTURE_STORE
    ?? path.join(os.homedir(), "Library", "Application Support", "ComputerUseCapture", "projects");
}
