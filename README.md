# Computer Use Capture

This macOS-only proof records a declared application window with ScreenCaptureKit while Codex uses the original Computer Use tool unchanged. It tails Computer Use actions from the current Codex task's read-only event stream during capture, maps screenshot coordinates into capture coordinates, and renders a synthetic cursor plus spring-driven camera motion with a native Metal/Core Image compositor.

## Boundary

The agent only starts and stops recording. The recorder does not wrap, proxy, replace, or patch `sky`. Normal calls such as `sky.click({ app, x, y })` continue through Computer Use directly.

Safari defaults to an application-only ScreenCaptureKit filter cropped to its selected window so Safari-owned popovers remain visible. Other macOS apps default to strict single-window capture, which prevents hidden or off-screen app-owned modal windows from corrupting a document recording. `AGENTRECORDER_CAPTURE_MODE=application|window` explicitly overrides this policy; strict window mode intentionally omits child and popup windows.

The current introspection adapter reads two Codex implementation details:

- structured `mcp_tool_call_end` records in the active task JSONL;
- cached Computer Use screenshots for the input coordinate-space dimensions.

Both dependencies are isolated under `lib/`. Unknown future `sky` actions are retained as `unknown`; missing introspection produces a cursorless timeline rather than failing capture. This makes capture the stable core and Codex introspection a replaceable, fail-open adapter.

The rollout log is a live event source, not the sole source of truth. A stateful incremental tailer consumes complete appended JSONL records while recording and preserves earlier JavaScript bindings and full/diff Computer Use Accessibility snapshots. The recorder-side macOS AX watcher and source frames independently supply geometry and visual timing. Stop waits for the writer to become quiescent, drains the same accumulator, and falls back to a full-file reconstruction with an explicit warning if live tailing fails. State omitted from a Computer Use result cannot be recovered by either path.

Element-index actions do not move the real macOS pointer and do not contain x/y coordinates. The adapter therefore joins each index to the preceding Computer Use accessibility text, then passively matches its role/title/value to a low-rate native AX geometry snapshot recorded alongside the video. It never samples the OS cursor and never changes how Computer Use performs the action.

The coordinate resolver retains complete Computer Use accessibility state while merging diff and sliced outputs, understands the combined macOS/AppKit role vocabulary, and records neighboring named elements as structural anchors. Change-driven native snapshots are treated as state intervals: the latest tree before an action remains valid until a newer tree is observed, so a control does not become "stale" merely because the agent thought for several seconds. Native resolution tries identity, post-action focus, and anchor-aligned tree position in that order. Ordered reconstruction also treats an explicit Computer Use action on a text control as focus ownership for following keyboard actions until another explicit focus-changing action; this prevents a lagging AX focus bit from contradicting the agent's click. Every result records provenance (`direct`, `ax-identity`, `ax-focus`, `ax-structural`, or `unresolved`) and native AX snapshots are persisted beside the capture for replayable diagnostics. Element-index coordinates are never borrowed from motion or another pointer action; unresolved targets remain explicit instead of producing a plausible but false cursor location.

The automatic product-demo preset renders the native macOS cursor at `3x`. The processor accepts `cursorScale` as an override without changing its native hotspot. Pointer actions are rendered only when their target provenance clears the factual-confidence policy; inferred targets may steer framing but are cursorless unless an edit explicitly opts in.

## Automatic composition

The editorless `product-demo` preset turns the captured action stream into grouped shots, curved cursor travel, native-hotspot click springs, drag trajectories, factual-action cursor visibility, scale-aware camera bounds, and action-protected dead-time acceleration. Idle cursor position is unconstrained, but every rendered click or drag is kept visible. The director transforms the complete composition—not only the captured video—so the Tahoe wallpaper, padding, authored shadow, rounded frame, and window zoom and reframe together. Source and semantic coordinates are mapped through an aspect-preserving content rectangle derived from the captured source before shot generation, keeping targets correct across window shapes and padding changes. A separate read-only macOS Accessibility observer records change-driven indexed geometry snapshots plus focused state; typing actions receive normalized semantic bounds and frame the whole control without moving the cursor. If no focused bounds are available, typing does not invent a zoom target. Scroll events never create or steer camera shots.

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

