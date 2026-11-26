"""Offline checks for the photo prompt experiment's credential destination."""

import importlib.util
import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from email.message import Message
from pathlib import Path
from unittest.mock import patch
from urllib.error import HTTPError
from urllib.request import HTTPSHandler
from urllib.response import addinfourl

SCRIPT = Path(__file__).resolve().parents[1] / "Experiments/photo-prompt/run_eval.py"
SPEC = importlib.util.spec_from_file_location("photo_eval", SCRIPT)
photo_eval = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(photo_eval)


class PhotoEvalTests(unittest.TestCase):
    def test_requires_explicit_https_service_and_its_token(self):
        with tempfile.TemporaryDirectory() as d:
            path = Path(d) / "service.json"
            with self.assertRaises(FileNotFoundError):
                photo_eval.read_service(path)
            for endpoint, token in [
                ("http://a.example/v1", "a"),
                ("https://user@a.example/v1", "a"),
                ("https://", "a"),
                ("https://a.example:70000/v1", "a"),
                ("https://a.example/v1?key=fixture-query", "a"),
                ("https://a.example/v1#fixture-fragment", "a"),
                ("https://a.example/v1", ""),
            ]:
                with self.subTest(endpoint=endpoint, token=token):
                    path.write_text(json.dumps({"endpoint": endpoint, "token": token}))
                    with self.assertRaises(ValueError) as error:
                        photo_eval.read_service(path)
                    self.assertNotIn(endpoint, str(error.exception))
            for host, token in [("a.example", "first"), ("b.example", "second")]:
                endpoint = f"https://{host}/v1/chat/completions"
                path.write_text(json.dumps({"endpoint": endpoint, "token": token}))
                self.assertEqual(photo_eval.read_service(path), (endpoint, token))

    def test_redirect_never_forwards_credentials_or_image(self):
        endpoint = "https://first.example/v1/chat/completions"
        for code in [301, 302, 303, 307, 308]:
            seen = []

            def redirect(_, request):
                seen.append((request.full_url, request.get_header("Authorization")))
                headers = Message()
                headers["Location"] = "https://second.example/other"
                response = addinfourl(io.BytesIO(b""), headers, request.full_url, code)
                response.msg = "Redirect"
                return response

            with self.subTest(code=code), patch.object(HTTPSHandler, "https_open", redirect):
                with self.assertRaises(HTTPError) as raised:
                    photo_eval.request_chat(endpoint, "test-only", {"messages": []})
                self.assertEqual(raised.exception.code, code)
                self.assertEqual(seen, [(endpoint, "Bearer test-only")])


