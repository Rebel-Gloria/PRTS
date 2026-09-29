# Runtime data flow

## Capture

`ProbeEngine` receives one `ARFrame` and creates a `FrameSnapshot` containing frame ID, epoch, timestamp, tracking state, camera pose, RGB intrinsics, scene depth/confidence availability and mesh priors. A bounded mailbox keeps one processing frame plus the newest pending frame; stale work is discarded.

## Analysis

The worker extracts high-confidence depth points, estimates a local ground plane, validates floor priors and updates the three-state grid (`candidate`, `obstacle`, `unknown`). `PathPredictor` validates session/order, then `ForwardRoutePlanner` retains a forward world reference and selects straight, same-side avoidance/rejoin, or a side route. A small near-field triangle triggers avoidance; it is not a farthest-target selector. A fresh clear new direction held for three seconds permits user redirection. Evidence expiry hides the path but does not automatically select a new target; contradictory ground/metric data invalidates it.

## Presentation

The main actor reads a `SharedSnapshot`. The Metal renderer projects RGB/depth and world-space overlays into one aspect-fit content rectangle. `HomeDemoOverlay` only displays measurements already present in that snapshot. It must not trigger analysis, create a timer or create an ARSession.

## Feedback

`FeedbackCoordinator` rate-limits result-based speech/haptics. `RouteAnnouncementPolicy` gives one cue per avoidance/rejoin stage; obstacle speech takes precedence. `PathHaptics` handles left/right/align target cues. Settings and perception speech have separate cancellation ownership so opening Settings cannot be silenced by a stale perception update.

## Diagnostics

The recorder writes launch metadata, capture/analysis/render/path/mesh events and compressed depth/confidence/mesh attachments. No RGB/video/audio/GPS is written by default. Drop counts, queue high-water marks, result age, thermal state and stage timings are retained for diagnosis.

Route module ownership and evidence rules: [Forward route policy](FORWARD_ROUTE_POLICY.md).

## Rolling route planning

`RoutePlanningGrid` reads the current `AnalysisResult.grid` ground samples directly; no dependency on
rendered `SurfaceModel.triangles`. The original clearance grid is never mutated.
`ForwardRoutePlanner` advances the straight horizon greedily, detects occupied swept-route cells,
and reacquires same-side manoeuvres when an entry or endpoint disappears.
Plane compatibility is evaluated near the current camera, not at a distant old origin.
UI and feedback remain consumers; neither creates another search or capture session.

## build16 route handoff update

Current path: raw clustered hazard → world RouteEvidenceMap → ForwardRoutePlanner → RoutePublicationPolicy → shared display/feedback. See [round-1 contracts and limits](ROUTE_CONTINUITY_2026-09-29.md). Dev compilation/recording does not select planning policy. SurfaceHistory remains display-only.
