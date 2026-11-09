import hashlib
import json
import tempfile
import unittest
import zlib
from pathlib import Path

from read_dev_capture import decode, summarize


class DevCaptureCodecTests(unittest.TestCase):
    def fixture(self, root):
        raw = b'{"source":"synthetic_test"}'
        compressor = zlib.compressobj(wbits=-15)
        encoded = compressor.compress(raw) + compressor.flush()
        (root / "sample.deflate").write_bytes(encoded)
        return raw, dict(
            file="sample.deflate",
            codec="deflate-raw",
            sha256=hashlib.sha256(raw).hexdigest(),
            compressedBytes=len(encoded),
            uncompressedBytes=len(raw),
        )

    def test_raw_deflate(self):
        with tempfile.TemporaryDirectory() as d:
            raw, ref = self.fixture(Path(d))
            self.assertEqual(decode(Path(d), ref), raw)

    def test_reject_corruption_and_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            _, ref = self.fixture(Path(d))
            for changes in (
                {"file": "../sample.deflate"},
                {"sha256": "bad"},
                {"uncompressedBytes": 1},
                {"compressedBytes": 0},
            ):
                with self.assertRaises(ValueError):
                    decode(Path(d), dict(ref, **changes))

    def test_dev_code_is_compile_gated(self):
        root = Path(__file__).resolve().parents[1]
        files = list((root / "PRTS/Spatial/DevCapture").glob("*.swift")) + [
            root / "PRTS/Features/Home/RecordingControl.swift",
            root / "PRTS/Features/Settings/RecordingsSection.swift",
        ]
        for file in files:
            source = file.read_text().strip()
            self.assertTrue(source.startswith("#if PRTS_DEV_CAPTURE"), file)
            self.assertTrue(source.endswith("#endif"), file)
            self.assertNotIn("AVAssetWriter", source)
        self.assertFalse((root / "PRTS/Spatial/DevCapture/DevCaptureRecorder.swift").exists())
        # Normal project settings must not silently opt in.
        self.assertNotIn("PRTS_DEV_CAPTURE", (root / "PRTS.xcodeproj/project.pbxproj").read_text())

    def recording(self, root):
        evidence = {"analysis": {"epoch": 1, "frameID": 2, "timestamp": 10.0}}
        raw = json.dumps(evidence).encode()
        compressor = zlib.compressobj(wbits=-15)
        encoded = compressor.compress(raw) + compressor.flush()
        (root / "sample.deflate").write_bytes(encoded)
        image = b"\x00\x00\x00\x18ftypheic" + bytes(12)
        (root / "1-2.heic").write_bytes(image)
        row = dict(
            epoch=1,
            frameID=2,
            timestamp=10.0,
            image=dict(
                file="1-2.heic",
                bytes=len(image),
                width=1920,
                height=1440,
                sha256=hashlib.sha256(image).hexdigest(),
            ),
            evidence=dict(
                file="sample.deflate",
                codec="deflate-raw",
                compressedBytes=len(encoded),
                uncompressedBytes=len(raw),
                sha256=hashlib.sha256(raw).hexdigest(),
            ),
        )
        (root / "samples.jsonl").write_text(json.dumps(row) + "\n")
        (root / "manifest.json").write_text('{"source":"synthetic"}')
        (root / "recording-status.json").write_text(
            '{"phase":"completed","savedSamples":1,"droppedSamples":3}'
        )
        return row

    def test_heic_samples_without_video(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.recording(root)
            result = summarize(root)
            self.assertEqual(result["issues"], [])
            self.assertEqual(result["images"], 1)
            self.assertEqual(result["droppedSamples"], 3)
            self.assertFalse(result["imagesDecoded"])

    def test_missing_corrupt_duplicate_or_mismatched_image(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = self.recording(root)
            (root / "1-2.heic").unlink()
            self.assertTrue(summarize(root)["issues"])
            self.recording(root)
            (root / "1-2.heic").write_bytes(b"corrupt")
            self.assertTrue(summarize(root)["issues"])
            self.recording(root)
            (root / "samples.jsonl").write_text((json.dumps(row) + "\n") * 2)
            self.assertIn("duplicate frame identity", str(summarize(root)["issues"]))
            row["image"]["file"] = "../1-2.heic"
            (root / "samples.jsonl").write_text(json.dumps(row) + "\n")
            self.assertIn("image identity/path mismatch", str(summarize(root)["issues"]))

    def test_source_time_must_match_analysis(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            row = self.recording(root)
            row["timestamp"] = 11
            (root / "samples.jsonl").write_text(json.dumps(row) + "\n")
            self.assertIn("analysis timestamp mismatch", str(summarize(root)["issues"]))
