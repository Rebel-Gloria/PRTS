# 代码清单

各模块的文件数和行数，由 `python3 scripts/code_inventory.py --write` 生成，不要手改。

- 行数包含注释，不等于语句数。
- App 包含 Swift 和 Metal 源码；Tests 包含 Swift 和 Python 测试。
- Contracts 是 App 链接的 `PRTSContracts`；OptionalModels 是没有链接进 App 的可选源码。
- Total 是全部维护的源码，不等于 App 的编译量。
- 不算 Experiments、模型、图片、文档、工程配置和 Package.swift。

| 模块 | 文件数 | 物理行 | 非空行 |
|---|---:|---:|---:|
| App | 46 | 6242 | 5859 |
| SpatialCore | 40 | 5325 | 5161 |
| Contracts | 7 | 770 | 746 |
| OptionalModels | 16 | 1409 | 1372 |
| Tests | 45 | 6208 | 5961 |
| Scripts | 10 | 931 | 862 |
| Total | 164 | 20885 | 19961 |

## 文件树

各目录做什么见 [代码结构](code-structure.md)。

```text
PRTS/
  App/
    PRTSApp.swift (18 lines)
    PRTSIntents.swift (61 lines)
    RuntimeProfile.swift (9 lines)
  Capture/
    CameraManager.swift (128 lines)
    CameraPreview.swift (33 lines)
  Feedback/
    FeedbackCoordinator.swift (112 lines)
    HapticManager.swift (71 lines)
    ObstacleRouteAnnouncementPolicy.swift (93 lines)
    PathHaptics.swift (81 lines)
    RouteAnnouncementPolicy.swift (58 lines)
    SpeechManager.swift (295 lines)
  Integration/
    PRTSBackendBridge.swift (61 lines)
  PhotoDescription/
    PhotoAudioOutput.swift (94 lines)
    PhotoChatClient.swift (55 lines)
    PhotoChatProtocol.swift (138 lines)
    PhotoChatProvider.swift (61 lines)
    PhotoCredentialStore.swift (48 lines)
    PhotoDescriptionCoordinator.swift (176 lines)
    PhotoDescriptionServices.swift (43 lines)
    PhotoImageEncoder.swift (38 lines)
    PhotoLocalModel.swift (20 lines)
    PhotoPressState.swift (31 lines)
    PhotoSpeechRecognizer.swift (138 lines)
  Spatial/
    DevCapture/
      DevCaptureRecorder.swift (270 lines)
    Diagnostics/
      DiagnosticRecorder.swift (267 lines)
      SessionRecorder.swift (231 lines)
    Rendering/
      ProbeRenderer.swift (453 lines)
      ProbeShaders.metal.txt (67 lines)
    Runtime/
      CoreMLDepthModel.swift (69 lines)
      MonocularDepthProvider.swift (133 lines)
      ProbeEngine.swift (411 lines)
      ProbeViewModel.swift (175 lines)
      Snapshots.swift (303 lines)
  TextReading/
    TextReadingPrompt.swift (145 lines)
    TextReadingSession.swift (289 lines)
    TextRecognizer.swift (43 lines)
    ThreeFingerHold.swift (67 lines)
  UI/
    ContentView.swift (658 lines)
    DemoOptionsView.swift (54 lines)
    HomeDemoOverlay.swift (85 lines)
    LiquidGlass.swift (52 lines)
    Localization.swift (86 lines)
    PhotoCaptureButton.swift (138 lines)
    PhotoDescriptionSettingsView.swift (105 lines)
    ProbeSettingsView.swift (156 lines)
    SettingsView.swift (123 lines)
PRTSTests/
  DevCaptureTests.swift (125 lines)
  LocalVLMBenchmarkTests.swift (112 lines)
  ObstacleRouteSpeechTests.swift (138 lines)
  PRTSTests.swift (103 lines)
  PhotoDescriptionTests.swift (188 lines)
  PhotoImageAlignmentTests.swift (59 lines)
  PhotoLifecycleTests.swift (231 lines)
  PhotoLocalModelTests.swift (84 lines)
  PhotoPresentationTests.swift (112 lines)
  TextReadingAnswerTests.swift (65 lines)
  TextRecognizerTests.swift (30 lines)
PRTSUITests/
  PRTSUITests.swift (316 lines)
  PRTSUITestsLaunchTests.swift (35 lines)
Vendor/
  PRTSCore/
    Sources/
      PRTSAppleModels/
        AMapService.swift (83 lines)
        AppleSpeechOutput.swift (82 lines)
        CameraAdapter.swift (33 lines)
        CorridorPlanner.swift (71 lines)
        ForwardScan.swift (57 lines)
        LocalGuide.swift (99 lines)
        NativePerception.swift (149 lines)
        NativeVisionLanguageModel.swift (92 lines)
        ONNXModel.swift (52 lines)
        PRTSCoreSession.swift (370 lines)
        QueueReader.swift (61 lines)
        SenseVoice.swift (26 lines)
        VisionTextReader.swift (101 lines)
        VisualWaitingBrain.swift (78 lines)
      PRTSAppleModelsLite/
        CameraAdapter.swift (41 lines)
        RuntimeCapability.swift (14 lines)
      PRTSContracts/
        CommandRouter.swift (66 lines)
        Contracts.swift (87 lines)
        CoreEvent.swift (55 lines)
        Navigation.swift (169 lines)
        PCMBuffer.swift (52 lines)
        QueueTextRules.swift (94 lines)
        TaskState.swift (247 lines)
    Tests/
      PRTSContractsTests/
        ContractTests.swift (28 lines)
        PythonParityTests.swift (105 lines)
  SpatialCore/
    Sources/
      SpatialCore/
        Analysis.swift (182 lines)
        AppendFile.swift (15 lines)
        BlockingVolume.swift (66 lines)
        Depth.swift (146 lines)
        DiagnosticJournal.swift (258 lines)
        DiagnosticMeasurements.swift (85 lines)
        FanPathSearch.swift (207 lines)
        FeedbackPolicy.swift (57 lines)
        ForwardObstacleTrigger.swift (132 lines)
        ForwardPathSearch.swift (146 lines)
        ForwardRoutePlanner.swift (541 lines)
        ForwardRouteState.swift (90 lines)
        Geometry.swift (147 lines)
        GreedyDetourSearch.swift (49 lines)
        Grid.swift (214 lines)
        Ground.swift (112 lines)
        GroundReference.swift (67 lines)
        MeshFrameCodec.swift (57 lines)
        MetricScaleTracking.swift (113 lines)
        MonocularDepth.swift (185 lines)
        ObstaclePersistence.swift (38 lines)
        ObstacleWaypointPlanner.swift (203 lines)
        ObstacleWaypointSearch.swift (102 lines)
        ObstacleWaypointState.swift (68 lines)
        OccupancyFootprint.swift (46 lines)
        PathDrawing.swift (98 lines)
        PathHapticPolicy.swift (82 lines)
        PathObstacleCheck.swift (75 lines)
        PathPrediction.swift (489 lines)
        PredictedGeometry.swift (36 lines)
        ResultPresentationGate.swift (53 lines)
        RouteContinuity.swift (248 lines)
        RouteEvidenceMap.swift (262 lines)
        RoutePlanningGrid.swift (69 lines)
        RouteProjection.swift (73 lines)
        SceneContracts.swift (156 lines)
        SurfaceHistory.swift (41 lines)
        SurfaceModel.swift (108 lines)
        TemporalOccupancyGrid.swift (162 lines)
        WaypointTransitionState.swift (47 lines)
    Tests/
      SpatialCoreTests/
        BlockingVolumeTests.swift (79 lines)
        DiagnosticTests.swift (175 lines)
        FanPathTests.swift (160 lines)
        FixedTargetTests.swift (207 lines)
        ForwardRouteTests.swift (286 lines)
        GroundContinuityTests.swift (153 lines)
        MeshFrameCodecTests.swift (42 lines)
        MetricScaleTrackingTests.swift (142 lines)
        MonocularTests.swift (161 lines)
        MotionPresentationTests.swift (216 lines)
        ObstacleWaypointTests.swift (285 lines)
        OccupancyContinuityTests.swift (289 lines)
        OccupancyFootprintTests.swift (66 lines)
        PathPredictionTests.swift (237 lines)
        RollingRouteTests.swift (135 lines)
        RouteEvidenceTests.swift (281 lines)
        RouteProjectionTests.swift (107 lines)
        SpatialCoreTests.swift (225 lines)
        SurfaceModelTests.swift (132 lines)
        TemporalOccupancyTests.swift (120 lines)
        TurnAndTailTests.swift (170 lines)
        VerifiedContinuityTests.swift (42 lines)
        WaypointStabilityTests.swift (76 lines)
        WorldRouteLockTests.swift (109 lines)
scripts/
  code_inventory.py (89 lines)
  compare_route_replays.py (76 lines)
  pull_diag.py (35 lines)
  read_dev_capture.py (89 lines)
  read_diag.py (324 lines)
  replay_route_snapshots.swift (34 lines)
  replay_routes.swift (96 lines)
  summarize_session.py (148 lines)
  sync-prts-core.sh (29 lines)
  test_code_inventory.py (54 lines)
  test_dev_capture.py (36 lines)
  test_read_diag.py (219 lines)
  test_route_replay.py (40 lines)
  test_spatial_integration.py (194 lines)
  test_summarize_session.py (39 lines)
  validate_spatial.sh (11 lines)
```
