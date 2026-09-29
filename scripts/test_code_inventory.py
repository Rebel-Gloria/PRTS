"""Inventory tests use synthetic source files, never modify the real checkout."""
from pathlib import Path
import tempfile
import unittest
from code_inventory import inventory, report


class InventoryTests(unittest.TestCase):
    def test_scopes_and_physical_lines(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name, contents in {
                "PRTS/App/Example.swift": "// comment\n\nlet n = 1\n",
                "Vendor/SpatialCore/Sources/SpatialCore/A.swift": "struct A {}\n",
                "Vendor/SpatialCore/.build/Generated.swift": "ignored",
                "Experiments/SpatialProbe/App/Old.swift": "ignored",
                "scripts/test_example.py": "# test\n",
                "scripts/read_example.py": "# tool\n",
                "PRTS/Assets.xcassets/icon.json": "{}",
            }.items():
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)
            rows = inventory(root)
            self.assertEqual(len(rows), 4)
            self.assertIn(("PRTS/App/Example.swift", "App", 3, 2), rows)
            self.assertIn("| Total | 4 | 6 | 5 |", report(rows))
            self.assertEqual(rows, sorted(rows))

    def test_empty_is_valid(self):
        with tempfile.TemporaryDirectory() as folder:
            self.assertEqual(inventory(Path(folder)), [])
            self.assertIn("| Total | 0 | 0 | 0 |", report([]))


if __name__ == "__main__":
    unittest.main()
