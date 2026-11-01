#!/usr/bin/env python3
"""Install the pinned, checksum-verified shell formatter into ignored build/tools."""

import hashlib
import os
import platform
import urllib.request
from pathlib import Path

VERSION = "3.12.0"
HASHES = {
    "darwin_amd64": "c31548693de6584e6164b7ed5fbb7b4a083f2d937ca94b4e0ddf59aa461a85e4",
    "darwin_arm64": "d903802e0ce3ecbc82b98512f55ba370b0d37a93f3f78de394f5b657052b33dd",
    "linux_amd64": "d9fbb2a9c33d13f47e7618cf362a914d029d02a6df124064fff04fd688a745ea",
    "linux_arm64": "5f3fe3fa6a9f766e6a182ba79a94bef8afedafc57db0b1ad32b0f67fae971ba4",
    "windows_amd64": "c8bda517ba1c640ce4a715c0fa665439ddbe4357ba5e9b77b0e51e70e2b9c94b",
}


def main():
    architecture = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64"}.get(
        platform.machine().lower(), platform.machine().lower()
    )
    target = f"{platform.system().lower()}_{architecture}"
    if target not in HASHES:
        raise SystemExit(f"Unsupported platform: {target}")
    suffix = ".exe" if os.name == "nt" else ""
    output = Path(__file__).resolve().parents[1] / "build/tools" / f"shfmt{suffix}"
    if output.exists() and hashlib.sha256(output.read_bytes()).hexdigest() == HASHES[target]:
        print(f"shfmt {VERSION} is ready")
        return
    url = f"https://github.com/mvdan/sh/releases/download/v{VERSION}/shfmt_v{VERSION}_{target}{suffix}"
    with urllib.request.urlopen(url, timeout=60) as response:
        data = response.read()
    if hashlib.sha256(data).hexdigest() != HASHES[target]:
        raise SystemExit("shfmt checksum mismatch; nothing installed")
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    output.chmod(0o755)
    print(f"Installed shfmt {VERSION} in {output.parent}")


if __name__ == "__main__":
    main()
