import hashlib
import json
from pathlib import Path
import tempfile
import unittest
import zlib
from read_dev_capture import decode

class DevCaptureCodecTests(unittest.TestCase):
    def fixture(self, root):
        raw = b'{"source":"synthetic_test"}'
        compressor = zlib.compressobj(wbits=-15)
        encoded = compressor.compress(raw) + compressor.flush()
        (root / "sample.deflate").write_bytes(encoded)
        return raw, dict(file="sample.deflate",codec="deflate-raw",sha256=hashlib.sha256(raw).hexdigest(),
                        compressedBytes=len(encoded),uncompressedBytes=len(raw))

    def test_raw_deflate(self):
        with tempfile.TemporaryDirectory() as d:
            raw, ref = self.fixture(Path(d))
            self.assertEqual(decode(Path(d), ref), raw)

    def test_reject_corruption_and_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            _, ref = self.fixture(Path(d))
            for changes in ({"file":"../sample.deflate"}, {"sha256":"bad"}, {"uncompressedBytes":1}, {"compressedBytes":0}):
                with self.assertRaises(ValueError):
                    decode(Path(d), dict(ref, **changes))

    def test_dev_code_is_compile_gated(self):
        root = Path(__file__).resolve().parents[1]
        source = (root / "PRTS/Spatial/DevCapture/DevCaptureRecorder.swift").read_text().strip()
        self.assertTrue(source.startswith("#if PRTS_DEV_CAPTURE"))
        self.assertTrue(source.endswith("#endif"))
        # Normal project settings must not silently opt in.
        self.assertNotIn("PRTS_DEV_CAPTURE", (root / "PRTS.xcodeproj/project.pbxproj").read_text())
