# PRTS code structure

Generated/maintained on 2026-09-29. Paths below are relative to the repository root.

```text
PRTS/
├── App/
│   ├── PRTSApp.swift                 # Composition root and shared services
│   └── RuntimeProfile.swift          # Offline runtime profile declaration
├── UI/
│   ├── ContentView.swift             # Product home screen
│   ├── HomeDemoOverlay.swift         # Read-only metrics/legend overlay
│   ├── DemoOptionsView.swift         # Home presentation switches
│   ├── SettingsView.swift            # Product settings shell
│   ├── ProbeSettingsView.swift       # Advanced spatial settings and export
│   └── Localization.swift            # Speech/UI language selection
├── Capture/
│   ├── CameraManager.swift           # Main-actor adapter; no second ARSession
│   └── CameraPreview.swift            # Shared Metal camera surface
├── Feedback/
│   ├── FeedbackCoordinator.swift     # Result → speech/haptic policy
│   ├── RouteAnnouncementPolicy.swift # One cue per avoidance/rejoin stage
│   ├── SpeechManager.swift            # TTS ownership and cancellation
│   ├── HapticManager.swift            # General UI/obstacle haptics
│   └── PathHaptics.swift              # Fixed-target direction haptics
├── Integration/
│   └── PRTSBackendBridge.swift        # Future detector/provider boundary
├── Spatial/
│   ├── Runtime/
│   │   ├── ProbeEngine.swift          # Single ARSession and bounded pipeline
│   │   ├── ProbeViewModel.swift       # Main-actor runtime presentation state
│   │   ├── Snapshots.swift             # Frame/result/render state models
│   │   ├── CoreMLDepthModel.swift      # Core ML model loading
│   │   └── MonocularDepthProvider.swift# No-LiDAR depth branch
│   ├── Rendering/
│   │   ├── ProbeRenderer.swift         # Metal rendering only
│   │   └── ProbeShaders.metal.txt      # Image/depth shader source
│   ├── Diagnostics/
│   │   ├── DiagnosticRecorder.swift    # Automatic launch diagnostics
│   │   └── SessionRecorder.swift       # Manual spatial sample recording
│   ├── DevCapture/                     # Compiled only with PRTS_DEV_CAPTURE
│   │   └── DevCaptureRecorder.swift     # Optional low-rate RGB + sensor evidence
│   └── Models/                         # Model files and provenance
└── Assets.xcassets/

Vendor/
├── SpatialCore/                        # Pure Swift geometry and path algorithms
│   ├── Sources/SpatialCore/
│   │   ├── PathPrediction.swift         # Public path contracts, order/session facade, presentation
│   │   ├── ForwardRoutePlanner.swift    # Straight/avoid/rejoin/user-turn state machine
│   │   ├── RoutePlanningGrid.swift     # Current measured ground support, independent of rendering
│   │   ├── ForwardRouteState.swift      # World reference, diagnostics and turn dwell
│   │   ├── ForwardObstacleTrigger.swift # Near triangle and occupied-component extent
│   │   ├── ForwardPathSearch.swift      # Straight trace, return and side-route searches
│   │   ├── FanPathSearch.swift          # Shared graph search and footprint collision checks
│   │   ├── PathObstacleCheck.swift      # Current grid/depth veto for every route
│   │   └── …                            # Existing ground/depth/grid/diagnostic algorithms retained
│   └── Tests/SpatialCoreTests/
└── PRTSCore/                           # Optional contracts/model compatibility

docs/                                   # Design, validation and release notes
scripts/                                # Validation, DIAG reading and maintenance tools
Experiments/SpatialProbe/               # Standalone validation application snapshot
```

## Ownership rules

1. `ProbeEngine` is the only owner of the live `ARSession`.
2. `SpatialCore` owns geometry decisions; it must not import UI, ARKit or Metal.
3. `ProbeRenderer` consumes snapshots and never decides whether a cell is traversable.
4. Feedback consumes accepted results; it must not read camera buffers directly.
5. Diagnostics observe scalar metadata and bounded spatial attachments; they never save RGB by default.
6. The home screen may hide presentation layers, but must not stop capture or analysis as a side effect.

The source layout is checked by `scripts/test_spatial_integration.py`. The test also verifies that presentation overlays do not create a second `ARSession` or timer and that the legacy product-home controls remain present.

## Forward-route extension

The 2026-09-29 strategy adds helpers inside the existing modules; no existing directories were moved.
`PathPredictor` remains the runtime entry point. The policy, diagnostic schema and synthetic/physical validation boundary are in [Forward route policy](FORWARD_ROUTE_POLICY.md).

### 平面预测扩展
`SpatialCore/RouteProjection.swift` 负责二维占用截断与视觉预测；
`PathDrawing` 生成独立虚线。App 的 Snapshot/Renderer 只负责展示，Feedback 不读取预测线。
详见 [ROUTE_PROJECTION.md](ROUTE_PROJECTION.md)。

### Route continuity additions (build16)

Within existing `Vendor/SpatialCore`: `RouteEvidenceMap.swift` owns world-indexed evidence and proof intervals; `RouteContinuity.swift` owns atomic publication decisions, proof expiry and bounded arc progress. `PathPredictor` integrates them on the existing serial analysis worker. No new parallel runtime, package or camera session. [Contracts](ROUTE_CONTINUITY_2026-09-29.md).
