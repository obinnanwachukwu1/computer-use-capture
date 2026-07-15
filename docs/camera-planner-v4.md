# Camera planner V4: subjects, shots, and continuous trajectories

V4 is a staged replacement for the action-beat camera model. It implements the architectural correction from the external design review: camera direction is expressed in persistent visual subjects and time-spanned shots, not as a sequence of independently optimized action poses.

V3 remains the production default while V4 is compared on fresh captures and the frozen corpus.

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
CameraPlannerV4
  continuous camera tracks
  hard factual-visibility projection
        ↓
NativeComposition adapter → renderer + audit
```

The layers have deliberately different contracts:

- Perception reports scene facts. A context transition no longer means "force overview" and a motion component does not directly create a zoom.
- `SubjectGraph` says what persists, where it is, and which actions belong to it. It groups actions by focus lifecycle or a bounded spatiotemporal union and preserves transition responses separately.
- `ShotSchedule` decides whether a subject is worth emphasizing once for its full span. Nearby actions on the same subject cannot each manufacture another zoom pulse.
- `CameraPlannerV4` turns the schedule into a trajectory. Visibility enforcement is a hard projection over that trajectory, represented by explicit sampled tracks rather than renderer-only emergency corrections.

## Editorial invariants

V4 treats these as structural rules rather than tunable local preferences:

- every factual click, drag, and semantic input interval is visible;
- Computer Use ordering is preserved;
- a camera move follows one continuous path and cannot jump between hidden poses;
- a persistent subject receives at most one framing decision for its span;
- a full-viewport transition establishes context before a localized response push-in;
- response motion is evidence for a response subject, not permission to chase every changed pixel;
- readability gains must repay a move before an optional close-up is scheduled.

The final visibility projection runs to a fixed point because adding a smooth shoulder for one factual interval can cross another interval. The emitted audit must report a feasible plan and zero emergency visibility corrections.

## Current migration boundary

V4 currently reuses V3's fixed-point timing, causal attribution, and global retime selections. It does **not** reuse V3's camera moves or action-pose policy. This keeps the first comparison controlled: identical event timing and edited duration, different planning vocabulary and trajectory.

Once V4 wins across the corpus, timing and causal selection should move into a camera-neutral evidence resolver. Only then should V3 policy code be removed. Keeping that boundary explicit prevents V4 from becoming a wrapper around two competing camera owners.

## Audit and comparison

Plan without rendering:

```sh
npm run compose -- artifacts/my-recording \
  --camera-planner v4 --plan-only --director-debug
```

V4 adds `.v4-plan.json` beside the existing director, production-plan, and camera-audit reports. It records inferred subjects, transitions, scheduled shots, ordinary moves, continuous tracks, and factual/tracking sample counts.

Compare V3 and V4 on the standard fixtures:

```sh
npm run compare:v4
```

Or pass capture bases explicitly:

```sh
node scripts/compare-camera-plans.mjs \
  --planners v3,v4 artifacts/native-alignment-rig
```

Promotion requires more than a lower aggregate travel score. Review the actual renders for subject continuity, orientation, readable emphasis, response timing, and pulse count. Factual validation must pass with zero emergency corrections on every candidate.
