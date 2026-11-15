#!/usr/bin/env python3
"""Copy PRTS recording data from a paired iPhone into one local ZIP, without launching the app."""

import argparse
import json
import subprocess
import tempfile
import zipfile
from pathlib import Path


def pack(source, output):
    """Use ZIP64 for long sessions; retain originals and relative file names."""
    with zipfile.ZipFile(output, "x", compression=zipfile.ZIP_STORED, allowZip64=True) as archive:
        for path in sorted(source.rglob("*")):
            if path.is_symlink():
                raise ValueError("Recording exports must not contain symbolic links")
            if path.is_file():
                archive.write(path, path.relative_to(source).as_posix())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True, help="Paired devicectl device identifier")
    parser.add_argument("--output", required=True, type=Path, help="New .zip output file")
    parser.add_argument("--bundle-id", default="com.jingxuan.PRTS")
    args = parser.parse_args()
    if args.output.exists() or args.output.suffix.lower() != ".zip":
        parser.error("--output must be a new .zip file")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="prts-recordings-") as temporary:
        directory = Path(temporary)
        result = directory / "copy-result.json"
        copied = directory / "recordings"
        subprocess.run(
            [
                "xcrun",
                "devicectl",
                "device",
                "copy",
                "from",
                "--device",
                args.device,
                "--domain-type",
                "appDataContainer",
                "--domain-identifier",
                args.bundle_id,
                "--source",
                "Documents/Recordings",
                "--destination",
                str(copied),
                "--timeout",
                "600",
                "--json-output",
                str(result),
            ],
            check=True,
        )
        if (
            not result.exists()
            or json.loads(result.read_text()).get("info", {}).get("outcome") != "success"
        ):
            raise SystemExit("The device did not confirm the copy")
        pack(copied, args.output)
    print(args.output.resolve())
    print("Run read_recording.py to verify. A live device copy can include an unfinished tail.")


if __name__ == "__main__":
    main()
