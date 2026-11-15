"""Check home feedback gating without restarting active computation."""

import itertools
import json
import re
import unittest
from pathlib import Path

from swift_source import swift_code

ROOT = Path(__file__).resolve().parents[1]


class StabilityBoundaryTests(unittest.TestCase):
    def test_home_feedback_shares_all_existing_pause_conditions(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        poll = source.split(".onReceive(pollTimer)", 1)[1].split(".onChange", 1)[0]
        expression = re.search(r"let suspendHaptics =\s+(.*?)\n\s*//", poll, re.S)[1]
        names = (
            "camera.suspendsFeedback",
            "photo.busy",
            "reading",
            "isShowingSettings",
            "isHoldingStop",
            "guidanceSuppressed",
            "scenePhase != .active",
            "audioInterrupted",
        )
        for flags in itertools.product((False, True), repeat=len(names)):
            evaluated = expression
            for name, flag in zip(names, flags, strict=True):
                evaluated = evaluated.replace(name, str(flag))
            self.assertEqual(eval(" ".join(evaluated.replace("||", "or").split())), any(flags))
        code = swift_code(poll)
        # Live captions pause speech only; vibration keeps running under them.
        self.assertIn("letsuspendFeedback=suspendHaptics||liveCaption.suspendsFeedback", code)
        self.assertIn("camera.poll(suspendFeedback:suspendHaptics)", code)
        self.assertIn("ifsuspendHaptics{feedback.resetAlerts()", code)
        self.assertIn("if!suspendFeedback{", code)
        self.assertIn("elseif!isShowingSettings{", code)

    def test_lifecycle_only_gates_feedback_and_preserves_work(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        lifecycle = source.split(".onChange(of: scenePhase)", 1)[1].split(".onAppear", 1)[0]
        settings = source.split(".onChange(of: isShowingSettings)", 1)[1].split(
            ".onChange(of: lowVisionMode)", 1
        )[0]
        for block in (lifecycle, settings):
            self.assertIn("updateFeatureFeedback()", block)
            for operation in ("textReading.terminate()", "photo.cancel()", "liveCaption.stop()"):
                self.assertNotIn(operation, block)
        disappearance = source.split(".onDisappear", 1)[1].split(".onReceive", 1)[0]
        for feature in ("photo", "liveCaption", "textReading"):
            self.assertIn(f"{feature}.setFeedbackEnabled(false)", disappearance)
        model = (ROOT / "PRTS/Spatial/Runtime/ProbeViewModel.swift").read_text(encoding="utf-8")
        lifecycle = model.split("func lifecycle(", 1)[1].split("private func", 1)[0]
        self.assertNotIn("engine.stop(", lifecycle)

    def test_feedback_gate_reaches_haptics_and_pending_pulses(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        gate = source.split("private func updateFeatureFeedback()", 1)[1].split(
            "private var isLargeText", 1
        )[0]
        self.assertIn("hapticManager.setFeedbackEnabled(enabled)", gate)
        self.assertIn("camera.poll(suspendFeedback: true)", gate)
        haptics = (ROOT / "PRTS/Features/Guidance/Feedback/HapticManager.swift").read_text(
            encoding="utf-8"
        )
        self.assertIn("feedbackGeneration &+= 1", haptics)
        self.assertEqual(haptics.count("self?.feedbackGeneration == generation"), 2)

    def test_audio_interruption_still_releases_unavailable_microphone(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text(encoding="utf-8")
        interruption = source.split("for: AVAudioSession.interruptionNotification", 1)[1]
        interruption = interruption.split(".onDisappear", 1)[0]
        self.assertIn("photo.handleAudioInterruption()", interruption)
        self.assertIn("updateFeatureFeedback()", interruption)
        for stop in ("textReading.terminate()", "photo.cancel()", "liveCaption.stop()"):
            self.assertNotIn(stop, interruption)
        photo = (
            ROOT / "PRTS/Features/PhotoDescription/PhotoDescriptionCoordinator.swift"
        ).read_text(encoding="utf-8")
        handler = photo.split("func handleAudioInterruption()", 1)[1].split("    ///", 1)[0]
        self.assertIn("recognizer.endCapture()", handler)

    def test_recognition_failure_translations(self):
        catalog = json.loads((ROOT / "PRTS/Localizable.xcstrings").read_text(encoding="utf-8"))
        translations = catalog["strings"]["ocr.failed"]["localizations"]
        self.assertEqual(
            translations["en"]["stringUnit"]["value"], "Couldn't read the text. Try again."
        )
        self.assertEqual(translations["zh-Hans"]["stringUnit"]["value"], "读文字失败，请重试")

    def test_error_descriptions_are_translated(self):
        # Error text is looked up by key at run time, so a missing entry would only show on device.
        catalog = json.loads((ROOT / "PRTS/Localizable.xcstrings").read_text(encoding="utf-8"))
        keys = set()
        for file in (ROOT / "PRTS").rglob("*.swift"):
            keys.update(re.findall(r'"(photo\.error\.[\w.]+)"', file.read_text(encoding="utf-8")))
        self.assertTrue(keys)
        for key in sorted(keys):
            with self.subTest(key=key):
                translations = catalog["strings"][key]["localizations"]
                self.assertEqual(set(translations), {"en", "zh-Hans"})
                values = [unit["stringUnit"]["value"] for unit in translations.values()]
                self.assertTrue(all(values))
                # Both languages take the same arguments.
                self.assertEqual(len({value.count("%lld") for value in values}), 1)

    def test_ci_stub_uses_the_source_cancellation_header(self):
        workflow = (ROOT / ".github/workflows/code-quality.yml").read_text(encoding="utf-8")
        self.assertIn("cp Packages/LocalVLM/csrc/prts_local_vlm.h", workflow)
        header = (ROOT / "Packages/LocalVLM/csrc/prts_local_vlm.h").read_text(encoding="utf-8")
        for function in ("create", "set", "is_requested", "free"):
            self.assertIn(f"prts_vlm_cancel_{function}", header)
        self.assertNotIn("volatile int", header)
