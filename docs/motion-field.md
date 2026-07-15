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
