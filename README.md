# Agent Recorder proof

This macOS-only proof records a Safari window with ScreenCaptureKit while Codex uses the original Computer Use tool unchanged. It reconstructs Computer Use actions afterward from the current Codex task's read-only event stream, maps screenshot coordinates into capture coordinates, and renders a synthetic cursor plus spring-driven camera motion with a native Metal/Core Image compositor.

## Boundary

The agent only starts and stops recording. The recorder does not wrap, proxy, replace, or patch `sky`. Normal calls such as `sky.click({ app, x, y })` continue through Computer Use directly.

Capture defaults to an application-only ScreenCaptureKit filter cropped to the selected Safari window. It excludes unrelated windows that overlap Safari while retaining Safari-owned windows and popovers inside the crop. Set `AGENTRECORDER_CAPTURE_MODE=window` for strict single-window capture; macOS intentionally omits child and popup windows in that mode.

The current introspection adapter reads two Codex implementation details:

- structured `mcp_tool_call_end` records in the active task JSONL;
- cached Computer Use screenshots for the input coordinate-space dimensions.

Both dependencies are isolated under `lib/`. Unknown future `sky` actions are retained as `unknown`; missing introspection produces a cursorless timeline rather than failing capture. This makes capture the stable core and Codex introspection a replaceable, fail-open adapter.

Element-index actions do not move the real macOS pointer and do not contain x/y coordinates. The adapter therefore joins each index to the preceding Computer Use accessibility text, then passively matches its role/title/value to a low-rate native AX geometry snapshot recorded alongside the video. It never samples the OS cursor and never changes how Computer Use performs the action.

The coordinate resolver retains complete Computer Use accessibility state while merging diff and sliced outputs, understands the combined macOS/AppKit role vocabulary, and records neighboring named elements as structural anchors. Change-driven native snapshots are treated as state intervals: the latest tree before an action remains valid until a newer tree is observed, so a control does not become "stale" merely because the agent thought for several seconds. Native resolution tries identity, post-action focus, and anchor-aligned tree position in that order. Every result records provenance (`direct`, `ax-identity`, `ax-focus`, `ax-structural`, or `unresolved`) and native AX snapshots are persisted beside the capture for replayable diagnostics. Element-index coordinates are never borrowed from motion or another action; unresolved targets remain explicit instead of producing a plausible but false cursor location.

The automatic product-demo preset renders the native macOS cursor at `3x`. The processor accepts `cursorScale` as an override without changing its native hotspot.

## Automatic composition

The editorless `product-demo` preset turns the captured action stream into grouped shots, curved cursor travel, native-hotspot click springs, drag trajectories, an always-visible cursor, scale-aware camera bounds, and action-protected dead-time acceleration. The director transforms the complete composition—not only the captured video—so the Tahoe wallpaper, padding, authored shadow, rounded frame, and window zoom and reframe together. Source and semantic coordinates are mapped through the content rectangle before shot generation, keeping targets correct when padding changes. A separate read-only macOS Accessibility observer records change-driven indexed geometry snapshots plus focused state; typing actions receive normalized semantic bounds and frame the whole control without moving the cursor. If no focused bounds are available, typing does not invent a zoom target. Scroll events never create or steer camera shots.

The native attention director treats pointer intent, drag paths, Accessibility bounds, and action-attributed visual response as evidence for one camera decision. Pointer evidence remains high confidence, but a substantial UI response can widen the decision to include both the control and the changed region—for example, a range button and the chart it updates. Tiny periodic changes remain sensitive enough to preserve time without steering the camera, and whole-page scroll motion is excluded. Adjacent-frame differences remain the timing signal. Framing uses settled snapshots from before and after each action, separates changed pixels into connected components, and locally matches displaced content against its previous position. Newly revealed or transformed components steer the camera; existing panels that merely translate to make room are retained as motion context but excluded from the framing union. Visual observations are assigned to only the nearest plausible action, including frames captured just before tool-result telemetry is written. Grouped shots retain the broadest decision so a later point click cannot crop an earlier large response out of view. The sidecar stores a small agent-editable recipe:

