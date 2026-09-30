"""Source/resource parity and preserved home-layout guards; not device acceptance."""
import hashlib
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "Experiments/SpatialProbe"

class SpatialIntegrationTests(unittest.TestCase):
    def test_all_verified_algorithms_are_identical(self):
        for source in (PROBE / "Core/Sources/SpatialCore").glob("*.swift"):
            # These files are intentionally evolved in main; Swift suites cover both the
            # legacy graph defaults and forward/maneuver behavior. Clearance math stays pinned below.
            if source.name in {"PathPrediction.swift", "FanPathSearch.swift", "PathDrawing.swift"}: continue
            with self.subTest(file=source.name):
                current = (ROOT / "Vendor/SpatialCore/Sources/SpatialCore" / source.name).read_text()
                if source.name == "Analysis.swift":
                    # Build25 extends the record only. Keep the ENTIRE sensor analyzer
                    # byte-for-byte pinned rather than exempting Analysis.swift wholesale.
                    current = current.replace(
                        "    /// Present only on an adapted planning snapshot; nil in raw/older recordings.\n"
                        "    public var planningObstacles: [OccupancyFootprint]?\n", "")
                self.assertEqual(source.read_text(), current)

    def test_runtime_algorithms_are_identical_except_explicit_imports(self):
        files = {
            "PathHaptics.swift": ROOT / "PRTS/Feedback/PathHaptics.swift",
            "CoreMLDepthModel.swift": ROOT / "PRTS/Spatial/Runtime/CoreMLDepthModel.swift",
            "MonocularDepthProvider.swift": ROOT / "PRTS/Spatial/Runtime/MonocularDepthProvider.swift",
            "SessionRecorder.swift": ROOT / "PRTS/Spatial/Diagnostics/SessionRecorder.swift",
        }
        for name,target in files.items():
            def body(path):
                # Compare the normal compiled branch: dev-only capture must not alter algorithms.
                lines = []; depth = 0; keep = True
                for line in path.read_text().splitlines():
                    token = line.strip()
                    if token == "#if PRTS_DEV_CAPTURE" and depth == 0:
                        depth = 1; keep = False; continue
                    if depth:
                        if token.startswith("#if "): depth += 1
                        if token == "#else" and depth == 1:
                            keep = True; continue
                        if token == "#endif":
                            depth -= 1
                            if depth == 0: keep = True; continue
                    if keep and not line.lstrip().startswith(("import ","//")):
                        lines.append(line)
                text = "\n".join(lines).replace(',"ground_evidence_expired"', "")
                # Explicit concurrency annotations do not change mathematical operations.
                # Value records explicitly opt out of the app's MainActor default.
                for record in ("CaptureDiagnostic", "RenderDiagnostic", "Event", "Record",
                               "Header", "Skip", "GPU", "Presented", "Heartbeat",
                               "MetricContext", "RenderMetricRecord", "CompactGrid",
                               "FrameLog", "RecorderStatus"):
                    text = text.replace(f"nonisolated struct {record}", f"struct {record}")
                # Main consumes the route module's explicit withdrawal bit; no strategy in runtime.
                text = text.replace("pathUpdate.strategy?.invalidatesPreviousPath == true ||\n                        ", "")
                # Previously approved user-facing copy change; haptic policy remains pinned.
                text = text.replace("已对准，静默至明显偏离（非安全确认）", "已对准")
                text = text.replace("nonisolated static func planes", "static func planes")
                text = text.replace('        let privacy = "No RGB or video saved."', "")
                text = text.replace('map. " + privacy', 'map. No RGB or video saved."')
                return " ".join(text.split())
            with self.subTest(file=name):
                self.assertEqual(body(PROBE / "App" / name),body(target))

    def test_forward_strategy_preserves_clearance_math_and_module_boundaries(self):
        before = (PROBE / "Core/Sources/SpatialCore/FanPathSearch.swift").read_text()
        after = (ROOT / "Vendor/SpatialCore/Sources/SpatialCore/FanPathSearch.swift").read_text()
        # Build18 changes raster permissions, not swept segment/cell distance math.
        # Pin the actual overlap implementation rather than freezing the old mask policy.
        def clearance_math(text):
            return text.split("public static func segment", 1)[1].split("public struct FanPathPlan", 1)[0]
        self.assertEqual(clearance_math(before), clearance_math(after))
        self.assertIn("radius: Float,allowUnknown: Bool = false", after)
        core = ROOT / "Vendor/SpatialCore/Sources/SpatialCore"
        for name in ("ForwardRoutePlanner.swift", "ForwardRouteState.swift", "ForwardPathSearch.swift", "RoutePlanningGrid.swift",
                     "OccupancyFootprint.swift", "ObstacleWaypointPlanner.swift", "ObstacleWaypointSearch.swift", "ObstacleWaypointState.swift", "ForwardObstacleTrigger.swift", "PathObstacleCheck.swift", "RouteProjection.swift", "TemporalOccupancyGrid.swift", "GreedyDetourSearch.swift", "ObstaclePersistence.swift", "RouteEvidenceMap.swift", "RouteContinuity.swift"):
            self.assertTrue((core / name).is_file())
            source = (core / name).read_text()
            for forbidden in ("import ARKit", "import SwiftUI", "import Metal", "import AVFoundation"):
                self.assertNotIn(forbidden, source)
        speech = (ROOT / "PRTS/Feedback/RouteAnnouncementPolicy.swift").read_text()
        self.assertNotIn("ARSession", speech)
        self.assertNotIn("ForwardPathSearch", speech)
        runtime = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text()
        self.assertIn("RoutePublicationPolicy.decide", runtime)
        self.assertLess(runtime.index("RouteSafety.invalidationReason"), runtime.index("let pathUpdate = pathPredictor.update"))
        self.assertNotIn("experimentalOccupancyPlanning: true", runtime)
        self.assertIn("PathPredictor(policy:PRTSRuntimeProfile.routePlanningPolicy)", runtime)
        self.assertIn("s.pathUpdate = decision.update", runtime)
        self.assertIn("routeHazardWatermark", runtime)
        home = (ROOT / "PRTS/UI/ContentView.swift").read_text()
        self.assertIn("snapshot.pathUpdate.waypointGuidance != nil", home)
        self.assertIn("feedback.consumeDirection(snapshot, speech: speechManager)", home)
        # Open-space speech is independent of whether a fresh measured floor exists.
        self.assertLess(home.index("snapshot.pathUpdate.waypointGuidance != nil"),
                        home.index("else if let result = camera.latestSceneResult"))
        self.assertNotIn("ForwardPathSearch", runtime)
        self.assertNotIn("ForwardObstacleTrigger", runtime)

    def test_recording_is_separate_from_planning_policy(self):
        engine = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text()
        planner = engine[engine.index("let pathUpdate = pathPredictor.update"):engine.index("result.stageMilliseconds[\"pathPrediction\"]")]
        self.assertNotIn("captureEnabled", planner)
        self.assertNotIn("#if", planner)
        diagnostics = (ROOT / "PRTS/Spatial/Diagnostics/DiagnosticRecorder.swift").read_text()
        self.assertIn("routePublication", diagnostics)
        self.assertIn("PRTSRuntimeProfile.routePlanningPolicy.rawValue", diagnostics)
        self.assertIn("captureEnabled", diagnostics)
        self.assertIn("routePresentationReason", diagnostics)
        self.assertIn("onOccupancyConflict:", engine)
        self.assertIn("includeCurrentObstacles:PRTSRuntimeProfile.routePlanningPolicy == .verified", engine)
        config = (ROOT / "PRTS/App/RuntimeProfile.swift").read_text()
        self.assertIn("routePlanningPolicy: RoutePlanningPolicy = .obstacleVeto", config)
        self.assertNotIn("#if", config)
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text()
        self.assertIn("presentation?.path.points.hashValue", renderer)
        self.assertIn("routeDisplayedVerifiedLength:drawnPath > 0", renderer)

    def test_model_matches_verified_probe(self):
        sources = [p for p in (PROBE / "App/Models").rglob("*") if p.is_file()]
        for source in sources:
            target = ROOT / "PRTS/Spatial/Models" / source.relative_to(PROBE / "App/Models")
            with self.subTest(file=str(source.name)):
                self.assertEqual(hashlib.sha256(source.read_bytes()).digest(),hashlib.sha256(target.read_bytes()).digest())

    def test_home_visibility_does_not_disable_capture_or_analysis(self):
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text()
        shader = (ROOT / "PRTS/Spatial/Rendering/ProbeShaders.metal.txt").read_text()
        self.assertIn("s.options.showCameraImage ? 0 : 1", renderer)
        self.assertIn("if s.options.showOverlays,s.frozen == nil", renderer)
        self.assertIn("if s.options.showPath,let pathBuffer", renderer)
        self.assertIn("u.colorEncoding.z > 0.5 ?", shader)
        engine = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text()
        self.assertNotIn("showCameraImage", engine)
        self.assertNotIn("showOverlays", engine)

    def test_demo_is_a_home_overlay_not_a_second_camera_screen(self):
        home = (ROOT / "PRTS/UI/ContentView.swift").read_text()
        settings = (ROOT / "PRTS/UI/SettingsView.swift").read_text()
        overlay = (ROOT / "PRTS/UI/HomeDemoOverlay.swift").read_text()
        options = (ROOT / "PRTS/UI/DemoOptionsView.swift").read_text()
        self.assertIn("HomeDemoOverlay(model:camera.model)",home)
        self.assertIn('NavigationLink("演示模式选项")',settings)
        self.assertNotIn("ProbeContentView",settings)
        for text in [overlay,options]:
            self.assertNotIn("ARSession()",text)
            self.assertNotIn("ProbeViewModel()",text)
            self.assertNotIn("Timer.publish",text)
        self.assertFalse((ROOT / "PRTS/Spatial/Runtime/ProbeContentView.swift").exists())

    def test_settings_has_native_back_and_separate_speech_ownership(self):
        settings = (ROOT / "PRTS/UI/SettingsView.swift").read_text()
        home = (ROOT / "PRTS/UI/ContentView.swift").read_text()
        self.assertNotIn('Button("返回")',settings)
        self.assertIn('speech.speakSettingsScreen',settings)
        self.assertIn('else if !isShowingSettings {',home)
        self.assertIn('speechManager.cancelPerceptionSpeech()',home)

    def test_original_home_controls_and_theme_are_preserved(self):
        # Intentional baseline: local main c9bace5, before the uncommitted UI rewrite.
        s = (ROOT / "PRTS/UI/ContentView.swift").read_text()
        parts = {
            "header": s[s.index("    private var header:"):s.index("    private var cameraStatus:")],
            "cameraStatus": s[s.index("    private var cameraStatus:"):s.index("    #if PRTS_DEV_CAPTURE\n    private var commandEntry:")],
            "primaryButton": s[s.index("    private var primaryButton:"):s.index("    private var stopGesture:")],
            "stopGesture": s[s.index("    private var stopGesture:"):s.index("    private func startCameraFromButton")],
            "theme": s[s.index("private extension Color"):],
        }
        expected = {'header': '3bfe906826c6e382a22ca3f5b0e35e809cb0bc6f6cbc0ad5ce3231ef76b7f87a', 'cameraStatus': 'c4b944ef4a1364469fad3ca8df7008808ca1fa693f1a6ec91ceaea8aa4008755', 'primaryButton': 'cd8e9cefccb539e922831be45aa32f6738eda904aa8bf5e3f9e66137fe7be663', 'stopGesture': '262372a13b8b7185856d8a908233d16e078b3428176aa0227e283558c6be16a8', 'theme': '060b5ef5337e64d7bc4545eb1dc5d728f53c1396bf670264c9cbef94b8659738'}
        for name,content in parts.items():
            with self.subTest(part=name):
                self.assertEqual(hashlib.sha256(content.encode()).hexdigest(),expected[name])

if __name__ == "__main__":
    unittest.main()