## MCP workflow

The MCP server implements the seven-tool contract in [`docs/mcp-tools.schema.json`](docs/mcp-tools.schema.json). Start it over stdio with:

```sh
npm install
npm run mcp
```

The intended agent flow is deliberately small:

1. `recorder_capabilities` builds/locates the native preflight helper, checks Screen Recording and Accessibility, reports visible application targets, and probes the observed Codex adapter shape. `recorder_start` requires exactly one eligible window for its declared bundle identifier and checks that app's screenshot evidence.
2. `recorder_start` returns only after the first video frame is committed. The agent then uses Computer Use normally; the recorder receives no per-action calls.
3. `recorder_stop` finalizes capture, waits for the Codex event log to settle, drains the live factual-action reconstruction, and normally enqueues the default render.
4. `recorder_get` polls the render. `recorder_edit` applies high-level intents and enqueues another render; `recorder_cancel` cancels a render; `recorder_discard` permanently removes the recording and every artifact.

The server allows one active recording and one active render per recording. IDs—not caller-supplied paths—address everything. Projects live under `~/Library/Application Support/AgentRecorder/projects` by default, with a manifest, source video, capture-truth ledger, value-redacted Accessibility sidecar, timeline, logs, and render artifacts. Files persist until `recorder_discard`; the raw AX stream is private temporary state and is removed after reconstruction or process exit. A store lock prevents two MCP daemons from mutating the same project store.

The default edit intent reduces visually static waiting to 100 ms, uses semantic zoom strength `1`, a native `3x` natural-path cursor, standard motion blur, and never renders inferred cursor targets. Edits reference stable `act_<digest>` IDs and can change waiting, zoom strength, cursor path/scale/tilt, motion blur, per-action emphasis, and per-action holds without exposing renderer internals.

## Run

```sh
swift build -c release
.build/release/export-macos-cursor artifacts/macos-arrow.png
npm install
npm run record -- artifacts/my-recording 300
```

Wait for `RECORDING_READY`, use Computer Use normally, then send a newline to stop. The command writes a `.mov`, `.capture.json`, and `.timeline.json`.

Capture requests ScreenCaptureKit's `.best` resolution and sizes the stream from the selected filter's actual `pointPixelScale`, avoiding a logical-resolution surface enlarged into a Retina-sized buffer. The default source codec is hardware HEVC at a high screen-content bitrate. `AGENTRECORDER_CAPTURE_CODEC=h264` is available for compatibility; `prores422lt` and `prores4444` provide progressively larger editing masters when chroma fidelity is more important than disk usage. The recorder logs the first frame's buffer size, scale factor, and content scale so accidental upscaling is visible rather than inferred later.

Run the complete editorless native composition pipeline:

```sh
npm run compose -- artifacts/my-recording
```

The output is `artifacts/my-recording.directed.mp4`. The compose command generates a renderer-sized copy of the installed macOS Tahoe Light wallpaper when needed. ScreenCaptureKit shadows are explicitly disabled; Core Image generates the rounded window mask and two-layer shadow. The compositor evaluates the director on a fixed offline clock, uses a 1440x1050 presentation canvas with an aspect-preserving window region derived from the source, and writes hardware H.264 directly through AVFoundation.

## Native 60fps composition with temporal motion sampling

`native-compose` reads the existing recording and timeline directly, renders through Core Image on Metal, temporally samples camera and cursor transforms within every frame, and writes hardware H.264 without Chrome or Pixi. Final composition defaults to native 1x (1440x1050 on the current display), avoiding enlargement of a native 1x ScreenCaptureKit surface. When recording on a Retina display that reports a genuine 2x source, use `--output-scale 2` or `AGENTRECORDER_OUTPUT_SCALE=2` for a 2880x2100 final. The Swift director implements grouped shots, semantic field framing, scroll exclusion, drag focus, curved cursor travel, click springs, camera bounds, deterministic spring smoothing, and dead-time retiming.