Persistent reveals can also create an attention episode. If at least two later actions are spatially contained by the revealed region within the edited-time horizon, the director keeps them in one shot. It first establishes the complete revealed region, then moves to one tighter shared working frame before the next action and holds it through contained typing, drags, and clicks. Locationless typing may inherit the containing region but never invents an exact field; AX focus bounds can provide that precision when available. Scroll, navigation away from the region, disappearance, scattered targets, or the edited-time limit end or reject the episode. The two-level limit and containment requirement prevent arbitrary long-range grouping and camera breathing.

```json
{
  "preset": "product-demo",
  "cursorScale": 3,
  "director": {
    "deadTimeRate": 6,
    "cursorCompression": 0.1,
    "zoomStrength": 1
  }
}
```

This is the editing surface for now: an agent can change intent-level values and re-render without a visual timeline editor.

The historical Computer Use compatibility audit is in [`docs/computer-use-compatibility.md`](docs/computer-use-compatibility.md).
The AX and Computer Use descriptor audit is in [`docs/accessibility-vocabulary.md`](docs/accessibility-vocabulary.md). Re-run the local corpus audit with `npm run audit:accessibility`.

## Run

```sh
swift build -c release
.build/release/export-macos-cursor artifacts/macos-arrow.png
npm install
npm run record -- artifacts/my-recording 300
```

Wait for `RECORDING_READY`, use Computer Use normally, then send a newline to stop. The command writes a `.mov` and `.timeline.json`.

Capture requests ScreenCaptureKit's `.best` resolution and sizes the stream from the selected filter's actual `pointPixelScale`, avoiding a logical-resolution surface enlarged into a Retina-sized buffer. The default source codec is hardware HEVC at a high screen-content bitrate. `AGENTRECORDER_CAPTURE_CODEC=h264` is available for compatibility; `prores422lt` and `prores4444` provide progressively larger editing masters when chroma fidelity is more important than disk usage. The recorder logs the first frame's buffer size, scale factor, and content scale so accidental upscaling is visible rather than inferred later.

Run the complete editorless native composition pipeline:

```sh
npm run compose -- artifacts/my-recording
```

The output is `artifacts/my-recording.directed.mp4`. The compose command generates a renderer-sized copy of the installed macOS Tahoe Light wallpaper when needed. ScreenCaptureKit shadows are explicitly disabled; Core Image generates the rounded window mask and two-layer shadow. The compositor evaluates the director on a fixed offline clock, renders at native 1440x1050, and writes hardware H.264 directly through AVFoundation.

## Native 60fps composition with temporal motion sampling

`native-compose` reads the existing recording and timeline directly, renders through Core Image on Metal, temporally samples camera and cursor transforms within every frame, and writes hardware H.264 without Chrome or Pixi. Final composition defaults to native 1x (1440x1050 on the current display), avoiding enlargement of a native 1x ScreenCaptureKit surface. When recording on a Retina display that reports a genuine 2x source, use `--output-scale 2` or `AGENTRECORDER_OUTPUT_SCALE=2` for a 2880x2100 final. The Swift director implements grouped shots, semantic field framing, scroll exclusion, drag focus, curved cursor travel, click springs, camera bounds, deterministic spring smoothing, and dead-time retiming.

The default cursor motion uses restrained, edge-aware cubic paths with a slower deliberative departure and a velocity/acceleration-driven attitude. The macOS arrow stays at its normal angle most of the time; increasing motion may trail its tail clockwise only, with a hard limit at the vertically aligned pose. Attitude uses a fast-attack, slow-release inertia envelope, so recent pointer momentum continues settling after the hotspot stops instead of snapping back with the path animation. The cursor is exported from macOS's genuine 10x `NSCursor.arrow` representation (280x400) and downsampled in the Metal composition, preserving clean edges through 3x sizing, camera zoom, rotation, and motion blur. Use `--cursor-path straight` to retain linear travel, or `--cursor-tilt-strength 0` to disable the inertial attitude; values through `1.5` are accepted for stronger tilt without bypassing the vertical limit.

Pointer and camera behavior share one action choreography: the cursor departs first, the camera follows, the pointer arrives before the click spring, the camera settles after the action, and the shot holds briefly before a nearly symmetric exit. The cursor uses minimum-jerk endpoint easing; the camera uses an emphasized curve that covers distance earlier and reserves more of a fast move for visible deceleration. Nearby actions remain in one continuous shot. The time warp smooths transitions between protected 1x action ranges and accelerated dead time, and every shutter sample interpolates the correct neighboring source-video frames so page motion and camera motion retain the same cadence.

