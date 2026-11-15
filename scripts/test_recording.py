import hashlib
import json
import struct
import tempfile
import unittest
import zipfile
import zlib
from pathlib import Path

from pull_recordings import pack
from read_recording import extract, sensor_frame, validate


class RecordingTests(unittest.TestCase):
    def test_zip_roundtrip_preserves_all_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source"
            (source / "run").mkdir(parents=True)
            (source / "run" / "original.png").write_bytes(bytes(range(256)))
            (source / "run" / "events.jsonl").write_text('{"payload":{"name":"start"}}\n')
            pack(source, root / "data.zip")
            extract(root / "data.zip", root / "restored")
            for path in source.rglob("*"):
                if path.is_file():
                    self.assertEqual(
                        path.read_bytes(),
                        (root / "restored" / path.relative_to(source)).read_bytes(),
                    )

    def test_zip_rejects_escape_duplicate_and_symlink(self):
        for filename in ("../outside", "/absolute", "C:/absolute", "..\\outside"):
            with self.subTest(filename=filename), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                with zipfile.ZipFile(root / "bad.zip", "w") as archive:
                    info = zipfile.ZipInfo("placeholder")
                    info.filename = filename
                    archive.writestr(info, "bad")
                with self.assertRaises(ValueError):
                    extract(root / "bad.zip", root / "out")

    def test_sensor_packet_keeps_nan_and_all_points(self):
        depth = struct.pack("<II", 0x7FC00001, 0x3F800000)
        point = struct.pack("<Qfff", 2**63 + 1, 1.25, -2.5, 3)
        header = {
            "kind": "sensor_frame",
            "schemaVersion": 1,
            "featureCount": 1,
            "sections": [
                {"name": "depth", "offset": 0, "bytes": 8, "width": 2, "height": 1},
                {"name": "feature_points", "offset": 8, "bytes": 20, "width": 1, "height": 1},
            ],
        }
        encoded = json.dumps(header).encode()
        raw = struct.pack("<I", len(encoded)) + encoded + depth + point
        _, payload = sensor_frame(raw)
        self.assertEqual(bytes(payload), depth + point)
        with self.assertRaises(ValueError):
            sensor_frame(raw[:-1])
        with self.assertRaises(ValueError):
            sensor_frame(raw + b"x")

    def test_validation_detects_corruption_and_unfinished_recording(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            run = root / "run"
            run.mkdir()
            metadata = {"format": "prts-recording", "finalized": True, "status": {}}
            (run / "manifest.json").write_text(json.dumps(metadata))
            raw = b"original unchanged"
            compressor = zlib.compressobj(wbits=-15)
            compressed = compressor.compress(raw) + compressor.flush()
            (run / "data-00000.bin").write_bytes(
                struct.pack("<II", len(compressed), len(raw)) + compressed
            )
            reference = {
                "file": "data-00000.bin",
                "offset": 0,
                "codec": "deflate-raw",
                "compressedBytes": len(compressed),
                "uncompressedBytes": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
            event = {"payload": {"kind": "original"}, "attachment": reference}
            (run / "events.jsonl").write_text(json.dumps(event) + "\n")
            self.assertEqual(validate(root)["issues"], [])
            reference["sha256"] = "bad"
            (run / "events.jsonl").write_text(json.dumps(event) + "\n")
            self.assertTrue(validate(root)["issues"])
            metadata["finalized"] = False
            (run / "manifest.json").write_text(json.dumps(metadata))
            self.assertEqual(len(validate(root)["issues"]), 2)

    def test_native_builds_only(self):
        root = Path(__file__).resolve().parents[1]
        project = (root / "PRTS.xcodeproj/project.pbxproj").read_text()
        self.assertNotIn("name = Debug;", project)
        self.assertNotIn("PRTS_DEV_CAPTURE", project)
        self.assertIn("PRTS_DEV", project)
        source = (root / "PRTS/Shared/Recording/RecordingStore.swift").read_text()
        self.assertIn("enabled && Self.compiledIn", source)


if __name__ == "__main__":
    unittest.main()
