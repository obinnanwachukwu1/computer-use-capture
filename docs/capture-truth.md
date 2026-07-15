# Capture truth and safe waiting reduction

Waiting reduction may change elapsed time, but it must not contradict the factual Computer Use stream or delete a visible consequence. The system therefore has three distinct authorities:

1. Computer Use is authoritative about which action occurred.
2. The capture-truth ledger is authoritative about visible source-frame changes.
3. The motion and attention models are editorial evidence only. They may frame or accelerate retained material, but they cannot prove absence or authorize deletion.

## Capture-time ledger

Every new recording writes `<base>.capture.json` beside the source movie. For each delivered ScreenCaptureKit sample it stores:

- presentation time relative to the first committed complete frame;
- WindowServer `displayTime`;
- `SCFrameStatus`;
- `dirtyRects`;
- whether a complete frame was appended or dropped by the writer;
- whether all active raw BGRA bytes are identical to the preceding delivered frame.

The pixel comparison happens before HEVC, H.264, or ProRes encoding. It compares every visible byte in every row and ignores only row padding. There is no resolution reduction, sampling, channel threshold, changed-area threshold, semantic classification, or lossy decoded-frame comparison.

ScreenCaptureKit's primitives remain important provenance, but live Safari application and strict-window probes on macOS Tahoe emitted every sample as `complete` with no dirty rectangles, including long static spans. For this reason `idle` and damage metadata alone cannot close the visible-change universe on every capture mode. Exact raw-pixel identity supplies the missing proof without guessing what kind of motion occurred.

The first frame establishes the baseline. A later delivered frame is:

- `changed` when any active pixel byte differs;
- `identical` only when every active pixel byte is equal;
- `unavailable` when the buffer cannot be safely read.

## Tri-state inference

The analyzer produces `visibleChange`, `provenIdle`, or `unknown` intervals.

An interval is `provenIdle` only when consecutive samples arrive within the allowed capture cadence and the later frame is byte-identical, or when consecutive WindowServer samples explicitly report idle. It becomes `visibleChange` when exact pixels changed. Every other state is `unknown`.

The implementation fails closed. These conditions prevent idle proof:

- a complete frame without an exact comparison;
- any writer backpressure, non-monotonic timestamp, or append failure;
- missing ScreenCaptureKit metadata;
- a delivery gap exceeding the cadence allowance;
- blank, suspended, started, stopped, or unknown status;
- incomplete action/capture clock alignment;
- a declared sidecar that cannot be loaded.

Old recordings without a capture-truth sidecar retain the legacy motion-based waiting behavior for reproducibility. A new timeline that declares a sidecar but cannot supply valid evidence preserves all unverified time at 1x.

## Factual action policy

All Computer Use actions remain in the timeline. Pointer and input actions retain their normal factual presentation rules. Scroll is the only action currently eligible to lose its generic protected hold because it has no synthetic pointer or keyboard overlay.

A scroll is considered a proven visual no-op only when the interval from its exact tool-call start until the next factual action's tool-call start is completely covered by `provenIdle`. A changed or unknown subinterval preserves the scroll envelope. Missing timing for either neighboring action also preserves it.

Removing a no-op scroll's hold does not remove the action record. It lets the ordinary proven-idle interval collapse to the configured still-frame handles in the edit decision list.

## Verification

`CaptureTruthTests` covers:

- consecutive idle samples;
- application streams that always report complete but deliver identical pixels;
- a one-frame visible change;
- one-pixel damage;
- delivery gaps;
- dropped frames;
- missing metadata;
- blank and suspended capture.

Director tests verify that a factual action stays protected without proof, a proven no-op can lose only its generic hold, and every unverified interval remains contiguous at 1x. This preserves the intended asymmetric behavior: uncertainty can retain too much time, but it cannot delete visible information.
