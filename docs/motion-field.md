# Motion-field detector

The camera must not infer subjects directly from a thresholded frame diff. `NativeDirector.MotionField` is the observational boundary between decoded pixels and editorial policy. It explains materially changed tiles as one of three mutually exclusive channels:

- **structural** — content appeared, vanished, or was replaced;
- **shift** — a connected neighborhood supports one displacement vector;
- **photometric context** — the same content underwent an affine luminance change.

The detector does not decide whether the camera should zoom. It supplies focus-filtered observations to the existing attention director, which combines them with factual pointer and Accessibility evidence.

## Invariants

1. A structural component keeps its tile mask, density, energy, and polarity. Its bounding rectangle is not treated as proof that every pixel inside changed.
2. A shift requires connected support from multiple tiles and a support region at least as large as the claimed displacement. A single repeated glyph cannot match an arbitrary remote glyph and become motion.
3. A broad coherent viewport shift owns the entering edge that has no source pixels. The edge is not emitted as an L-shaped structural component whose bounding box covers the screen.
4. Photometric context is scalar context, not a camera target. Textured seed regions establish the model; flat tiles may then be explained by the same model.
5. A viewport-spanning dim/blur transform is backdrop context. A deterministic consensus fit makes foreground and animated backdrop regions outliers, while sharp residual foreground features establish the focus box.
6. Backdrop residual motion remains in the raw structural report but cannot steer framing while a focus box exists. Factual pointer or Accessibility evidence outside the focus box still expands the camera decision.
7. Focus is an interaction-ordered state, not a property that must be rediscovered in every frame pair. A gained focus remains active through internal and backdrop animation, may grow or move when structural evidence crosses its boundary, releases on the inverse backdrop transition, and invalidates on a full-page replacement.
8. Motion fully contained inside an active foreground cannot collapse the focus box onto a chart, spinner, or typing region. Factual pointer and Accessibility evidence remain independent overrides rather than mutating the tracked focus.
9. Forward and reverse comparisons must preserve focus geometry. Only polarity, shift direction, and focus-gained/focus-released direction may reverse.
10. Analysis tile size scales with raster width, so changing the response-frame resolution does not change normalized component geometry or padding.
11. A click without resolved coordinates still receives an activation-relative full-viewport probe. Missing pointer geometry must not suppress visual focus detection; it only prevents the result from being treated as factual pointer evidence.
12. Camera-policy tuning must not compensate for a detector failure.
13. Multi-frame structural tracks are retained across the entire recording, including intervals with no Computer Use action. Visual persistence is an object proposal, not proof of causal ownership.
14. Global visual-only tracks cannot be retroactively assigned to an earlier action in the same tool-call envelope. Ordered action evidence, semantic containers, and visual-only objects remain separate until global planning compares them.

## Evaluation

The synthetic suite covers dialogs over dimming and blur, persistent focus across animated backdrops, foreground resize and internal animation, page-replacement invalidation, pointer override, focus-release symmetry, flyouts without dimming, inserted content plus local reflow, graph animation, separated subjects, frame reversal, and viewport translation:

```sh
swift test --filter motionField
```

Inspect any real frame pair independently of the composer:

```sh
swift run motion-debug before.png after.png /tmp/example
```

This writes `/tmp/example.overlay.png` and `/tmp/example.motion.json`. Structural bounds are red, coherent shifts are blue, and the focus box is green. Normal composition uses one activation-relative field per interaction. `--director-debug` additionally records intermediate field intervals plus the active focus and its lifecycle transition (`gained`, `held`, `updated`, `released`, or `invalidated`) in the sibling director JSON.

To inspect the loss-preserving field over a recording without involving the
camera planner:

```sh
swift run -c release motion-field-video source.mov /tmp/motion-field.mp4 --fps 6 --analysis-width 320
```

The source is shown on the right. The left side is derived directly from the
current frame pair: structural evidence is red, translation cyan, photometric
change purple, and backdrop transformation blue. Raw sub-threshold change is
retained in the field and JSON report but hidden from the review video. Spatial smoothing exists only in this visualization; there is no
temporal smoothing and the accompanying `*.motion-field.json` records the raw
per-frame counts. The detector retains the exact per-pixel RGB delta and one
mutually exclusive explanation for every analysis tile before any connected
component, object proposal, or camera decision. Dense evidence retention is
off during normal composition, so the diagnostic does not add production
analysis cost.

The diagnostic report also contains experimental `objectTracks`. Dense changed
tiles are first grouped into per-frame connected masks; all plausible temporal
links are then solved together as a maximum-weight path cover. Residual edges
allow an earlier association to be revised, so this is not the previous greedy
"nearest overlapping rectangle" tracker. Every component retains its exact
tile indices, while bounds are derived only for inspection. A long static gap
may join two components only when their spatial support remains strongly
compatible; the track records that gap and its continuity confidence rather
than pretending continuous motion was observed.

