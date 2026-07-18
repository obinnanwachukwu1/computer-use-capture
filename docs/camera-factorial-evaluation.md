# Camera foreground-support evaluation

This evaluation asks one narrow question before a production depth estimator is built: does perfect visible foreground support improve final camera decisions?

The four conditions isolate geometry from objective semantics:

- `a-current`: current detector and current objective.
- `b-optional-motion`: current detector; ordinary appearance and transformation are optional editorial evidence.
- `c-oracle-current`: manually annotated foreground support under the current objective.
- `d-oracle-gated`: oracle support plus optional editorial motion and foreground gating.

Production behavior is unchanged. These conditions are available only through explicit compose flags and are not exposed by the MCP.

Every condition uses A's resolved action timing, response timing, retiming, and waiting cuts. B/C/D may change only attention interpretation and camera trajectory. B and D both treat ordinary editorial motion as optional globally; D additionally uses high-confidence foreground support to gate competing motion while that support owns the scene.

## Fixture contract

Oracle fixtures use normalized top-left source-window coordinates and visible support bounds. They must not label UI types, infer hidden pixels, or alter factual Computer Use events. `abstained: true` records an intentionally unlabeled interval without injecting evidence.

Camera annotations describe desired shots at factual action beats. Mark each baseline beat `acceptable`, `bad`, or `ambiguous`; this lets the report count corrections separately from regressions. The example files in `Fixtures/CameraEvaluation` document both schemas.
Use `sampleOutputOffset` for a post-response judgment (typically `0.5`–`0.75` seconds). Factual click visibility is always audited separately at activation and cannot be weakened by this offset.

Use `frame-subject` only when the subject warrants an editorial reframe; it
checks visibility, shot scale, and centering. Use `keep-visible` when a brief or
peripheral subject must remain on screen but does not independently justify a
camera move. It checks visible fraction and any explicitly supplied scale
bounds without imposing centering or a default zoom. This distinction prevents
the evaluator from rewarding an unreadable punch-in merely because verified
support exists.

## Run

```sh
npm run evaluate:camera -- /path/to/recording-base \
  --oracle /path/to/oracle-support.json \
  --annotations /path/to/camera-annotations.json
```

The default is plan-only, which reuses the motion-analysis cache and produces camera audits quickly. Add `--render` to create all four videos for a blind preference review. Add `--skip-run` to rescore existing artifacts after editing annotations.
Use `--director-debug` for frame-level evidence and ownership diagnostics. In
experimental renders, thin red/blue/purple boxes are raw detector output,
violet is injected verified support, orange is an active inferred subject,
thick cyan is the subject that actually owns the selected shot, and white is
that shot's target viewport. Legacy per-action attention is never labeled cyan
when the experimental scheduler owns the camera.

The JSON and Markdown reports include beat correctness, false emphasis, regressions on acceptable baseline beats, factual visibility violations, emergency corrections, full action-window continuity violations, move count, added moves per minute, and travel relative to A. A sampled pose cannot hide a scale reversal, path reversal, or inefficient trajectory elsewhere in the action window. Deterministic metrics are a regression gate; final adoption still requires blind camera-level preference review.

## Accepted editorial baseline

`Fixtures/CameraEvaluation/editorial-baseline-v1` freezes the first blind-reviewed
result judged equivalent to a good manual Screen Studio edit. It is a behavior
target, not a claim that the automatic detector already recovers perfect support:
the accepted reference uses condition D with verified visible-surface geometry.

Changes to subject inference or shot scheduling must retain its 12/12 annotated
beats, six-or-fewer camera moves, and zero false-emphasis, factual, and continuity
violations. The focused Swift tests also encode the two non-local taste rules that
completed this baseline: causal anticipation of transient surfaces and minimum
intervention for nested surfaces that already fit their parent shot.

A condition passes the deterministic gate only if its annotations cover the
recording's final action, it improves the number of correct beats, adds no
false emphasis, regresses at most one acceptable baseline beat, has zero
factual, causal-ordering, emergency-visibility, and trajectory-continuity
violations, travels no more than 1.25× A, and adds no more than two moves per
minute. A passing plan is eligible for blind review; it is not automatically a
production winner.

## Production-evidence bake-off

The factorial fixture answers whether verified foreground support would be
useful. It does not prove that production evidence can recover that support.
Before promoting a planner, compare it across distinct recordings with no
oracle file supplied to either variant:

```sh
npm run evaluate:camera-bakeoff -- /path/to/manifest.json
```

The version 1 manifest contains `recordings[]`; each entry requires `id`,
`normalAudit`, and `experimentalAudit`, with optional `kind` and `annotations`.
Paths are resolved relative to the manifest. The command writes adjacent JSON
and Markdown reports containing per-recording and aggregate structural metrics.

At minimum, the corpus should cover browser and native surfaces, nested
transients, scrolling, form entry, and a remote visual response. Structural
improvements such as fewer moves, less travel, and zero continuity violations
are necessary but insufficient. Unannotated recordings require side-by-side
review, and a missed or cropped meaningful response blocks promotion even when
the experimental planner is smoother. Do not repair such failures by allowing
ordinary motion or verified support alone to force a camera move; first
determine whether the production subject graph contains enough factual evidence
to justify the shot.
