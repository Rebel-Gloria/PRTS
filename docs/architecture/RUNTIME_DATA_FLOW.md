# Runtime data flow

## Capture

`ProbeEngine` receives one `ARFrame` and creates a `FrameSnapshot` containing frame ID, epoch, timestamp, tracking state, camera pose, RGB intrinsics, scene depth/confidence availability and mesh priors. A bounded mailbox keeps one processing frame plus the newest pending frame; stale work is discarded.

## Analysis

The worker extracts high-confidence depth points, estimates a local ground plane, validates floor priors and updates the three-state grid (`candidate`, `obstacle`, `unknown`). `PathPredictor` selects and retains a fixed world-space target. Evidence expiry hides the path but does not automatically select a new target; contradictory ground/metric data invalidates it.

## Presentation

The main actor reads a `SharedSnapshot`. The Metal renderer projects RGB/depth and world-space overlays into one aspect-fit content rectangle. `HomeDemoOverlay` only displays measurements already present in that snapshot. It must not trigger analysis, create a timer or create an ARSession.

## Feedback

`FeedbackCoordinator` rate-limits result-based speech/haptics. `PathHaptics` handles left/right/align target cues. Settings and perception speech have separate cancellation ownership so opening Settings cannot be silenced by a stale perception update.

## Diagnostics

The recorder writes launch metadata, capture/analysis/render/path/mesh events and compressed depth/confidence/mesh attachments. No RGB/video/audio/GPS is written by default. Drop counts, queue high-water marks, result age, thermal state and stage timings are retained for diagnosis.
