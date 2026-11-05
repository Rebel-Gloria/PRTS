"""Guard replacement boundaries and the file references used by the build."""

import re
import unittest
from pathlib import Path

from swift_source import swift_code, swift_identifiers, swift_types

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
        self.assert_layer_boundary("Shared", ("Features", "Spatial", "App"))

    def test_spatial_runtime_does_not_reference_feature_or_app_types(self):
        self.assert_layer_boundary("Spatial", ("Features", "App"))

    def assert_layer_boundary(self, layer, forbidden_layers):
        declarations = {}
        for directory in forbidden_layers:
            for file in (ROOT / "PRTS" / directory).rglob("*.swift"):
                for name in swift_types(file.read_text(encoding="utf-8")):
                    declarations[name] = file.relative_to(ROOT).as_posix()
        for file in (ROOT / "PRTS" / layer).rglob("*.swift"):
            identifiers = swift_identifiers(file.read_text(encoding="utf-8"))
            conflicts = {name: declarations[name] for name in identifiers & declarations.keys()}
            self.assertFalse(conflicts, f"{file.relative_to(ROOT)}: {conflicts}")

    def test_type_discovery_includes_attributed_and_multiline_declarations(self):
        source = """
            @MainActor final class PathHaptics {}
            @available(iOS 17, *) public struct Snapshot {}
            private nonisolated enum State {}
            @MainActor
            protocol Output {}
            actor Worker {}
            typealias Handler = Output
            struct Container { enum NestedOnly {} }
            class func refresh() {}
            // class CommentOnly {}
            let message = "struct LiteralOnly {}"
        """
        self.assertEqual(
            swift_types(source),
            {"PathHaptics", "Snapshot", "State", "Output", "Worker", "Handler", "Container"},
        )
        self.assertNotIn("CommentOnly", swift_identifiers(source))
        self.assertNotIn("LiteralOnly", swift_identifiers(source))

    def test_audio_session_has_one_product_owner(self):
        owners = [
            file.relative_to(ROOT).as_posix()
            for file in (ROOT / "PRTS").rglob("*.swift")
            if "AVAudioSession.sharedInstance()" in swift_code(file.read_text(encoding="utf-8"))
        ]
        self.assertEqual(owners, ["PRTS/Shared/Audio/AudioSessionCoordinator.swift"])

    def test_photo_backend_consumes_configuration_without_reading_preferences(self):
        backend = (
            ROOT / "PRTS/Features/PhotoDescription/Services/PhotoDescriptionBackend.swift"
        ).read_text()
        self.assertNotIn("UserDefaults", swift_identifiers(backend))
        self.assertNotIn("IntelligenceFeature", swift_identifiers(backend))
        self.assertNotIn("PhotoChatProvider", swift_identifiers(backend))

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
