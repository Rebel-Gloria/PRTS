# Runtime data flow

## Capture

`ProbeEngine` receives one `ARFrame` and creates a `FrameSnapshot` containing frame ID, epoch, timestamp, tracking state, camera pose, RGB intrinsics, scene depth/confidence availability and mesh priors. A bounded mailbox keeps one processing frame plus the newest pending frame; stale work is discarded.

## Analysis

The worker produces the measured three-state grid (`candidate`, `obstacle`, `unknown`).
`PathPredictor(policy: .obstacleVeto)` then adapts a **private** planning copy through
`TemporalOccupancyGrid`: 300 ms confirmed occupancy vetoes cells; every other cell is searchable.
This copy uses a session-fixed plane and retained route axis with a rolling 8 m forward window.
Missing ground/depth/grid data and evidence TTL do not withdraw the route. If no initial floor
reference exists, drawing starts on a horizontal plane 1.4 m below the initial camera.

Confirmed conflicts raise a watermark and preempt the conflicting committed route before search.
`ForwardRoutePlanner` retains its existing greedy extension, greedy detour and graph-search fallback.
Normal replacements commit atomically; unfinished candidates keep the old route. A clear new
heading held 3 seconds allows user redirection. Epoch, ordering, explicit reset and tracking checks
remain active; recording does not select a different policy.

## Presentation

The main actor reads a `SharedSnapshot`. The Metal renderer projects RGB/depth and world-space overlays into one aspect-fit content rectangle. `HomeDemoOverlay` only displays measurements already present in that snapshot. It must not trigger analysis, create a timer or create an ARSession.

## Feedback

`FeedbackCoordinator` rate-limits result-based speech/haptics. `RouteAnnouncementPolicy` gives one cue per avoidance/rejoin stage; obstacle speech takes precedence. `PathHaptics` handles left/right/align target cues. Settings and perception speech have separate cancellation ownership so opening Settings cannot be silenced by a stale perception update.

## Diagnostics

The recorder writes launch metadata, capture/analysis/render/path/mesh events and compressed depth/confidence/mesh attachments. No RGB/video/audio/GPS is written by default. Drop counts, queue high-water marks, result age, thermal state and stage timings are retained for diagnosis.

Route module ownership and evidence rules: [Forward route policy](FORWARD_ROUTE_POLICY.md).

## Rolling route planning

The facade advances a bounded arc-progress window, preserves the world prefix, and appends the
straight tail without waiting for a local endpoint arrival. Renewal uses the existing speed/budget
heuristic. Grid query bounds are computational limits; they move with the user, not an evidence
frontier. `SurfaceHistory` never supplies planning permissions.

`RoutePlanningGrid`/`PathClearance` consume the adapted raster; their generic candidate checks
therefore impose only confirmed occupancy plus the configured route width and query bounds.
The explicit `.verified` policy remains available for offline comparison, not the app default.

Display and feedback read the same committed `PathUpdate`. The main veto route is solid with
no evidence-expiry or endpoint-arrival hiding. Sensor surface layers retain their own raw-data
checks; those checks do not hide the main route.

See [build17 contracts, tests and limits](OBSTACLE_VETO_2026-09-29.md).

## build18 heading query and tail update

`TemporalOccupancyGrid.projected` reuses confirmed world tracks to query the user's new
heading without ingesting observations twice. `ForwardTurnDwell` uses projected-heading
stability rather than the capture-wide pitch/angular-speed gate. It accepts normal 2 Hz
intervals; epoch/tracking invalidation still belongs to the runtime.

Straight extension tests a full swept segment, then bisects only if occupied.
`RouteArc.coalescingCollinear` removes redundant rolling nodes without changing the curve.
Side-route tails extend along their terminal tangent before arrival; local goals no longer
clear the product route. Details: [build18](TURN_TAIL_2026-09-29.md).