The default cursor motion uses restrained, edge-aware cubic paths with a slower deliberative departure and a velocity/acceleration-driven attitude. The macOS arrow stays at its normal angle most of the time; increasing motion may trail its tail clockwise only, with a hard limit at the vertically aligned pose. Attitude uses a fast-attack, slow-release inertia envelope, so recent pointer momentum continues settling after the hotspot stops instead of snapping back with the path animation. The cursor is exported from macOS's genuine 10x `NSCursor.arrow` representation (280x400) and downsampled in the Metal composition, preserving clean edges through 3x sizing, camera zoom, rotation, and motion blur. Use `--cursor-path straight` to retain linear travel, or `--cursor-tilt-strength 0` to disable the inertial attitude; values through `1.5` are accepted for stronger tilt without bypassing the vertical limit.

Pointer and camera behavior share one action choreography: the cursor departs first, the camera follows, the pointer arrives before the click spring, the camera settles after the action, and the shot holds briefly before a nearly symmetric exit. The cursor uses minimum-jerk endpoint easing; the camera uses an emphasized curve that covers distance earlier and reserves more of a fast move for visible deceleration. Nearby actions remain in one continuous shot. The time warp smooths transitions between protected 1x action ranges and accelerated dead time, and every shutter sample interpolates the correct neighboring source-video frames so page motion and camera motion retain the same cadence.

V3 is the default clip-wide production planner, not another local camera repair pass. It preserves alternative interaction timings, causal attributions, foreground lifecycles, and attention regions in an immutable graph, then jointly selects timing, activation framing, response framing, and the camera trajectory across the entire clip. It has no shot or episode reset states; factual cursor visibility and Computer Use event ordering are hard constraints, while movement and editorial taste remain costs. The same selected action times feed a single global retime partition. Long keyboard-only intervals use an explicit pointer-reveal transition when the synthetic cursor's factual departure lies outside the held shot. Each run writes a `.production-plan.json` decision and search trace beside the camera audit. The architecture, current boundary, and replacement gates are in [`docs/production-planner-v3.md`](docs/production-planner-v3.md).

Experimental V4 changes the planning vocabulary rather than adding another V3 cost term. `SubjectGraph` first infers persistent surfaces, factual targets, scene transitions, and localized responses without prescribing camera behavior. `ShotSchedule` then prices emphasis once per subject span and emits explicit overview, framing, orientation, and response beats. The renderer consumes continuous camera tracks for factual visibility instead of injecting per-frame repair poses. V4 remains behind `--camera-planner v4`; every run writes a `.v4-plan.json`, and `npm run compare:v4` compares it against V3 before any default promotion. See [`docs/camera-planner-v4.md`](docs/camera-planner-v4.md).

Click timing is phase-based rather than a fixed telemetry offset. The rollout adapter preserves the complete Computer Use tool-call envelope and its original estimate. During the native prepass, full-rate target-local frame differences are clustered into optional hover/arrival, activation, and later response phases. Cursor travel may finish at the earlier arrival phase while the click spring and action choreography use measured activation. If the target has no detectable visual state, a final standalone `sky.click` falls back to semantic tool completion; calls followed by more Computer Use work retain the original estimate. Director diagnostics report the raw estimate, tool bounds, measured phases, threshold, and selected source for every refined action.

Shot grouping uses edited output time rather than raw agent time. Nearby controls are clustered when their projected camera viewports overlap and all targets fit inside one stable zoom envelope. Strongly overlapping targets can bridge up to 3.8 seconds in the edited video; the camera stays zoomed and pans between them instead of returning to 1x. A cluster-fit constraint prevents chains of individually nearby actions from gradually drifting across the screen.

Accessibility reconstruction also preserves viewport relocations. When the same semantic target is outside the captured window before a Computer Use action and clearly inside it afterward, the director treats that geometry change as a shot boundary rather than ordinary layout motion. It establishes the full window before the pointer trip, holds the wide context while the application scrolls or navigates, shows the factual click, and focuses the newly visible region only after it settles.

```sh
swift run -c release native-compose \
  artifacts/milestone-product-demo.mov \
  artifacts/milestone-product-demo.timeline.json \
  artifacts/native-motion-blur-60.mp4 \
  --fps 60 --samples 8 --shutter 0.55
```