Click timing is phase-based rather than a fixed telemetry offset. The rollout adapter preserves the complete Computer Use tool-call envelope and its original estimate. During the native prepass, full-rate target-local frame differences are clustered into optional hover/arrival, activation, and later response phases. Cursor travel may finish at the earlier arrival phase while the click spring and action choreography use measured activation. If the target has no detectable visual state, a final standalone `sky.click` falls back to semantic tool completion; calls followed by more Computer Use work retain the original estimate. Director diagnostics report the raw estimate, tool bounds, measured phases, threshold, and selected source for every refined action.

Shot grouping uses edited output time rather than raw agent time. Nearby controls are clustered when their projected camera viewports overlap and all targets fit inside one stable zoom envelope. Strongly overlapping targets can bridge up to 3.8 seconds in the edited video; the camera stays zoomed and pans between them instead of returning to 1x. A cluster-fit constraint prevents chains of individually nearby actions from gradually drifting across the screen.

```sh
swift run -c release native-compose \
  artifacts/milestone-product-demo.mov \
  artifacts/milestone-product-demo.timeline.json \
  artifacts/native-motion-blur-60.mp4 \
  --fps 60 --samples 8 --shutter 0.55
```

The exported file defaults to standard 60fps. `--samples 8` evaluates camera and cursor motion at 480 temporal samples per second and integrates those samples into the 60 output frames, retaining fast-camera blur without marking the movie as high-frame-rate slow motion. `--shutter` controls how much of each frame interval contributes to motion blur. `npm run compose` exposes the same settings as `AGENTRECORDER_FPS`, `AGENTRECORDER_MOTION_SAMPLES`, and `AGENTRECORDER_SHUTTER`.

## Director diagnostics and scenario contracts

Use the native diagnostic overlay when a framing decision needs explanation:

```bash
npm run compose -- artifacts/my-recording --director-debug
```

The output video includes cyan final-attention bounds, red appearance components, blue translated components, yellow pointer evidence, green Accessibility evidence, and magenta visual-response evidence. A sibling `*.director.json` report records every action, source/output time, evidence weight, attention behavior and bounds, episode membership, camera center/scale, shot membership, and classified motion component. `--plan-only --director-debug` writes the same report without rendering video.

Generalization contracts live in `Fixtures/DirectorScenarios/scenarios.json`. They cover contained modal work, popovers, side panels, chart updates followed by departure, scroll motion, and reveals followed by unrelated actions. `swift test` validates episode membership and shot behavior for every scenario alongside the lower-level motion and camera tests.

### Agent waiting time

The director removes visually static agent waiting by default while preserving interaction and visible motion at their natural speed. The default retained still-frame handle is 100 milliseconds; customize it with:

```sh
npm run compose -- artifacts/my-recording --waiting-time 100
```

`--waiting-time` is milliseconds retained per visually static gap, split between the last still moment before the cut and the first still moment after it. Interaction, typing, drag, scroll, and camera ranges remain at 1x. The timeline identifies candidate waiting regions, then a native prepass compares downscaled decoded frames: sustained still runs are cut, while visually moving waiting ranges are retained and smoothly accelerated at the recipe's dead-time rate. Localized and periodic changes are bridged into motion ranges, so a blinking caret, UI animation, or other real motion prevents a hard cut without forcing the entire wait to remain at 1x. The equivalent environment variables are `AGENTRECORDER_REDUCE_WAITING=1` and `AGENTRECORDER_WAITING_TIME_MS=100`.

Use `--keep-waiting` (or `AGENTRECORDER_REDUCE_WAITING=0`) when a faithful, uncut timeline is needed. The legacy `--reduce-waiting` flag remains accepted for existing scripts.

## Current limitations

- Safari is the only capture target and screenshot adapter name currently wired in.
- Action timestamps are estimated within each Computer Use tool-call duration; the event stream does not expose the exact injection instant.
- Coordinate clicks and drags use their logged coordinates. Element-index actions use passive role/title/value matching against recorder-side AX snapshots; ambiguous or missing matches fail open without inventing a cursor target.
- Camera, cursor, and neighboring source-video frames are temporally sampled together. Optical-flow interpolation is not yet used, so extremely fast source-only animation can still reveal ordinary cross-frame blending.
- The task JSONL and screenshot cache are private Codex implementation seams. Schema probes and adapter versioning are required before treating this as a distributable product.
