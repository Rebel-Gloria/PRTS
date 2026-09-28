# PRTS code structure

Generated/maintained on 2026-09-28. Paths below are relative to the repository root.

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
│   └── Models/                         # Model files and provenance
└── Assets.xcassets/

Vendor/
├── SpatialCore/                        # Pure Swift geometry and path algorithms
│   ├── Sources/SpatialCore/
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