The exported file defaults to standard 60fps. `--samples 8` evaluates camera and cursor motion at 480 temporal samples per second and integrates those samples into the 60 output frames, retaining fast-camera blur without marking the movie as high-frame-rate slow motion. `--shutter` controls how much of each frame interval contributes to motion blur. `npm run compose` exposes the same settings as `AGENTRECORDER_FPS`, `AGENTRECORDER_MOTION_SAMPLES`, and `AGENTRECORDER_SHUTTER`.

### Profile and benchmark the pipeline

Add `--profile` to a normal composition to write an in-process phase report
next to the output, or provide an explicit JSON path:

```bash
npm run compose -- artifacts/recording --profile
npm run compose -- artifacts/recording --profile /tmp/recording.profile.json
```

The report separates source setup, motion analysis, capture-truth loading,
composition/camera planning, camera sampling, decode/composite/encode, and
writer finalization. It also records source/output duration, dimensions,
frame counts, action counts, planner version, temporal-sample settings, and
whether immutable motion evidence came from cache.

Motion analysis is cached beside the source using a SHA-256 digest of the full
movie plus the exact timing/target inputs consumed by the detector. Camera,
waiting, emphasis, and blur edits reuse that evidence; source pixels, action
timing, semantic target geometry, detector revision, or relocation evidence
invalidate it. Debug motion-field runs bypass the cache because they require
additional diagnostic data. `--no-analysis-cache` is available for cold-path
validation without deleting a valid cache.

For repeatable measurements, build once and run isolated plan-only and full
export trials with macOS process CPU and peak-memory accounting:

```bash
npm run benchmark:pipeline -- \
  /path/to/source.mov /path/to/source.timeline.json \
  --mode both --trials 3 --planner v3 --samples 8 \
  --analysis-cache warm
```

Results are written under `.benchmarks/` by default, including every phase
profile and an aggregate `summary.json`. Rendered videos are deleted after
measurement unless `--keep-outputs` is supplied. Use `--mode plan` when
iterating on the director and `--mode render` for compositor/encoder changes.
`--analysis-cache warm` measures repeated edits, `cold` removes the cache
before every trial, and `off` bypasses it without deleting the persisted entry.

## Director diagnostics and scenario contracts

Use the native diagnostic overlay when a framing decision needs explanation:

```bash
npm run compose -- artifacts/my-recording --director-debug
```

The output video includes cyan final-attention bounds, red appearance components, blue translated components, yellow pointer evidence, green Accessibility evidence, and magenta visual-response evidence. A sibling `*.director.json` report records every action, source/output time, evidence weight, attention behavior and bounds, episode membership, camera center/scale, shot membership, and classified motion component. `--plan-only --director-debug` writes the same report without rendering video.

The raw motion stream remains deliberately sensitive for waiting reduction and is retained in the JSON report. Camera framing uses a stricter candidate gate: micro-deltas, caret/glyph noise, and coherent viewport translation cannot direct the shot. Pointer actions use one activation-relative response comparison; the older wide snapshot is only a recall fallback when a distinct later response exists, no material activation-relative component survived, and the fallback covers at least 6% of the viewport. This prevents duplicate response boxes while preserving large animated chart changes.

Generalization contracts live in `Fixtures/DirectorScenarios/scenarios.json`. They cover contained modal work, popovers, side panels, chart updates followed by departure, scroll motion, and reveals followed by unrelated actions. `swift test` validates episode membership and shot behavior for every scenario alongside the lower-level motion and camera tests.

Detector development is isolated from camera taste in [`docs/motion-field.md`](docs/motion-field.md). `swift run motion-debug before.png after.png /tmp/example` writes a detector-only overlay and JSON report. Composition tracks focus in interaction order: a dim/blur foreground persists across later actions and backdrop animation until a release or page replacement. `--director-debug` records intermediate field intervals, active-focus geometry, and lifecycle transitions. Backdrop residual motion stays observable but cannot steer framing; factual pointer and Accessibility evidence can still expand the focus decision.

Real captures can be promoted into privacy-local golden plans without committing video or task data to Git. `AGENTRECORDER_STORE=... npm run golden:update -- rec_...` snapshots the stable director decisions inside that recording's project; `npm run test:golden -- rec_...` reruns the native motion prepass and plan, then fails if action provenance, attention bounds, timing source, camera pose, shot grouping, motion classification, or edited duration changes. The implementation was verified against a live two-click Computer Use capture in addition to the synthetic suite.

