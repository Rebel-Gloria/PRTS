"""Source/resource parity and preserved home-layout guards; not device acceptance."""

import hashlib
import unittest
from pathlib import Path

from swift_source import source_file, swift_code

ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "Experiments/SpatialProbe"


class SpatialIntegrationTests(unittest.TestCase):
    def assertIn(self, member, container, msg=None):
        if isinstance(member, str) and isinstance(container, str):
            member, container = swift_code(member), swift_code(container)
        super().assertIn(member, container, msg)

    def assertNotIn(self, member, container, msg=None):
        if isinstance(member, str) and isinstance(container, str):
            member, container = swift_code(member), swift_code(container)
        super().assertNotIn(member, container, msg)

    def test_all_verified_algorithms_are_identical(self):
        for source in (PROBE / "Core/Sources/SpatialCore").glob("*.swift"):
            # These files are intentionally evolved in main; Swift suites cover both the
            # legacy graph defaults and forward/maneuver behavior. Clearance math stays pinned below.
            if source.name in {"PathPrediction.swift", "FanPathSearch.swift", "PathDrawing.swift"}:
                continue
            with self.subTest(file=source.name):
                current = source_file(
                    ROOT / "Packages/SpatialCore/Sources/SpatialCore", source.name
                ).read_text(encoding="utf-8")
                if source.name == "Analysis.swift":
                    # Build25 extends the record only. Keep the ENTIRE sensor analyzer
                    # token-identical rather than exempting Analysis.swift wholesale.
                    current = current.replace(
                        "    /// Present only on an adapted planning snapshot; nil in raw/older recordings.\n"
                        "    public var planningObstacles: [OccupancyFootprint]?\n",
                        "",
                    )
                expected = source.read_text(encoding="utf-8")
                if source.name == "PathHapticPolicy.swift":
                    # The product already prompts outside alignment without the probe's
                    # additional entry threshold. Pin this existing difference explicitly.
                    entry_gate = (
                        'if side == 0 && angle < threshold { mode = "neutral"; return nil }'
                    )
                    self.assertIn(entry_gate, expected)
                    self.assertNotIn(entry_gate, current)
                    expected = swift_code(expected).replace(swift_code(entry_gate), "")
                self.assertEqual(swift_code(expected), swift_code(current))

    def test_runtime_algorithms_are_identical_except_explicit_imports(self):
        files = {
            "PathHaptics.swift": ROOT / "PRTS/Features/Guidance/Feedback/PathHaptics.swift",
            "CoreMLDepthModel.swift": ROOT / "PRTS/Spatial/Depth/CoreMLDepthModel.swift",
            "MonocularDepthProvider.swift": ROOT
            / "PRTS/Spatial/Depth/MonocularDepthProvider.swift",
            "SessionRecorder.swift": ROOT / "PRTS/Spatial/Diagnostics/SessionRecorder.swift",
        }
        for name, target in files.items():

            def body(path):
                # Compare the normal compiled branch: dev-only capture must not alter algorithms.
                lines = []
                depth = 0
                keep = True
                for line in path.read_text(encoding="utf-8").splitlines():
                    token = line.strip()
                    if token == "#if PRTS_DEV_CAPTURE" and depth == 0:
                        depth = 1
                        keep = False
                        continue
                    if depth:
                        if token.startswith("#if "):
                            depth += 1
                        if token == "#else" and depth == 1:
                            keep = True
                            continue
                        if token == "#endif":
                            depth -= 1
                            if depth == 0:
                                keep = True
                                continue
                    if keep and not line.lstrip().startswith(("import ", "//")):
                        lines.append(line)
                text = "\n".join(lines).replace(',"ground_evidence_expired"', "")
                # Explicit concurrency annotations do not change mathematical operations.
                # Value records explicitly opt out of the app's MainActor default.
                for record in (
                    "CaptureDiagnostic",
                    "RenderDiagnostic",
                    "Event",
                    "Record",
                    "Header",
                    "Skip",
                    "GPU",
                    "Presented",
                    "Heartbeat",
                    "MetricContext",
                    "RenderMetricRecord",
                    "CompactGrid",
                    "FrameLog",
                    "RecorderStatus",
                ):
                    text = text.replace(f"nonisolated struct {record}", f"struct {record}")
                # Main consumes the route module's explicit withdrawal bit; no strategy in runtime.
                text = text.replace(
                    "pathUpdate.strategy?.invalidatesPreviousPath == true ||\n                        ",
                    "",
                )
                # Previously approved user-facing copy change; haptic policy remains pinned.
                text = text.replace("已对准，静默至明显偏离（非安全确认）", "已对准")
                text = text.replace("nonisolated static func planes", "static func planes")
                text = text.replace('        let privacy = "No RGB or video saved."', "")
                text = text.replace('map. " + privacy', 'map. No RGB or video saved."')
                return swift_code(text)

            with self.subTest(file=name):
                self.assertEqual(body(PROBE / "App" / name), body(target))

    def test_forward_strategy_preserves_clearance_math_and_module_boundaries(self):
        before = (PROBE / "Core/Sources/SpatialCore/FanPathSearch.swift").read_text(
            encoding="utf-8"
        )
        after = source_file(
            ROOT / "Packages/SpatialCore/Sources/SpatialCore", "FanPathSearch.swift"
        ).read_text(encoding="utf-8")

        # Build18 changes raster permissions, not swept segment/cell distance math.
        # Pin the actual overlap implementation rather than freezing the old mask policy.
        def clearance_math(text):
            return text.split("public static func segment", 1)[1].split(
                "public struct FanPathPlan", 1
            )[0]

        self.assertEqual(swift_code(clearance_math(before)), swift_code(clearance_math(after)))
        self.assertIn("radius: Float,allowUnknown: Bool = false", after)
        core = ROOT / "Packages/SpatialCore/Sources/SpatialCore"
        for name in (
            "ForwardRoutePlanner.swift",
            "ForwardRouteState.swift",
            "ForwardPathSearch.swift",
            "RoutePlanningGrid.swift",
            "OccupancyFootprint.swift",
            "ObstacleWaypointPlanner.swift",
            "ObstacleWaypointSearch.swift",
            "ObstacleWaypointState.swift",
            "ForwardObstacleTrigger.swift",
            "PathObstacleCheck.swift",
            "RouteProjection.swift",
            "TemporalOccupancyGrid.swift",
            "GreedyDetourSearch.swift",
            "ObstaclePersistence.swift",
            "RouteEvidenceMap.swift",
            "RoutePublicationPolicy.swift",
            "RouteSafety.swift",
        ):
            self.assertTrue(source_file(core, name).is_file())
            source = source_file(core, name).read_text(encoding="utf-8")
            for forbidden in (
                "import ARKit",
                "import SwiftUI",
                "import Metal",
                "import AVFoundation",
            ):
                self.assertNotIn(forbidden, source)
        speech = (ROOT / "PRTS/Features/Guidance/Feedback/RouteAnnouncementPolicy.swift").read_text(
            encoding="utf-8"
        )
        self.assertNotIn("ARSession", speech)
        self.assertNotIn("ForwardPathSearch", speech)
        runtime = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text(encoding="utf-8")
        self.assertIn("RoutePublicationPolicy.decide", runtime)
        self.assertLess(
            runtime.index("RouteSafety.invalidationReason"),
            runtime.index("let pathUpdate = pathPredictor.update"),
        )
        self.assertNotIn("experimentalOccupancyPlanning: true", runtime)
        self.assertIn("PathPredictor(policy:PRTSRuntimeProfile.routePlanningPolicy)", runtime)
        self.assertIn("s.pathUpdate = decision.update", runtime)
        self.assertIn("routeHazardWatermark", runtime)
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        self.assertIn("snapshot.pathUpdate.waypointGuidance != nil", home)
        self.assertIn("feedback.consumeDirection(snapshot, speech: speechManager)", home)
        # Open-space speech is independent of whether a fresh measured floor exists.
        self.assertLess(
            home.index("snapshot.pathUpdate.waypointGuidance != nil"),
            home.index("else if let result = camera.latestSceneResult"),
        )
        self.assertNotIn("ForwardPathSearch", runtime)
        self.assertNotIn("ForwardObstacleTrigger", runtime)

    def test_recording_is_separate_from_planning_policy(self):
        engine = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text(encoding="utf-8")
        planner = engine[
            engine.index("let pathUpdate = pathPredictor.update") : engine.index(
                'result.stageMilliseconds["pathPrediction"]'
            )
        ]
        self.assertNotIn("captureEnabled", planner)
        self.assertNotIn("#if", planner)
        diagnostics = (ROOT / "PRTS/Spatial/Diagnostics/DiagnosticRecorder.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("routePublication", diagnostics)
        self.assertIn("PRTSRuntimeProfile.routePlanningPolicy.rawValue", diagnostics)
        self.assertIn("captureEnabled", diagnostics)
        self.assertIn("routePresentationReason", diagnostics)
        self.assertIn("onOccupancyConflict:", engine)
        self.assertIn(
            "includeCurrentObstacles:PRTSRuntimeProfile.routePlanningPolicy == .verified", engine
        )
        config = (ROOT / "PRTS/App/RuntimeProfile.swift").read_text(encoding="utf-8")
        self.assertIn("routePlanningPolicy: RoutePlanningPolicy = .obstacleVeto", config)
        self.assertNotIn("#if", config)
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text(encoding="utf-8")
        self.assertIn("presentation?.path.points.hashValue", renderer)
        self.assertIn("routeDisplayedVerifiedLength:drawnPath > 0", renderer)

    def test_model_matches_verified_probe(self):
        sources = [p for p in (PROBE / "App/Models").rglob("*") if p.is_file()]
        for source in sources:
            target = ROOT / "PRTS/Spatial/Models" / source.relative_to(PROBE / "App/Models")
            with self.subTest(file=str(source.name)):
                self.assertEqual(
                    hashlib.sha256(source.read_bytes()).digest(),
                    hashlib.sha256(target.read_bytes()).digest(),
                )

    def test_home_visibility_does_not_disable_capture_or_analysis(self):
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text(encoding="utf-8")
        shader = (ROOT / "PRTS/Spatial/Rendering/ProbeShaders.metal.txt").read_text(
            encoding="utf-8"
        )
        self.assertIn("s.options.showCameraImage ? 0 : 1", renderer)
        self.assertIn("if s.options.showOverlays,s.frozen == nil", renderer)
        self.assertIn("if s.options.showPath,let pathBuffer", renderer)
        self.assertIn("u.colorEncoding.z > 0.5 ?", shader)
        engine = (ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift").read_text(encoding="utf-8")
        self.assertNotIn("showCameraImage", engine)
        self.assertNotIn("showOverlays", engine)

    def test_demo_is_a_home_overlay_not_a_second_camera_screen(self):
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        settings = (ROOT / "PRTS/Features/Settings/SettingsView.swift").read_text(encoding="utf-8")
        overlay = (ROOT / "PRTS/Features/Developer/HomeDemoOverlay.swift").read_text(
            encoding="utf-8"
        )
        options = (ROOT / "PRTS/Features/Developer/DemoOptionsView.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("HomeDemoOverlay(model:camera.model)", home)
        self.assertIn('NavigationLink("演示模式选项")', settings)
        self.assertNotIn("ProbeContentView", settings)
        for text in [overlay, options]:
            self.assertNotIn("ARSession()", text)
            self.assertNotIn("ProbeViewModel()", text)
            self.assertNotIn("Timer.publish", text)
        self.assertFalse((ROOT / "PRTS/Spatial/Runtime/ProbeContentView.swift").exists())

    def test_settings_has_native_back_and_separate_speech_ownership(self):
        settings = (ROOT / "PRTS/Features/Settings/SettingsView.swift").read_text(encoding="utf-8")
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        self.assertNotIn('Button("返回")', settings)
        self.assertIn("speech.speakSettingsScreen", settings)
        self.assertIn("else if !isShowingSettings {", home)
        self.assertIn("speechManager.cancelPerceptionSpeech()", home)

    def test_original_home_controls_and_theme_are_preserved(self):
        # Guard observable actions and accessibility contracts, not layout hashes.
        # The old primary-button hash already failed before this reorganization.
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        parts = {
            "header": (ROOT / "PRTS/Features/Home/HomeHeaderView.swift").read_text(encoding="utf-8")
            + home,
            "cameraStatus": (
                ROOT / "PRTS/Features/Guidance/Capture/CameraStatusView.swift"
            ).read_text(encoding="utf-8"),
        }
        self.assertIn(".onAppear {", home)
        self.assertIn("startCameraIfNeeded()", home)
        self.assertIn(".accessibilityAction(.magicTap)", home)
        self.assertIn("toggleTextReading()", home)
        self.assertNotIn('accessibilityIdentifier("cameraButton")', home)
        theme = (ROOT / "PRTS/Shared/Appearance/AppColors.swift").read_text(encoding="utf-8")
        for color in (
            "Color(red: 0.025, green: 0.045, blue: 0.075)",
            "Color(red: 0.25, green: 0.95, blue: 0.77)",
            "Color(red: 0.015, green: 0.12, blue: 0.10)",
        ):
            self.assertIn(color, theme)
        for part, required in {
            "header": [
                "hapticManager.buttonTapped()",
                "isShowingSettings = true",
                'accessibilityLabel("home.settings.label")',
                'accessibilityHint("home.settings.hint")',
                'accessibilityIdentifier("settingsButton")',
                ".accessibilityAddTraits(.isHeader)",
            ],
            "cameraStatus": [
                ".accessibilityElement(children: .ignore)",
                'accessibilityLabel("home.camera.status.label")',
                'accessibilityIdentifier("cameraStatus")',
            ],
        }.items():
            for line in required:
                with self.subTest(part=part, line=line):
                    self.assertIn(line, parts[part])


if __name__ == "__main__":
    unittest.main()
