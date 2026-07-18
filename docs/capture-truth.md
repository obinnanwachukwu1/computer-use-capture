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
- the buffer dimensions and every available ScreenCaptureKit `contentRect`, `boundingRect`, `screenRect`, `scaleFactor`, and `contentScale` value;
- any placement or effective-resolution difference from the first complete frame.

The pixel comparison happens before HEVC, H.264, or ProRes encoding. It compares every visible byte in every row and ignores only row padding. There is no resolution reduction, sampling, channel threshold, changed-area threshold, semantic classification, or lossy decoded-frame comparison.

ScreenCaptureKit's primitives remain important provenance, but live Safari application and strict-window probes on macOS Tahoe emitted every sample as `complete` with no dirty rectangles, including long static spans. For this reason `idle` and damage metadata alone cannot close the visible-change universe on every capture mode. Exact raw-pixel identity supplies the missing proof without guessing what kind of motion occurred.

The first frame establishes the baseline. A later delivered frame is:

- `changed` when any active pixel byte differs;
- `identical` only when every active pixel byte is equal;
- `unavailable` when the buffer cannot be safely read.

The first complete frame also establishes an immutable geometry baseline. A
fixed movie buffer does not prove fixed source placement or density:
ScreenCaptureKit reports how the captured surface was fitted through
`contentRect`, `boundingRect`, `scaleFactor`, and `contentScale`. A later change
relative to the first complete frame is recorded as a geometry discontinuity
until the original geometry returns. Missing rectangle attachments are
recorded as partial observability rather than silently interpreted as
stability. A non-unit value that is already present in the baseline is fit
metadata, not evidence that the stream changed mid-capture.

Display-bound selected-window filtering is the production default. It excludes
other applications while retaining the selected window's tested menus and
popovers at native pixel density. In a controlled TextEdit interaction matrix,
application filtering, selected-window filtering, and
desktop-independent-window filtering all held stable geometry for the entire
recording. The independent-window stream used a stable fitted `contentRect` and
`contentScale`; consumers must normalize that placement instead of treating the
entire output buffer as native window pixels. A true display crop also retained
overlapping windows from unrelated applications, which is undesirable for an
out-of-band Computer Use recorder.

## Capture quality diagnostics

Raw pre-encoder PNG checkpoints are disabled by default. Enable the bounded
diagnostic for a focused reproduction:

```sh
COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_INTERVAL_SECONDS=1 \
COMPUTER_USE_CAPTURE_DIAGNOSTIC_CHECKPOINT_LIMIT=30 \
npm run record -- /tmp/capture-quality 15 com.google.Chrome
```

The checkpoints are copied before `AVAssetWriter` and compressed off the
capture queue. Compare them with the encoded source using:

```sh
npm run analyze:capture-quality -- /tmp/capture-quality.mov \
  --output /tmp/capture-quality.report.json
```

The report keeps geometry discontinuities separate from codec reconstruction
error. HEVC remains the default source codec because the controlled 1600×1112
fixture produced a 0.76 MB six-second source, compared with 82 MB for ProRes
422 LT and 173 MB for ProRes 4444. ProRes is useful for diagnosis, but is not a
practical default for continuously editable agent recordings.

Every completed composition also records `sourceRaster.baseUpscaleFactor`.
The MCP marks render quality as degraded when the source was enlarged before
camera zoom. Camera motion remains editorially available, but low-density
capture can no longer pass as an unreported quality-stable source. The durable
remedies are a HiDPI source, a smaller output, or more canvas around the window;
post-capture enlargement cannot restore missing pixels.

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
- persistent scale and active-raster drift from an immutable baseline;
- missing geometry metadata and subpixel-jitter tolerances.

Director tests verify that a factual action stays protected without proof, a proven no-op can lose only its generic hold, and every unverified interval remains contiguous at 1x. This preserves the intended asymmetric behavior: uncertainty can retain too much time, but it cannot delete visible information.
