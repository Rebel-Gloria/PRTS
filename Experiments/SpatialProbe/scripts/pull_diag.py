#!/usr/bin/env python3
"""Copy only PRTS diagnostic data from a connected iPhone; does not launch camera or upload data."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--device", required=True, help="devicectl device identifier")
    p.add_argument("--output", required=True, type=Path)
    args = p.parse_args()
    if args.output.exists():
        p.error("Choose a new output directory to avoid overwriting previous evidence")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="probe-diag-copy-") as tmp:
        result = Path(tmp) / "result.json"
        command = ["xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                   "--domain-type", "appDataContainer", "--domain-identifier", "org.prts.SpatialProbe",
                   "--source", "Documents/Diagnostics", "--destination", str(args.output.resolve()),
                   "--timeout", "120", "--json-output", str(result)]
        completed = subprocess.run(command, check=False)
        if completed.returncode:
            raise SystemExit(completed.returncode)
        if not result.exists() or json.loads(result.read_text()).get("info", {}).get("outcome") != "success":
            raise SystemExit("Copy outcome could not be confirmed")
    print("Diagnostic data copied to", args.output.resolve())
    print("Run read_diag.py on one launch directory; --verify-data checks every saved attachment.")


if __name__ == "__main__":
    main()
