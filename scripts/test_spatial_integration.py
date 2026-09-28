"""Source/resource parity and preserved home-layout guards; not device acceptance."""
import hashlib
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1]
PROBE = ROOT / "Experiments/SpatialProbe"

class SpatialIntegrationTests(unittest.TestCase):
    def test_all_verified_algorithms_are_identical(self):
        for source in (PROBE / "Core/Sources/SpatialCore").glob("*.swift"):
            if source.name == "PathPrediction.swift": continue # Main-specific stability policy has deterministic tests.
            with self.subTest(file=source.name):
                self.assertEqual(source.read_bytes(), (ROOT / "Vendor/SpatialCore/Sources/SpatialCore" / source.name).read_bytes())

    def test_runtime_algorithms_are_identical_except_explicit_imports(self):
        files = {
            "ProbeEngine.swift": ROOT / "PRTS/Spatial/Runtime/ProbeEngine.swift",
            "PathHaptics.swift": ROOT / "PRTS/Feedback/PathHaptics.swift",
            "CoreMLDepthModel.swift": ROOT / "PRTS/Spatial/Runtime/CoreMLDepthModel.swift",
            "MonocularDepthProvider.swift": ROOT / "PRTS/Spatial/Runtime/MonocularDepthProvider.swift",
            "DiagnosticRecorder.swift": ROOT / "PRTS/Spatial/Diagnostics/DiagnosticRecorder.swift",
            "SessionRecorder.swift": ROOT / "PRTS/Spatial/Diagnostics/SessionRecorder.swift",
        }
        for name,target in files.items():
            def body(path):
                return "\n".join(line for line in path.read_text().splitlines() if not line.lstrip().startswith(("import ","//"))).strip().replace(',"ground_evidence_expired"', "")
            with self.subTest(file=name):
                self.assertEqual(body(PROBE / "App" / name),body(target))

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
        self.assertIn('else if !isShowingSettings,feedback.lastConsumedResultID',home)
        self.assertIn('speechManager.cancelPerceptionSpeech()',home)

    def test_original_home_controls_and_theme_are_preserved(self):
        # Intentional baseline: local main c9bace5, before the uncommitted UI rewrite.
        s = (ROOT / "PRTS/UI/ContentView.swift").read_text()
        parts = {
            "header": s[s.index("    private var header:"):s.index("    private var cameraStatus:")],
            "cameraStatus": s[s.index("    private var cameraStatus:"):s.index("    private var backendStatus:")],
            "primaryButton": s[s.index("    private var primaryButton:"):s.index("    private var stopGesture:")],
            "stopGesture": s[s.index("    private var stopGesture:"):s.index("    private func startCameraFromButton")],
            "theme": s[s.index("private extension Color"):],
        }
        expected = {'header': 'b6fd21bf1b46b2e6d4151abfa1f471660ba09d045abea164f266e43dd79b1909', 'cameraStatus': 'c4b944ef4a1364469fad3ca8df7008808ca1fa693f1a6ec91ceaea8aa4008755', 'primaryButton': 'cd8e9cefccb539e922831be45aa32f6738eda904aa8bf5e3f9e66137fe7be663', 'stopGesture': '262372a13b8b7185856d8a908233d16e078b3428176aa0227e283558c6be16a8', 'theme': '060b5ef5337e64d7bc4545eb1dc5d728f53c1396bf670264c9cbef94b8659738'}
        for name,content in parts.items():
            with self.subTest(part=name):
                self.assertEqual(hashlib.sha256(content.encode()).hexdigest(),expected[name])

if __name__ == "__main__":
    unittest.main()
