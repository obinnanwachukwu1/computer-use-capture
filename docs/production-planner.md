# Production planner

This is the normal and default camera path: one clip-wide inference problem rather than locally staged direction.

## Ownership

The intended single owner is:

```text
lossless observations
        ↓
ProductionPlanGraph
  timing alternatives
  causal attribution alternatives
  foreground lifecycles
  attention alternatives
        ↓
ProductionPlanner
  clip-wide beam over actions
  activation pose + response pose
  camera trajectory
        ↓
GlobalRetimePlanner
  one evidence partition for the clip
        ↓
NativeComposition adapter → renderer + audit
```

The adapter exists because cursor interpolation, source/output time mapping, rendering, and validation already consume `NativeComposition`. It contains no inferred shots. Its earlier local attention, shot, and retime choices are replaced by the global selections before rendering.

## Evidence is not a decision

`ProductionPlanGraph` is immutable and keeps competing interpretations:

- interaction timing from selected target activity, raw telemetry, tool completion, and every eligible visual activity cluster;
- causal attribution from each structural observation to every plausible action, plus an ambient/null cause;
- factual pointer and accessibility bounds;
- structural visual regions;
- foreground surfaces that persist from appearance/focus gain through release;
- separate activation and response attention hypotheses.

Exact duplicate interpretations are removed, but alternatives are not collapsed merely because they are spatially close. The bounded top-K and beam widths make the search approximate and deterministic; they are explicit resource limits rather than hidden greedy policy.

## Global objective and invariants

The solver scores a path across the full ordered action sequence. A decision contains the chosen timing, causal/attention hypothesis, arrival pose, response pose, and cumulative cost. Costs cover camera travel, zoom travel, move count, reversal, zoom churn, attention coverage, centering, scale taste, timing discontinuity, and unexplained structural observations.

These are hard constraints:

- a selected activation cannot precede a completed observed hover/arrival cluster;
- pointer arrival cannot occur after activation;
- all factual click and drag targets must be visible at their required times;
- the complete factual cursor route must remain visible throughout each proposed camera edge;
- camera moves cannot overlap and every move is a single straight pose interpolation;
- Computer Use action order cannot be reversed by independently inferred activation times;
- semantic input framing settles before the renderer's factual visibility interval begins;
- if a held shot excludes the synthetic cursor's next factual departure, an establishing pointer-reveal pose contains both ends before travel begins;
- persistent surface evidence may maintain framing but may not claim causality for the surface's birth observation.
- a full-page context transition must resolve to an establishing overview pose; future nearby work cannot trade that orientation beat away to reduce camera travel.
- every detected full-page context transition must be causally covered by the selected clip-wide path; paying an unexplained-motion cost is not an allowed substitute.

Activation and response are distinct beats. A click may be framed in the current context while the resulting dialog, panel, graph, or page becomes the response pose. Closing a foreground surface can select an overview response without inventing an intermediate shot boundary.

## Retiming

`GlobalRetimePlanner` partitions source time once using all globally selected actions and all detected motion ranges. Action intervals remain 1x. Ambient UI motion is retained and may use the configured dead-time rate. Only static intervals are candidates for waiting reduction. It does not progressively edit gaps around one action at a time.

Because retiming changes camera scheduling and selected timing changes retiming, the CLI runs a bounded fixed-point iteration and emits the final stable decision set. The iteration count is diagnostic and not an additional policy layer.

## Audit and comparison

Plan without rendering:

```sh
npm run compose -- artifacts/my-recording --plan-only
```

The normal planner writes:

- `.director.json`: renderer-facing resolved actions, attention, and retime;
- `.camera-audit.json`: the exact sampled trajectory, factual alignment, and emergency correction count;
- `.production-plan.json`: selected timing and attention hypothesis IDs, observation ownership, activation/response poses, camera moves, and cumulative costs.

Compare the normal and experimental planners on both standard fixtures:

```sh
npm run compare:experimental
```

Or choose any planner set and fixture bases:

```sh
node scripts/compare-camera-plans.mjs --planners normal,experimental artifacts/native-alignment-rig
```

The normal planner must pass the factual alignment gate with zero renderer visibility corrections on fresh web/native captures and the deterministic fixture set. Default promotion does not delete the controls: prefer deleting an old component only after its remaining renderer/data contract has moved to a neutral type.

## Current boundary

This is not yet a fully end-to-end learned scene model. The bundled Swift motion analysis produces raw timing activity and motion ranges, while `NativeComposition` remains a compatibility substrate for event normalization and rendering facts. Those boundaries are deliberately called out so production success is not confused with completion of the whole migration.
