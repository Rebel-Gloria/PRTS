"""Check home feedback wiring and lifecycle termination at the view boundary."""

import itertools
import json
import re
import unittest
from pathlib import Path

from swift_source import swift_code

ROOT = Path(__file__).resolve().parents[1]


class StabilityBoundaryTests(unittest.TestCase):
    def test_home_feedback_shares_all_existing_pause_conditions(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text()
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

    def test_lifecycle_terminates_text_reading_silently(self):
        source = (ROOT / "PRTS/Features/Home/ContentView.swift").read_text()
        lifecycle = source.split(".onChange(of: scenePhase)", 1)[1].split(".onAppear", 1)[0]
        interruption = source.split("for: AVAudioSession.interruptionNotification", 1)[1]
        interruption = interruption.split(".onDisappear", 1)[0]
        disappearance = source.split(".onDisappear", 1)[1].split(".onReceive", 1)[0]
        for block in (lifecycle, interruption, disappearance):
            self.assertIn("textReading.terminate()", block)
            self.assertNotIn("textReading.cancel()", block)

    def test_recognition_failure_translations(self):
        catalog = json.loads((ROOT / "PRTS/Localizable.xcstrings").read_text())
        translations = catalog["strings"]["ocr.failed"]["localizations"]
        self.assertEqual(
            translations["en"]["stringUnit"]["value"], "Couldn't read the text. Try again."
        )
        self.assertEqual(translations["zh-Hans"]["stringUnit"]["value"], "读文字失败，请重试")

    def test_ci_stub_uses_the_source_cancellation_header(self):
        workflow = (ROOT / ".github/workflows/code-quality.yml").read_text()
        self.assertIn("cp Packages/LocalVLM/csrc/prts_local_vlm.h", workflow)
        header = (ROOT / "Packages/LocalVLM/csrc/prts_local_vlm.h").read_text()
        for function in ("create", "set", "is_requested", "free"):
            self.assertIn(f"prts_vlm_cancel_{function}", header)
        self.assertNotIn("volatile int", header)
