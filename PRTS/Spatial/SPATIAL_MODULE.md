# Spatial runtime

This directory is the app-side adapter around `Vendor/SpatialCore`.

- `Runtime/` owns ARKit lifecycle, the bounded mailbox, Core ML fallback and state snapshots.
- `Rendering/` owns Metal texture conversion and world-space projection. It consumes snapshots only.
- `Diagnostics/` records scalar metadata and compressed spatial attachments. It never stores RGB by default.
- `Models/` contains the optional no-LiDAR model and its provenance/license files.

Do not put geometry policy in the renderer or UI. Add geometry decisions to `Vendor/SpatialCore` with deterministic tests first.