Every native plan also writes a sibling `*.camera-audit.json`. It samples the exact camera and cursor trajectory used by the renderer and records factual target projection, cursor-hotspot error, visibility, direction reversals, path efficiency, line deviation, and hidden scale excursions. Validate a real Chrome or native-app capture with:

```bash
npm run audit:alignment -- artifacts/my-recording.directed.camera-audit.json
```

The audit fails when a factual click/drag is off-screen, the synthetic hotspot misses the reconstructed target, a camera move reverses direction, a nominal pan contains a zoom pulse, or visual timing falls outside the Computer Use tool/response envelope. Preferred safety-inset misses are warnings; factual visibility is mandatory.

For V2, the audit additionally fails if no hard-constraint-feasible plan exists or if the renderer applies even one emergency visibility correction. This makes the correction path a last-resort safety mechanism rather than a hidden second camera planner.

### Agent waiting time

The director removes visually static agent waiting by default while preserving interaction and visible motion at their natural speed. The default retained still-frame handle is 100 milliseconds; customize it with:

```sh
npm run compose -- artifacts/my-recording --waiting-time 100
```

`--waiting-time` is milliseconds retained per proven-idle gap, split between the last still moment before the cut and the first still moment after it. New recordings persist a capture-truth ledger directly from ScreenCaptureKit. It records WindowServer frame status, display time, damage rectangles, writer acceptance, and an exhaustive comparison of every active raw BGRA byte before encoding. Only consecutive, on-cadence frames that are exactly identical prove idleness. Any changed pixel, dropped frame, callback gap, missing metadata, blank/suspended capture, clock ambiguity, or unavailable sidecar preserves the interval. The downscaled motion model remains editorial evidence for framing and optional acceleration; it cannot authorize deletion. A scroll loses its generic action hold only when its complete causal interval until the next factual action is proven idle. The Computer Use action remains in the timeline regardless. See [`docs/capture-truth.md`](docs/capture-truth.md).

The equivalent environment variables are `AGENTRECORDER_REDUCE_WAITING=1` and `AGENTRECORDER_WAITING_TIME_MS=100`.

Use `--keep-waiting` (or `AGENTRECORDER_REDUCE_WAITING=0`) when a faithful, uncut timeline is needed. The legacy `--reduce-waiting` flag remains accepted for existing scripts.

## Current limitations

- A target must have exactly one eligible on-screen window at recording start. The bundle identifier is carried through preflight, ScreenCaptureKit, Accessibility observation, screenshot-coordinate lookup, and timeline persistence.
- Accessibility sampling backs off adaptively when a native app exposes a slow, very large AX tree, preventing the recorder from continuously contending with Computer Use for the same accessibility server.
- Video time is anchored to the first committed ScreenCaptureKit frame using WindowServer `displayTime`, correcting callback scheduling delay. Action timestamps are still estimated within each Computer Use tool-call duration because the event stream does not expose the exact injection instant; target-local visual timing refines clicks when evidence exists.
- Coordinate clicks and drags use their logged coordinates. Element-index actions use passive role/title/value matching against recorder-side AX snapshots; ambiguous or missing matches fail open without inventing a cursor target.
- A moved or resized target window invalidates direct coordinates for the affected span rather than silently remapping them. The v1 capture does not follow the window mid-recording.
- System-owned foreground surfaces such as open/save or permission panels are not present in application-only capture. The recorder marks those spans and suppresses authoritative pointer reconstruction instead of depicting a click on inert target-app content.
- Camera, cursor, and neighboring source-video frames are temporally sampled together. Optical-flow interpolation is not yet used, so extremely fast source-only animation can still reveal ordinary cross-frame blending.
- The task JSONL and screenshot cache are private Codex implementation seams. Runtime probes, fingerprints, ambiguity handling, and fail-closed coordinate validation isolate their failure, but compatibility still needs continuous corpus coverage as Codex evolves.
- Capture and composition are video-only. Audio must not be added until waiting cuts and speed changes have a track-aware keep/stretch policy.
