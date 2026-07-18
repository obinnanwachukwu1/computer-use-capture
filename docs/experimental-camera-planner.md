# Global camera scheduler: subjects, shots, and continuous trajectories

The global scheduler is the production camera default. Camera direction is expressed in persistent visual subjects and time-spanned shots, not as a sequence of independently optimized action poses.

The previous action-local planner remains available through `--legacy-camera-planner` as a bounded rollback and comparison control.

## Ownership

```text
capture and Computer Use facts
        ↓
ProductionPlanGraph
  timing and causal alternatives
  structural observations and focus lifecycles
        ↓
SubjectGraph
  persistent surfaces
  factual targets
  scene transitions
  localized response subjects
        ↓
ShotSchedule
  overview / frame / orient / push-in spans
  one emphasis decision per subject span
        ↓
ExperimentalCameraPlanner
  action-response crop audit + bounded replan
  continuous camera tracks
  hard factual-visibility projection
        ↓
NativeComposition adapter → renderer + audit
```

The layers have deliberately different contracts:

- Perception reports scene facts. A context transition no longer means "force overview" and a motion component does not directly create a zoom.
- `SubjectGraph` says what persists, where it is, and which actions belong to it. Verified focus lifecycles remain hard ownership facts. All other contiguous action intervals coexist as episode hypotheses until a clip-level partition selects the most coherent cover; no action is greedily committed to the preceding subject. Transition-local motion geometry is retained as competing diagnostic hypotheses, not promoted to subject identity or camera authority.
- `ShotSchedule` decides whether a subject is worth emphasizing once for its full span. Nearby actions on the same subject cannot each manufacture another zoom pulse.
- `ExperimentalCameraPlanner` turns the schedule into a trajectory. Visibility enforcement is a hard projection over that trajectory, represented by explicit sampled tracks rather than renderer-only emergency corrections.

## Editorial invariants

The experiment treats these as structural rules rather than tunable local preferences:

- every factual click, drag, and semantic input interval is visible;
- Computer Use ordering is preserved;
- a camera move follows one continuous path and cannot jump between hidden poses;
- a persistent subject receives at most one framing decision for its span;
- a full-viewport transition establishes context before a localized response push-in;
- response motion is evidence for a response subject, not permission to chase every changed pixel;
- a material localized response that is exclusive to one action cannot be cropped by the selected trajectory; the safety pass may only preserve the chosen center and zoom out;
- readability gains must repay a move before an optional close-up is scheduled.
- a completed unresolved-opener → later-factual-target interval is an evidence-defined episode boundary; nearby earlier activity cannot absorb it merely through spatial overlap;
- equivalent evidence must produce equivalent subject framing after translation, waiting, or insertion of unrelated prior activity.
- an explicit ordered scroll owns the viewport through the next action boundary; offline knowledge of the following subject cannot start a close-up while that subject is still entering the frame.

Optional attention is not allowed to enlarge a completed episode when stronger localized or factual geometry exists. An unresolved action between grounded endpoints remains owned by that episode without being assigned invented coordinates. This lets typing stay focused even when it produces no independently detectable structural motion.

The final visibility projection runs to a fixed point because adding a smooth shoulder for one factual interval can cross another interval. The emitted audit must report a feasible plan and zero emergency visibility corrections.

Action-aligned response hypotheses do not create subjects, choose centers, or add camera beats. After the normal global schedule is compiled, a coverage audit checks the actual response-time trajectory. Only localized, action-exclusive hypotheses in the near-optimal evidence set may veto a crop. If one fails, the scheduler runs once more with a scale-only constraint; weak background fragments, unowned motion, and diffuse scene-scale fields remain optional. The final trajectory is rejected if the response is still cropped.

## Clip-global readability search

Shot selection is a bounded clip-wide search over overview and readable poses. The objective is the accumulated readability improvement minus the costs of the camera edges the selected trajectory actually emits. It does not guess that every subject will require two moves, and it does not charge scale or translation once while choosing a pose and again while accepting it.

This distinction lets several nearby short interactions repay one shared entry move while unrelated short targets still lose when they require separate travel. A locally negative entry remains in the beam long enough for a later hold or direct handoff to repay it. Verified releases, context transitions, and overview constraints remain explicit events, so their real return or handoff edges are included in the same objective.

The experimental plan serializes `shotScheduleObjectiveValue` and each selected shot's gross `readabilityValue`. An overview shot reports zero readability rather than the negative value of an unselected candidate.

## Overview-blame diagnostics

Every `requiresOverview` constraint carries an `overviewBlame` chain. It records the action, broad action-aligned observation IDs and weight, localized response IDs and weight, broad motion already underway before activation, and the exact veto reason. The same data is written beside every plan as `<output>.overview-blame.json`.

Render the focused diagnostic with a fixed camera:

```sh
npm run compose -- artifacts/my-recording --overview-blame-debug
```

The overlay intentionally excludes the ordinary director layers:

- yellow: factual subject bounds;
- red: broad response considered action-aligned by onset;
- green: localized action response;
- blue: broad motion already underway before activation.

This report describes the current causal claim; it does not strengthen it. In particular, `causalBasis: broad-onset-within-action-clock-window` makes clear that broad negative evidence is presently associated through onset timing rather than exclusive causal attribution.

## Response-coverage diagnostics

Every plan also writes `<output>.response-coverage-blame.json`. It preserves all clustered action-response hypotheses and records their causal ownership, relative signal, projected visibility, and whether they had enough authority to veto a crop. Applied constraints are serialized in `.experimental-plan.json` under `responseCoverageConstraints`.

This is a negative safety mechanism only. It never identifies a toast, menu, modal, or other UI role; it never moves the camera toward motion. A response can cause a replan only when it is localized, contains action-owned evidence, remains within 80% of that action's strongest response signal, and is less than 98% visible in the preliminary trajectory. Diffuse fields stay with the separate overview inference path.

## Current architecture boundary

The experiment currently reuses the normal planner's fixed-point timing, causal attribution, and global retime selections. It does **not** reuse the normal planner's camera moves or action-pose policy. This keeps the first comparison controlled: identical event timing and edited duration, different planning vocabulary and trajectory.

Timing and causal selection remain in a camera-neutral evidence resolver. Keeping that boundary explicit prevents the scheduler from becoming a wrapper around two competing camera owners.

## Audit and comparison

Plan without rendering:

```sh
npm run compose -- artifacts/my-recording \
  --plan-only --director-debug
```

The flag adds `.experimental-plan.json` beside the existing director, production-plan, and camera-audit reports. It records inferred subjects, transitions, scheduled shots, ordinary moves, continuous tracks, and factual/tracking sample counts.

Compare the legacy and global implementations on the standard fixtures:

```sh
npm run compare:experimental
```

Or pass capture bases explicitly:

```sh
node scripts/compare-camera-plans.mjs \
  --planners normal,experimental artifacts/native-alignment-rig
```

The global scheduler was promoted only after fresh held-out captures improved editorial correctness and reduced travel without factual, causal-order, continuity, or emergency-correction regressions. Future changes remain subject to the same gate.
