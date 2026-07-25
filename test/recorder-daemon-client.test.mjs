import assert from "node:assert/strict";
import { access, mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { RecorderDaemonClient } from "../lib/recorder-daemon-client.mjs";

const repoRoot = path.resolve(import.meta.dirname, "..");

test("daemon client restarts the daemon after its socket disappears", async () => {
  const storeRoot = await mkdtemp(path.join(os.tmpdir(), "computer-use-capture-reconnect-"));
  const socketPath = path.join(storeRoot, ".daemon.sock");
  const client = await RecorderDaemonClient.connect({ repoRoot, storeRoot });

  try {
    const beforeRestart = await client.call("capabilities");
    assert.equal(beforeRestart.contractVersion, "1.0.0");

    assert.deepEqual(await client.call("shutdownIfIdle"), { stopped: true });
    await waitForMissing(socketPath);

    const [afterRestart, activeRecordingId] = await Promise.all([
      client.call("capabilities"),
      client.call("activeRecordingId")
    ]);
    assert.equal(afterRestart.contractVersion, "1.0.0");
    assert.equal(activeRecordingId, null);
    await access(socketPath);
  } finally {
    await client.call("shutdownIfIdle").catch(() => {});
  }
});

async function waitForMissing(filePath) {
  const deadline = Date.now() + 5_000;
  while (Date.now() < deadline) {
    try {
      await access(filePath);
    } catch (error) {
      if (error?.code === "ENOENT") return;
      throw error;
    }
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.fail(`Timed out waiting for ${filePath} to be removed`);
}
