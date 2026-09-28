# PRTS iOS application

This directory contains the product target. The target is intentionally organized by responsibility rather than by feature screen.

## Boundaries

- **App** — application composition and runtime profile declarations.
- **UI** — the restored product home screen, settings pages and presentation-only overlays.
- **Capture** — the home-screen adapter and camera surface. It does not own a second camera session.
- **Feedback** — speech, haptics and result-to-feedback policy.
- **Integration** — compatibility seams for future semantic detectors or backend providers.
- **Spatial/Runtime** — ARSession ownership, frame mailbox, analysis orchestration and runtime snapshots.
- **Spatial/Rendering** — Metal RGB/depth/world overlay rendering only.
- **Spatial/Diagnostics** — launch diagnostics and manual spatial sample export.
- **Spatial/Models** — bundled Core ML artifacts and provenance metadata.

`Vendor/SpatialCore` is the pure-Swift spatial algorithm package. It has no SwiftUI, ARSession or Metal dependency. `Vendor/PRTSCore` remains an optional contracts/model compatibility package and is not a prerequisite for the offline geometry loop.

## Data flow

```text
ARSession
  -> Capture/ProbeEngine frame mailbox
  -> SpatialCore analysis + path prediction
  -> Runtime snapshot
       ├── Spatial/Rendering/ProbeRenderer (visuals)
       ├── Feedback/FeedbackCoordinator + PathHaptics (audio/haptics)
       └── Spatial/Diagnostics (JSONL + compressed measurements)
```

The home screen and the presentation overlay consume the same runtime snapshot. Hiding RGB, overlays or metrics changes presentation only; it does not stop capture or analysis.
