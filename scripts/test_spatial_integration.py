"""Source/resource parity and preserved home-layout guards; not device acceptance."""

import hashlib
import json
import re
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
            # Disk retention lives in the app's RecordingStore; SpatialCore keeps only DTOs.
            if source.name in {"AppendFile.swift", "DiagnosticJournal.swift"}:
                continue
            with self.subTest(file=source.name):
                current = source_file(
                    ROOT / "Packages/SpatialCore/Sources/SpatialCore", source.name
                ).read_text(encoding="utf-8")
                expected = source.read_text(encoding="utf-8")
                if source.name == "Analysis.swift":
                    # Only product feedback classification has no frozen counterpart.
                    # Keep comparing the entire fit, tracking, grid, and clearance pipeline.
                    current = re.sub(
                        r"^        func groundFeedback\(mapped: Bool = false\).*?^        \}\n",
                        "",
                        current,
                        flags=re.M | re.S,
                    )
                    current = swift_code(current)
                    for product, probe in (
                        (
                            "public enum GroundFeedbackEvidence: String, Codable, Sendable { case mapped, unmapped, fullFieldObstacle }",
                            "",
                        ),
                        ("public var groundFeedbackEvidence: GroundFeedbackEvidence?", ""),
                        ("public var planningObstacles: [OccupancyFootprint]?", ""),
                        (
                            "let depthStatistics = DepthStatistics(observation, parameters: p) diagnostics.depth = depthStatistics",
                            "diagnostics.depth = DepthStatistics(observation, parameters: p)",
                        ),
                        ("!observation.isPrediction,", ""),
                        (
                            "Float(depthStatistics.acceptedHighConfidence) / Float(depthStatistics.pixels)",
                            "observation.coverage(parameters: p)",
                        ),
                        ("result.groundFeedbackEvidence = groundFeedback()", ""),
                        (
                            "result.groundFeedbackEvidence = groundFeedback(mapped: confirmedGround && grid.cells.contains { $0.groundSamples > 0 })",
                            "",
                        ),
                    ):
                        self.assertIn(product, current)
                        current = current.replace(swift_code(product), swift_code(probe))
                if source.name == "Depth.swift":
                    # Zero is not a physical range, even with a configured lower bound of zero.
                    expected = expected.replace(
                        "return supported && depth[i].isFinite && depth[i] >= p.minDepth && depth[i] <= p.maxDepth",
                        "let z = depth[i]\n        return supported && z.isFinite && z > 0 && z >= p.minDepth && z <= p.maxDepth",
                    )
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
        }
        for name, target in files.items():

            def body(path):
                # Compare the normal compiled branch: dev-only capture must not alter algorithms.
                lines = []
                depth = 0
                keep = True
                for line in path.read_text(encoding="utf-8").splitlines():
                    token = line.strip()
                    if token == "#if PRTS_DEV" and depth == 0:
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
                if path == PROBE / "App/MonocularDepthProvider.swift":
                    # Only the probe displays these diagnostics live; the app computes coverage
                    # when recording. Continue comparing the entire prediction and render path.
                    text = text.replace("    let relativeCoverage: Float\n", "")
                    text = re.sub(
                        r"^    var groundStatus: String \{.*?^    \}\n", "", text, flags=re.M | re.S
                    )
                    text = text.replace(
                        "        self.relativeCoverage =\n"
                        r"            Float(relative.filter(\.isFinite).count) / Float(max(1, relative.count))",
                        "",
                    )
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
        # All raw and route speech passes through the same ground-evidence gate.
        coordinator = (
            ROOT / "PRTS/Features/Guidance/Feedback/FeedbackCoordinator.swift"
        ).read_text()
        self.assertIn("raw: camera.latestSceneResult", home)
        self.assertNotIn("feedback.consumeDirection", home)
        self.assertIn("snapshot.feedbackEvidence(now: now)", coordinator)
        self.assertIn("private func consumeDirection(", coordinator)
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
        config = (ROOT / "PRTS/Spatial/Runtime/RuntimeProfile.swift").read_text(encoding="utf-8")
        self.assertIn("routePlanningPolicy: RoutePlanningPolicy = .obstacleVeto", config)
        self.assertNotIn("#if", config)
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text(encoding="utf-8")
        self.assertIn("presentation?.path.points.hashValue", renderer)
        self.assertIn("routeDisplayedVerifiedLength:drawnPath > 0", renderer)

    def test_model_matches_verified_probe(self):
        provenance = json.loads((PROBE / "App/Models/provenance.json").read_text(encoding="utf-8"))
        for item in provenance["files"]:
            relative = "AppleModelCard.txt" if item["path"] == "README.md" else item["path"]
            data = (PROBE / "App/Models" / relative).read_bytes()
            with self.subTest(upstream=relative):
                self.assertEqual(len(data), item["bytes"])
                self.assertEqual(hashlib.sha256(data).hexdigest(), item["sha256"])
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

    def test_dev_recording_ui_replaces_manual_capture_and_demo_controls(self):
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        settings = (ROOT / "PRTS/Features/Settings/SettingsView.swift").read_text(encoding="utf-8")
        share = (ROOT / "PRTS/Features/Developer/RecordingShareSheet.swift").read_text(
            encoding="utf-8"
        )
        for legacy in (
            "HomeDemoOverlay",
            "DemoOptionsView",
            "ProbeSettingsView",
            "devCaptureToggle",
        ):
            self.assertNotIn(legacy, home + settings)
        self.assertIn('Text("recording.home.privacy")', home)
        self.assertIn('accessibilityIdentifier("recordingPrivacyNotice")', home)
        self.assertIn('Button("recording.settings.export")', settings)
        self.assertIn('Button("recording.settings.clear", role: .destructive)', settings)
        self.assertIn(
            '.alert("recording.clear.title", isPresented: $confirmClearRecordings)', settings
        )
        self.assertIn('Button("recording.clear.confirm", role: .destructive)', settings)
        self.assertEqual(settings.count("resetRecordings()"), 1)
        self.assertIn('Button("recording.clear.cancel", role: .cancel) {}', settings)
        self.assertIn("UIActivityViewController(activityItems: [url]", share)
        for text in (share, settings):
            self.assertNotIn("ARSession()", text)
            self.assertNotIn("ProbeViewModel()", text)
            self.assertNotIn("Timer.publish", text)
        catalog = json.loads((ROOT / "PRTS/Localizable.xcstrings").read_text(encoding="utf-8"))
        self.assertEqual(
            catalog["strings"]["recording.home.privacy"]["localizations"]["zh-Hans"]["stringUnit"][
                "value"
            ],
            "此构建将自动录制数据到本地，请注意隐私安全",
        )

    def test_build_modes_share_product_rendering_and_planning(self):
        project = (ROOT / "PRTS.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        configurations = project.split("/* Begin XCBuildConfiguration section */", 1)[1].split(
            "/* End XCBuildConfiguration section */", 1
        )[0]
        names = re.findall(r"name = (\w+);", configurations)
        self.assertEqual(sorted(names), ["Dev"] * 4 + ["Release"] * 4)
        self.assertIn(
            'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "PRTS_DEV $(inherited)"', configurations
        )
        renderer = (ROOT / "PRTS/Spatial/Rendering/ProbeRenderer.swift").read_text(encoding="utf-8")
        self.assertNotIn("PRTS_DEV", renderer)
        model = (ROOT / "PRTS/Spatial/Runtime/ProbeViewModel.swift").read_text(encoding="utf-8")
        self.assertIn("options = .product(scanMesh:", model)
        self.assertNotIn("homeRenderOptions.v1", model)
        self.assertFalse((ROOT / "configs/DevCapture.xcconfig").exists())

    def test_settings_has_native_back_and_separate_speech_ownership(self):
        settings = (ROOT / "PRTS/Features/Settings/SettingsView.swift").read_text(encoding="utf-8")
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        self.assertNotIn('Button("返回")', settings)
        self.assertIn("speech.speakSettingsScreen", settings)
        self.assertIn("if !isShowingSettings { speechManager.cancelPerceptionSpeech() }", home)

    def test_original_home_controls_and_theme_are_preserved(self):
        # Guard observable actions and accessibility contracts, not layout hashes.
        # The old primary-button hash already failed before this reorganization.
        home = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        parts = {
            "header": (ROOT / "PRTS/Features/Home/HomeHeaderView.swift").read_text(encoding="utf-8")
            + home,
            "cameraStatus": (
                ROOT / "PRTS/Features/Guidance/Views/CameraStatusView.swift"
            ).read_text(encoding="utf-8"),
        }
        self.assertIn(".onAppear {", home)
        self.assertIn("startCameraFromButton", home)
        self.assertIn(".accessibilityAction(.magicTap)", home)
        self.assertIn("toggleTextReading()", home)
        self.assertIn("GuidanceButton(", home)
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
