import assert from "node:assert/strict";
import test from "node:test";
import { discontinuityRuns, summarizeCaptureLedger } from "../lib/capture-quality.mjs";

const baseline = {
  bufferWidth: 1200,
  bufferHeight: 800,
  contentRect: { x: 0, y: 0, width: 1200, height: 800 },
  boundingRect: { x: 100, y: 80, width: 600, height: 400 },
  scaleFactor: 2,
  contentScale: 1
};

test("capture quality distinguishes placement drift from resolution drift", () => {
  const ledger = {
    version: 2,
    geometryBaseline: baseline,
    samples: [
      { sourceTime: 0, status: "complete", geometry: baseline },
      {
        sourceTime: 1,
        status: "complete",
        geometry: { ...baseline, contentRect: { ...baseline.contentRect, x: 20 } },
        geometryDiscontinuities: [{ kind: "contentRectX", baseline: 0, observed: 20 }]
      },
      {
        sourceTime: 2,
        status: "complete",
        geometry: {
          ...baseline,
          contentRect: { ...baseline.contentRect, width: 1100 },
          contentScale: 0.92
        },
        geometryDiscontinuities: [
          { kind: "contentRectWidth", baseline: 1200, observed: 1100 },
          { kind: "contentScale", baseline: 1, observed: 0.92 }
        ]
      }
    ]
  };
  const summary = summarizeCaptureLedger(ledger);
  assert.equal(summary.verdict, "discontinuous");
  assert.equal(summary.samples.placementDiscontinuityFrames, 1);
  assert.equal(summary.samples.resolutionDiscontinuityFrames, 1);
  assert.deepEqual(summary.ranges.contentWidth, { min: 1100, max: 1200 });
});
test("discontinuity runs group only adjacent frames with the same cause", () => {
  const samples = [
    { sourceTime: 1, geometryDiscontinuities: [{ kind: "contentScale" }] },
    { sourceTime: 1.05, geometryDiscontinuities: [{ kind: "contentScale" }] },
    { sourceTime: 1.1, geometryDiscontinuities: [] },
    { sourceTime: 2, geometryDiscontinuities: [{ kind: "contentRectX" }] }
  ];
  assert.deepEqual(discontinuityRuns(samples), [
    { start: 1, end: 1.05, frames: 2, kinds: ["contentScale"] },
    { start: 2, end: 2, frames: 1, kinds: ["contentRectX"] }
  ]);
});
