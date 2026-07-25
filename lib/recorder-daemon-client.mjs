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
  constructor({
    socketPath,
    runtimeVersion,
    repoRoot,
    storeRoot,
    workingDirectory = process.cwd()
  }) {
    this.socketPath = socketPath;
    this.runtimeVersion = runtimeVersion;
    this.repoRoot = path.resolve(repoRoot);
    this.storeRoot = path.resolve(storeRoot);
    this.workingDirectory = path.resolve(workingDirectory);
    this.daemonStartPromise = undefined;
  }

  static async connect({ repoRoot, storeRoot = defaultStoreRoot(), workingDirectory = process.cwd() }) {
    const resolvedRepoRoot = path.resolve(repoRoot);
    const resolvedStoreRoot = path.resolve(storeRoot);
    const socketPath = path.join(resolvedStoreRoot, ".daemon.sock");
    const runtimeVersion = JSON.parse(
      await readFile(path.join(resolvedRepoRoot, "package.json"), "utf8")
    ).version;
    const client = new RecorderDaemonClient({
      socketPath,
      runtimeVersion,
      repoRoot: resolvedRepoRoot,
      storeRoot: resolvedStoreRoot,
      workingDirectory
    });
    await client.ensureDaemon();
    return client;
  }

  async ensureDaemon() {
    if (!this.daemonStartPromise) {
      this.daemonStartPromise = this.startDaemon().finally(() => {
        this.daemonStartPromise = undefined;
      });
    }
    return this.daemonStartPromise;
  }

  async startDaemon() {
    const existing = await this.pingStatus();
    if (existing?.protocolVersion === RECORDER_DAEMON_PROTOCOL_VERSION
        && existing.runtimeVersion === this.runtimeVersion) return;
    if (existing) {
      const retired = await this.callOnce("shutdownIfIdle", {}).catch(() => ({ stopped: false }));
      if (!retired?.stopped) {
        throw new RecorderError(
          "storage_unavailable",
          `Recorder daemon ${existing.runtimeVersion ?? "unknown"} is busy and cannot be replaced by ${this.runtimeVersion}. Stop its active recording or render and retry.`,
          { retryable: true }
        );
      }
      await new Promise(resolve => setTimeout(resolve, 100));
    }

    const child = spawn(process.execPath, [path.join(this.repoRoot, "scripts", "recorder-daemon.mjs")], {
      cwd: this.repoRoot,
      env: { ...process.env, COMPUTER_USE_CAPTURE_STORE: this.storeRoot },
      detached: true,
      stdio: "ignore"
    });
    child.unref();

    const deadline = Date.now() + START_TIMEOUT_MS;
    while (Date.now() < deadline) {
      await new Promise(resolve => setTimeout(resolve, 80));
      const status = await this.pingStatus();
      if (status?.protocolVersion === RECORDER_DAEMON_PROTOCOL_VERSION
          && status.runtimeVersion === this.runtimeVersion) return;
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
    return this.callOnce("ping", {})
      .then(result => result?.ok === true ? result : undefined)
      .catch(() => undefined);
  }

  async call(method, args = {}, requestContext = {}) {
    try {
      return await this.callOnce(method, args, requestContext);
    } catch (error) {
      if (!isMissingDaemonSocket(error)) throw error;
    }

    await this.ensureDaemon();
    try {
      return await this.callOnce(method, args, requestContext);
    } catch (error) {
      if (!isMissingDaemonSocket(error)) throw error;
      throw new RecorderError("storage_unavailable", error.message, { retryable: true });
    }
  }

  async callOnce(method, args = {}, requestContext = {}) {
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

function isMissingDaemonSocket(error) {
  return error?.code === "ENOENT" || error?.code === "ECONNREFUSED";
}

export function defaultStoreRoot() {
  return process.env.COMPUTER_USE_CAPTURE_STORE
    ?? path.join(os.homedir(), "Library", "Application Support", "ComputerUseCapture", "projects");
}