class PhotoEvalResumeTests(unittest.TestCase):
    endpoint = "https://one.example/private-fixture/chat/completions"

    def setUp(self):
        root = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.config = root / "service.json"
        self.runs = root / "runs"
        self.runs.mkdir()
        (root / "prompts").mkdir()
        for name in ("first", "second"):
            (root / "prompts" / f"{name}.txt").write_text("synthetic prompt")
        (root / "image.bin").write_bytes(b"synthetic input")
        case = {
            "id": "case",
            "split": "调优",
            "image": "image.bin",
            "preprocess": {"sha256": "0" * 64},
            "tasks": [{"id": "q", "text": "test", "mode": "test", "trap": False}],
        }
        (root / "bench.json").write_text(json.dumps({"cases": [case]}))
        self.results = self.runs / "first_调优.jsonl"
        self.summary = self.runs / "first_调优_配置.json"
        self.enterContext(patch.object(photo_eval, "ROOT", root))
        self.enterContext(patch.object(photo_eval, "LEDGER", self.runs / "调用台账.jsonl"))
        self.request = self.enterContext(patch.object(photo_eval, "request_chat"))
        self.request.return_value = {"choices": [{"message": {"content": "synthetic answer"}}]}
        self.output = self.enterContext(redirect_stdout(io.StringIO()))

    def evaluate(self, endpoint, token="fixture-token-one", name="first", model=None):
        self.config.write_text(json.dumps({"endpoint": endpoint, "token": token}))
        argv = [
            "eval",
            name,
            "--service-config",
            str(self.config),
            "--models",
            model or photo_eval.MODELS[0],
        ]
        with patch.object(sys, "argv", argv):
            photo_eval.main()

    def archive(self):
        return {p.name: p.read_bytes() for p in self.runs.iterdir()}

    def assert_refused_without_changes(self, endpoint):
        before = self.archive()
        self.request.reset_mock()
        with self.assertRaisesRegex(SystemExit, "新轮次") as error:
            self.evaluate(endpoint)
        self.request.assert_not_called()
        self.assertEqual(self.archive(), before)
        self.assertNotIn(endpoint, str(error.exception))

    def test_resume_reuses_only_completed_jobs_and_token_rotation_is_not_a_new_service(self):
        self.evaluate(self.endpoint)
        self.assertEqual(self.request.call_count, 3)
        complete = self.archive()
        self.request.reset_mock()
        self.evaluate(self.endpoint)
        self.request.assert_not_called()
        self.assertEqual(self.archive(), complete)
        # Simulate an interrupted round: two completed records, no final summary.
        lines = self.results.read_bytes().splitlines(keepends=True)
        self.results.write_bytes(b"".join(lines[:2]))
        self.summary.unlink()
        canonical_alias = self.endpoint.replace("one.example", "ONE.example:443")
        self.evaluate(canonical_alias, token="fixture-token-two")
        self.request.assert_called_once()
        self.assertEqual(self.request.call_args.args[:2], (canonical_alias, "fixture-token-two"))
        self.assertTrue(self.results.read_bytes().startswith(b"".join(lines[:2])))
        rows = [json.loads(line) for line in self.results.read_text().splitlines()]
        fingerprint = json.loads(self.summary.read_text())["服务指纹"]
        self.assertRegex(fingerprint, r"^[0-9a-f]{64}$")
        self.assertEqual({row["服务指纹"] for row in rows}, {fingerprint})
        self.assertEqual(len({row["id"] for row in rows}), 3)
        output = b"".join(self.archive().values()) + self.output.getvalue().encode()
        for secret in (b"fixture-token-", b"one.example", b"private-fixture", b"Authorization"):
            self.assertNotIn(secret, output)

    def test_changed_host_port_or_path_requires_new_round(self):
        self.evaluate(self.endpoint)
        original = self.results.read_bytes(), self.summary.read_bytes()
        for changed in (
            self.endpoint.replace("one.example", "two.example"),
            self.endpoint.replace("one.example", "one.example:8443"),
            self.endpoint.replace("private-fixture", "another-route"),
        ):
            with self.subTest(endpoint=changed):
                self.assert_refused_without_changes(changed)
        self.evaluate(changed, name="second")
        self.assertEqual(self.request.call_count, 3)
        self.assertEqual((self.results.read_bytes(), self.summary.read_bytes()), original)
        self.assertNotEqual(
            json.loads(self.summary.read_text())["服务指纹"],
            json.loads((self.runs / "second_调优_配置.json").read_text())["服务指纹"],
        )
        # The source claim must work before the first result arrives, too.
        self.results.unlink()
        self.assert_refused_without_changes(changed)

    def test_resume_repairs_summary_if_interrupted_after_new_model_results(self):
        self.evaluate(self.endpoint)
        first_summary = self.summary.read_bytes()
        self.evaluate(self.endpoint, model=photo_eval.MODELS[1])
        self.summary.write_bytes(first_summary)
        rows = self.results.read_bytes()
        self.request.reset_mock()
        self.evaluate(self.endpoint, model=photo_eval.MODELS[1])
        self.request.assert_not_called()
        self.assertEqual(self.results.read_bytes(), rows)
        self.assertEqual(json.loads(self.summary.read_text())["模型"], sorted(photo_eval.MODELS))

    def test_legacy_or_mixed_archives_are_not_adopted(self):
        self.summary.write_text('{"模型": ["legacy"]}')
        self.assert_refused_without_changes(self.endpoint)
        self.summary.unlink()
        for success in (True, False):
            self.results.write_text(json.dumps({"id": "legacy", "成功": success}) + "\n")
            self.assert_refused_without_changes(self.endpoint)
        self.results.unlink()
        self.evaluate(self.endpoint)
        with self.results.open("a") as f:
            f.write('{"id": "unattributed", "成功": false}\n')
        self.assert_refused_without_changes(self.endpoint)
