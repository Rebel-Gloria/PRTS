import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from ci import check_permissions, quality

ROOT = Path(__file__).resolve().parents[1]


class QualityTests(unittest.TestCase):
    def test_only_repository_prose_can_reuse_macos_checks(self):
        for paths, expected in [
            ([("A", "docs/read me.md"), ("D", "README.md")], "docs"),
            ([("M", "PRTS/Features/Home/ContentView.swift")], "source"),
            ([("M", "PRTS/Features/Settings/UserGuide/basic.md")], "full"),
            ([("M", ".swift-format")], "full"),
            ([("M", ".github/workflows/code-quality.yml")], "full"),
            ([("D", "PRTS/a.swift"), ("A", "docs/a.md")], "full"),
            ([("D", "PRTS/a.swift"), ("A", "PRTS/b.swift")], "full"),
            ([("M", "Packages/SpatialCore/Package.swift")], "full"),
            ([], "full"),
        ]:
            with self.subTest(paths=paths):
                self.assertEqual(quality.file_mode(paths), expected)

    def test_incremental_requires_one_parent_and_completed_evidence(self):
        with (
            patch.object(quality.subprocess, "check_output", return_value=b"M\0docs/a.md\0"),
            patch.object(quality, "verified_parent") as verified,
        ):
            for event, parents in [
                ("workflow_dispatch", ["a"]),
                ("pull_request", ["a"]),
                ("push", []),
                ("push", ["a", "b"]),
            ]:
                self.assertEqual(quality.scope(event, parents, "a", "b")[0], "full")
            verified.assert_not_called()
            for result, mode in [(False, "full"), (True, "docs")]:
                verified.return_value = result
                self.assertEqual(quality.scope("push", ["a"], "a", "b")[0], mode)
            verified.side_effect = OSError()
            self.assertEqual(quality.scope("push", ["a"], "a", "b")[0], "full")

    def test_full_marker_matches_exact_tested_sha_and_all_jobs(self):
        jobs = [
            {"name": name, "conclusion": "success"}
            for name in (
                "Full checks a",
                "style-and-boundaries",
                "spatial-tests",
                "app-build (Dev)",
                "app-build (Release)",
            )
        ]
        self.assertTrue(quality.verified_jobs(jobs, "a"))
        self.assertFalse(quality.verified_jobs(jobs, "b"))
        jobs[-1]["conclusion"] = "skipped"
        self.assertFalse(quality.verified_jobs(jobs, "a"))
        self.assertFalse(quality.verified_jobs(jobs[1:], "a"))

    def test_bulk_push_dispatches_only_intermediate_shas_without_prerelease(self):
        workflow = (ROOT / ".github/workflows/code-quality.yml").read_text()
        with tempfile.TemporaryDirectory() as temp:
            subprocess.run(["git", "init", "-q", temp], check=True)
            shas = []
            for i in range(3):
                subprocess.run(
                    [
                        "git",
                        "-c",
                        "user.name=Test",
                        "-c",
                        "user.email=test@example.invalid",
                        "commit",
                        "-q",
                        "--allow-empty",
                        "-m",
                        str(i),
                    ],
                    cwd=temp,
                    check=True,
                )
                shas.append(
                    subprocess.check_output(
                        ["git", "rev-parse", "HEAD"], cwd=temp, text=True
                    ).strip()
                )
            script = 'gh() { echo "$*"; }\n' + (ROOT / "scripts/ci/dispatch-commits.sh").read_text()
            env = dict(os.environ, GITHUB_SHA=shas[-1], RUNNER_TEMP=temp)
            for before, expected in [(shas[0], [shas[1]]), (shas[1], [])]:
                result = subprocess.check_output(
                    ["bash", "-c", script], env=dict(env, BEFORE=before), cwd=temp, text=True
                )
                self.assertEqual(
                    result.splitlines(),
                    [
                        f"workflow run code-quality.yml --ref main -f verify_sha={sha}"
                        for sha in expected
                    ],
                )
        publish = workflow.split("  publish:\n", 1)[1]
        for gate in (
            "needs: full",
            "github.event_name == 'workflow_dispatch'",
            "github.ref == 'refs/heads/main'",
            "inputs.prerelease && !inputs.verify_sha",
        ):
            self.assertIn(gate, publish)
        self.assertIn(
            "on: workflow_call\n", (ROOT / ".github/workflows/prerelease.yml").read_text()
        )

    def test_missing_compiled_permission_fails(self):
        with tempfile.TemporaryDirectory() as root:
            app = Path(root)
            prompts = {
                f"NS{kind}UsageDescription": "prompt"
                for kind in ("Camera", "Microphone", "SpeechRecognition")
            }
            for name in (
                "Info.plist",
                "en.lproj/InfoPlist.strings",
                "zh-Hans.lproj/InfoPlist.strings",
            ):
                target = app / name
                target.parent.mkdir(exist_ok=True)
                target.write_bytes(plistlib.dumps(prompts, fmt=plistlib.FMT_BINARY))
            check_permissions.check(app)
            target.write_bytes(plistlib.dumps(dict(prompts, NSCameraUsageDescription="  ")))
            with self.assertRaisesRegex(ValueError, "NSCameraUsageDescription"):
                check_permissions.check(app)
