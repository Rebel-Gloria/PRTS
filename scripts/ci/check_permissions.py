"""Check compiled permission prompts, not just the source catalogs."""

import plistlib
import sys
from pathlib import Path


def check(app):
    for name in ("Info.plist", "en.lproj/InfoPlist.strings", "zh-Hans.lproj/InfoPlist.strings"):
        with (app / name).open("rb") as f:
            values = plistlib.load(f)
        for key in (
            "NSCameraUsageDescription",
            "NSMicrophoneUsageDescription",
            "NSSpeechRecognitionUsageDescription",
        ):
            if not isinstance(values.get(key), str) or not values[key].strip():
                raise ValueError(f"{name}: missing {key}")


if __name__ == "__main__":
    check(Path(sys.argv[1]))
