import { StringDecoder } from "node:string_decoder";
import { open, stat } from "node:fs/promises";
import { createComputerUseEventAccumulator } from "./codex-events.mjs";

/**
 * Incrementally consumes Codex's append-only rollout JSONL while capture is in
 * progress. A single accumulator owns JavaScript bindings and AX snapshot
 * history, so live and post-stop reconstruction have identical semantics.
 */
export class CodexEventTailer {
  constructor({ sessionFile, captureStartedAt, pollIntervalMs = 100, onProgress }) {
    this.sessionFile = sessionFile;
    this.pollIntervalMs = pollIntervalMs;
    this.onProgress = onProgress;
    this.accumulator = createComputerUseEventAccumulator({ captureStartedAt });
    this.offset = 0;
    this.remainder = "";
    this.decoder = new StringDecoder("utf8");
    this.timer = undefined;
    this.inFlight = Promise.resolve();
    this.invalidCompleteLines = 0;
    this.invalidTrailingRecord = false;
    this.lastEventCount = 0;
    this.error = undefined;
  }

  async start() {
    await this.poll();
    this.timer = setInterval(() => {
      this.inFlight = this.inFlight.then(() => this.poll()).catch(error => {
        this.error = error;
        this.onProgress?.({ type: "error", error });
      });
    }, this.pollIntervalMs);
    this.timer.unref();
    return this;
  }

  async poll() {
    const metadata = await stat(this.sessionFile);
    if (metadata.size < this.offset) {
      throw new Error("Codex rollout was truncated while recording");
    }
    if (metadata.size === this.offset) return;

    const handle = await open(this.sessionFile, "r");
    try {
      const buffer = Buffer.allocUnsafe(256 * 1024);
      while (this.offset < metadata.size) {
        const length = Math.min(buffer.length, metadata.size - this.offset);
        const { bytesRead } = await handle.read(buffer, 0, length, this.offset);
        if (!bytesRead) break;
        this.offset += bytesRead;
        this.#consume(this.decoder.write(buffer.subarray(0, bytesRead)));
      }
    } finally {
      await handle.close();
    }
    const eventCount = this.accumulator.snapshot().events.length;
    if (eventCount !== this.lastEventCount) {
      this.lastEventCount = eventCount;
      this.onProgress?.({ type: "events", eventCount, offset: this.offset });
    }
  }

  async stop({ captureEndedAt } = {}) {
    if (this.timer) clearInterval(this.timer);
    this.timer = undefined;
    await this.inFlight;
    if (this.error) throw this.error;
    await this.poll();
    const decoderRemainder = this.decoder.end();
    if (decoderRemainder) this.remainder += decoderRemainder;
    if (this.remainder.trim()) {
      try {
        this.accumulator.ingest(JSON.parse(this.remainder));
        this.remainder = "";
      } catch {
        this.invalidTrailingRecord = true;
      }
    }
    return this.snapshot({ captureEndedAt });
  }

  snapshot({ captureEndedAt } = {}) {
    return {
      ...this.accumulator.snapshot({ captureEndedAt }),
      live: {
        bytesRead: this.offset,
        invalidCompleteLines: this.invalidCompleteLines,
        invalidTrailingRecord: this.invalidTrailingRecord
      }
    };
  }

  #consume(chunk) {
    const contents = this.remainder + chunk;
    const lines = contents.split("\n");
    this.remainder = lines.pop() ?? "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        this.accumulator.ingest(JSON.parse(line));
      } catch {
        // A newline establishes that this is a complete malformed record,
        // unlike the expected partial final line retained above.
        this.invalidCompleteLines += 1;
      }
    }
  }
}
