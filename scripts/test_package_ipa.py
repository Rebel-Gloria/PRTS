import hashlib
import os
import plistlib
import tempfile
import unittest
import zipfile
from pathlib import Path

from package_ipa import model_checksums, validate_app, write_ipa


class PackageIPATests(unittest.TestCase):
    def fixture(self, root):
        app = root / "PRTS.app"
        (app / "LocalVLM").mkdir(parents=True)
        info = {
            "CFBundlePackageType": "APPL",
            "DTPlatformName": "iphoneos",
            "CFBundleExecutable": "PRTS",
            "PRTSCommit": "a" * 40,
        }
        (app / "Info.plist").write_bytes(plistlib.dumps(info))
        (app / "PRTS").write_bytes(b"executable")
        (app / "PRTS").chmod(0o755)
        (app / "LocalVLM/model.gguf").write_bytes(b"real test model bytes")
        checksums = {"model.gguf": hashlib.sha256(b"real test model bytes").hexdigest()}
        return app, info, checksums

    def test_rejects_placeholder_weights_wrong_commit_and_simulator(self):
        with tempfile.TemporaryDirectory() as temporary:
            app, info, checksums = self.fixture(Path(temporary))
            self.assertEqual(validate_app(app, "a" * 40, checksums), info)
            with self.assertRaises(ValueError):
                validate_app(app, "b" * 40, checksums)
            info["DTPlatformName"] = "iphonesimulator"
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                validate_app(app, "a" * 40, checksums)
            info["DTPlatformName"] = "iphoneos"
            (app / "Info.plist").write_bytes(plistlib.dumps(info))
            (app / "LocalVLM/model.gguf").write_bytes(b"")
            with self.assertRaises(ValueError):
                validate_app(app, "a" * 40, checksums)

    def test_payload_layout_and_size_failure_preserve_existing_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, _, _ = self.fixture(root)
            output = root / "build.ipa"
            write_ipa(app, output)
            with zipfile.ZipFile(output) as archive:
                self.assertEqual(archive.read("Payload/PRTS.app/PRTS"), b"executable")
                if os.name == "posix":
                    mode = archive.getinfo("Payload/PRTS.app/PRTS").external_attr >> 16
                    self.assertEqual(mode & 0o111, 0o111)
                self.assertTrue(
                    all(name.startswith("Payload/PRTS.app/") for name in archive.namelist())
                )
                self.assertIsNone(archive.testzip())
            original = output.read_bytes()
            with self.assertRaises(FileExistsError):
                write_ipa(app, output)
            self.assertEqual(output.read_bytes(), original)
            rejected = root / "oversized.ipa"
            with self.assertRaises(ValueError):
                write_ipa(app, rejected, size_limit=1)
            self.assertFalse(rejected.exists())
            self.assertFalse(rejected.with_suffix(".ipa.partial").exists())

    def test_existing_partial_is_not_deleted(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            app, _, _ = self.fixture(root)
            partial = root / "build.ipa.partial"
            partial.write_bytes(b"previous attempt")
            with self.assertRaises(FileExistsError):
                write_ipa(app, root / "build.ipa")
            self.assertEqual(partial.read_bytes(), b"previous attempt")

    def test_model_inventory_is_pinned_and_shared_with_preparation(self):
        self.assertEqual(len(model_checksums()), 2)
        root = Path(__file__).resolve().parents[1]
        prepare = (root / "Packages/LocalVLM/prepare.sh").read_text(encoding="utf-8")
        self.assertIn('done < "$here/models.sha256"', prepare)


if __name__ == "__main__":
    unittest.main()
