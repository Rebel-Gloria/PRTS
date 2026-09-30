# SpatialCore provenance

Selected pure-Swift spatial analysis files were copied from the adjacent validation project
`/Users/yuanyuan/Desktop/Prts/PRTSTEST/Core` on 2026-09-25. Recording, export, diagnostic UI,
and probe renderer code were intentionally not copied. The tiny `AppendFile` primitive is retained only to keep the
original 25-test package suite intact; the PRTS app does not call it.

Original SHA-256 values (from `PRTSTEST/Reports/source-sha256.json`):

- `Analysis.swift`: `f6b7fe6075d407e598600b9d11972d8de2526e90390d99ffbf9ff03edd5da8e7`
- `Depth.swift`: `fecff01ec16e3f76af65d2ce4d8a7a28d21c1156a51faf4d623aa4eae6d477f7`
- `Geometry.swift`: `8937c2acf906b3cc9aa50f72fb9ac04ad6ae5b242dccd9bbb9e99b896690f7ae`
- `Grid.swift`: `68091b1b23770273e5569988865d06f00bd0bcab3ea75e71f0dc4b28b04264c8`
- `Ground.swift`: `8deecf60b38fe15cecfa0014f01389989d894d29544991b99386651739120540`
- `AppendFile.swift`: `a447a4ef0a34eb2dab34594cd51083e4ee952e64728b057c79f29285c02f0a68`
- `SpatialCoreTests.swift`: `dad66e54b1348d7931664c9f3d046d80c4ad55d8d70609bf0d28441ba405344f`

PRTS adds `SceneContracts.swift` and `FeedbackPolicy.swift`. The copied algorithm behavior is kept unchanged; `Grid.swift` only adds synthesized `Hashable` conformances
for `CellState` and `Sector` so they can be stable contract identifiers. Original synthetic behavior remains directly comparable.

## Main-only route evolution (2026-09-29)

The original hashes above are historical provenance, not hashes of the current package.
`PathPrediction.swift` is now a stable facade over `ForwardRoutePlanner`; the new `Forward*`
helpers implement forward-first routing, a near-field trigger, same-side avoidance/rejoining,
and continuous user-turn dwell. `FanPathSearch` adds explicit-root and constrained-search inputs;
its default graph-search behavior and `PathClearance` collision mathematics retain regression coverage.
`PathObstacleCheck` extracts the existing current-depth veto and supports sample clusters straddling
cell boundaries. It also vetoes newly generated routes. No original experiment files were overwritten.

See [forward route policy](../../docs/architecture/FORWARD_ROUTE_POLICY.md) for contracts and limitations.
All new route-policy tests use synthetic inputs; physical-device acceptance is still pending.

## 2026-09-29 evening route evolution

Added RoutePlanningGrid (current measured ground evidence, independent of rendered triangles),
rolling straight horizons, swept-route preview triggers, nearest-component selection, same-side
entry reacquisition, and locally evaluated plane compatibility. PathClearance collision math and
the sensor/ground estimator remain unchanged. Updated synthetic fixtures to include actual
ground evidence and changed only explicitly superseded fixed-goal/one-metre-trigger expectations.
See docs/architecture/ROUTE_REPLAY_2026-09-29.md in the main repository for sampled replay limits.

2026-09-29 projection layer: RouteProjection adds visual-only planar extrapolation on the
current 2D occupancy grid. PathDrawing now shares ribbons with a distinct prediction role.
The frozen experiment remains unchanged. PathUpdate stores an optional backward-compatible
projection; measured routes, goals and feedback continue to use their existing evidence.

Build 14 adds explicitly opt-in experimental occupancy planning for Dev Capture builds:
TemporalOccupancyGrid (300ms world-position persistence), GreedyDetourSearch and independent
filter diagnostics. Normal builds retain the evidence-aware route policy. Raw sensor/grid
records are never overwritten by the hypothetical planning raster.

World-route lock follow-up: Dev routes keep their reference plane, endpoint and bends when
the camera-aligned raster moves away; confirmed occupancy still vetoes. Rendering uses
solid approach/history in this mode. Normal routes retain their evidence policy.
See docs/architecture/WORLD_ROUTE_LOCK_2026-09-29.md for the compact-grid replay limitation.

## Build25 geometry correction (2026-09-30)

`AnalysisResult` gains an optional planning-only `planningObstacles` payload; the
`SpatialAnalyzer` implementation remains identical to the frozen experiment (parity test
strips exactly that field declaration, not the analyzer). `OccupancyFootprint` separates
current measured cell area from its temporal association anchor. Collision checks retain
world footprints even outside a rotated search window. No original experiment is edited.
`WaypointTransitionState` adds product-state hysteresis, without changing the 300ms
obstacle admission rule. See `docs/architecture/WAYPOINT_STABILITY_2026-09-30.md`.
