"""Guard replacement boundaries and the file references used by the build."""

import re
import unittest
from pathlib import Path

from swift_source import TOKEN, swift_code

ROOT = Path(__file__).resolve().parents[1]


class RepositoryLayoutTests(unittest.TestCase):
    def test_local_package_references_exist(self):
        project = (ROOT / "PRTS.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
        packages = re.findall(r"relativePath = ([^;]+);", project)
        self.assertTrue(packages)
        for package in packages:
            self.assertTrue((ROOT / package.strip('"') / "Package.swift").is_file(), package)

    def test_spatial_package_does_not_import_device_or_ui_frameworks(self):
        for file in (ROOT / "Packages/SpatialCore/Sources").rglob("*.swift"):
            imports = re.findall(r"^import (\w+)", file.read_text(encoding="utf-8"), re.M)
            self.assertFalse(
                set(imports) & {"ARKit", "UIKit", "SwiftUI", "AVFoundation", "Metal", "CoreML"},
                file,
            )

    def test_ar_session_has_one_product_owner(self):
        owners = [
            file.relative_to(ROOT).as_posix()
            for file in (ROOT / "PRTS").rglob("*.swift")
            if "ARSession()" in swift_code(file.read_text(encoding="utf-8"))
        ]
        self.assertEqual(owners, ["PRTS/Spatial/Runtime/ProbeEngine.swift"])

    def test_shared_capabilities_do_not_reference_feature_or_runtime_types(self):
        declarations = {}
        for directory in ("Features", "Spatial", "App"):
            for file in (ROOT / "PRTS" / directory).rglob("*.swift"):
                for name in re.findall(
                    r"^(?:nonisolated |public |final )*(?:enum|class|struct|protocol)\s+(\w+)",
                    file.read_text(encoding="utf-8"),
                    re.M,
                ):
                    declarations[name] = file.relative_to(ROOT).as_posix()
        for file in (ROOT / "PRTS/Shared").rglob("*.swift"):
            identifiers = {
                match.group()
                for match in TOKEN.finditer(file.read_text(encoding="utf-8"))
                if re.fullmatch(r"\w+", match.group())
            }
            self.assertFalse(identifiers & declarations.keys(), file)

    def test_photo_lifecycle_uses_injected_services(self):
        source = swift_code(
            (ROOT / "PRTS/Features/PhotoDescription/PhotoDescriptionCoordinator.swift").read_text(
                encoding="utf-8"
            )
        )
        for implementation in ("URLSession", "PhotoChatClient", "PhotoLocalModel"):
            self.assertNotIn(implementation, source)
        for boundary in ("PhotoRecognizing", "AnswerAudio", "PhotoDescriptionServices"):
            self.assertIn(boundary, source)

    def test_source_comparison_keeps_literal_content(self):
        self.assertEqual(swift_code("let x = 1; // comment"), swift_code("let x=1"))
        self.assertNotEqual(swift_code('let x = "a b"'), swift_code('let x = "ab"'))
        self.assertNotEqual(swift_code('let x = "//a"'), swift_code('let x = "//b"'))
        self.assertNotEqual(swift_code("let x = 1"), swift_code("let x = 2"))


if __name__ == "__main__":
    unittest.main()