To render track identities over the dense-field diagnostic:

```sh
node scripts/render-dense-motion-tracks.mjs \
  /tmp/motion-field.mp4 /tmp/motion-field.motion-field.json \
  /tmp/motion-tracks.mp4
```

Track outlines remain faintly visible across inferred static holds. The exact
component at a sampled time is bright and labeled with its track ID. These
tracks remain experimental evidence and are not consumed by the camera.

The report also partitions complete track lifecycles into experimental
`objectEnsembles`. Every pair in an ensemble must independently agree about
birth and release timing; spatial proximity cannot merge tracks frame by
frame. A compact, sufficiently occupied envelope is labeled `compactObject`.
Synchronized changes spanning the viewport are `broadContext`, while sparse
fragments with shared timing are only `correlatedChange` and are explicitly
not claimed as object geometry. Atomic track masks remain intact in every
case. Render the partition over the source half with:

```sh
node scripts/render-dense-motion-objects.mjs \
  /tmp/motion-field.mp4 /tmp/motion-field.motion-field.json \
  /tmp/motion-objects.mp4
```

Object ensembles remain diagnostic-only and are not consumed by the camera.

For a compact lifecycle with a measured static hold, `objectSurfaces` records a
bidirectional foreground-support veil. The held frame is compared with both
the scene before birth and the scene after release; only support present in
both residuals may define the settled surface. This prevents a moving object's
whole travel path—or an unrelated one-sided page update—from becoming object
geometry. A connected single track is eligible for the same surface inference
as a multi-track ensemble; fragmentation does not determine objecthood.

Low-contrast surfaces that remain present while moving use the separate
`transportTracks` evidence path. It extracts connected local appearance modes
before the material frame-difference threshold, associates their complete
geometry at a higher temporal cadence, and retains only trajectories with
measured displacement, stable rectangular support, and coherent direction.
Changing interior pixels are not identity: a label may change while its
enclosing surface continues to translate. Stationary same-colored surfaces are
rejected. This path does not lower the production motion threshold or alter
the transient-surface veil.

Run a focused transport diagnostic at 24 fps and render its surface identities:

```sh
swift run -c release motion-field-video source.mov /tmp/transport-field.mp4 \
  --fps 24 --analysis-width 320 --start 4 --duration 8
node scripts/render-dense-motion-transport.mjs \
  /tmp/transport-field.mp4 /tmp/transport-field.motion-field.json \
  /tmp/transport-surfaces.mp4
```

The left panel fills the inferred moving appearance surface; the right panel
outlines the same time-varying geometry over the source. Transport tracks are
diagnostic-only and are not consumed by the camera.

Accepted before/held/after support can be audited against all clip-wide motion
and transport evidence without creating new objects from motion:

```sh
node scripts/render-foreground-ownership.mjs \
  /tmp/transport-field.mp4 /tmp/transport-field.motion-field.json \
  /tmp/foreground-ownership.mp4
```

The ownership resolver compares every track with every accepted visible-support
lifecycle and an explicit unowned alternative. Direct provenance is green,
unique retrospective association is cyan, ambiguity is yellow, and accepted
visible support is magenta. Motion that has no colored owner remains visible in
the underlying field. Close competing hypotheses abstain; motion cannot create
support, lifecycle birth/release timestamps are immutable, crossing lifetimes
are allowed, and this diagnostic is not consumed by the camera.

For object/subject diagnosis, use `--object-detection-debug`. It includes the
same evidence and ownership overlays but renders them through a fixed overview
camera. The real planner and audit still run, but camera motion and camera
ownership overlays are disabled in the diagnostic video. The object-only overlay no longer includes the legacy
subject graph, camera ownership, or raw observation layers. Semantic object
candidates are blue, supported visual objects are orange, unsupported visual
births are red, and factual trigger evidence remains yellow. Every candidate is
shown only during its own evidence range, never merely because its containing
episode is active.
The object-only view uses the normal analysis cache and omits the larger raw
per-action field dump; use `--director-debug` when that lower-level report is
required. This prevents camera motion from being mistaken for a detector error
and never changes production composition behavior.

Every experimental plan also writes a sibling `*.object-births.json`. Its
declarative invariant is that each visually sourced object must have
spatially-overlapping motion evidence at its declared birth. To create a raw
before/after/difference review for every failure:

```sh
node scripts/render-object-birth-blame.mjs source.mov render.object-births.json /tmp/object-blame
```
