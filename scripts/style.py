#!/usr/bin/env python3
"""Check or format repository-owned sources with pinned tools; never downloads tools."""

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSIONS = {"swift": "6.2.0", "python": "0.14.0", "cpp": "21.1.0", "shell": "3.12.0"}
TOOLS = {"swift": "swift-format", "python": "ruff", "cpp": "clang-format", "shell": "shfmt"}
EXTENSIONS = {"swift": {".swift"}, "python": {".py"}, "cpp": {".cpp", ".h"}, "shell": {".sh"}}


def source_files():
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=ROOT,
        check=True,
        stdout=subprocess.PIPE,
    )
    return sorted(
        {
            name
            for name in result.stdout.decode("utf-8").split("\0")
            if name and not name.startswith("Vendor/PRTSCore/") and (ROOT / name).is_file()
        }
    )


def executable(language):
    name = TOOLS[language]
    command = os.environ.get(name.upper().replace("-", "_"))
    if not command and language == "shell":
        local = ROOT / "build/tools" / ("shfmt.exe" if os.name == "nt" else "shfmt")
        if local.is_file():
            command = str(local)
    command = command or shutil.which(name)
    if not command and language == "swift" and shutil.which("xcrun"):
        command = subprocess.check_output(["xcrun", "--find", name], text=True).strip()
    if not command:
        raise RuntimeError(f"Missing {name}; see docs/development.md for installation")
    version = subprocess.check_output([command, "--version"], text=True).strip()
    detected = re.search(r"\d+\.\d+\.\d+", version)
    if not detected or detected.group() != VERSIONS[language]:
        raise RuntimeError(f"Expected {name} {VERSIONS[language]}, found {version}")
    return command


def run(arguments):
    return subprocess.run(arguments, cwd=ROOT, check=False).returncode == 0


def check(language, files, fix):
    command = executable(language)
    print(f"{language}: {'formatting' if fix else 'checking'} {len(files)} files", flush=True)
    passed = True
    # Keep commands below Windows' command-line limit.
    for offset in range(0, len(files), 20):
        batch = files[offset : offset + 20]
        if language == "swift":
            args = ["format", "--in-place"] if fix else ["lint", "--strict"]
            passed = run([command, *args, "--configuration", ".swift-format", *batch]) and passed
        elif language == "python":
            if fix:
                run([command, "check", "--fix", *batch])
            passed = run([command, "format", *([] if fix else ["--check"]), *batch]) and passed
            passed = run([command, "check", *batch]) and passed
        elif language == "cpp":
            args = ["-i"] if fix else ["--dry-run", "--Werror"]
            passed = run([command, *args, *batch]) and passed
        else:
            passed = (
                run([command, "-i", "4", "-ci", "-sr", "-w" if fix else "-d", *batch]) and passed
            )
    return passed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fix", action="store_true", help="Apply formatting and safe Python fixes")
    parser.add_argument(
        "--language", choices=TOOLS, action="append", help="Limit languages locally"
    )
    args = parser.parse_args()
    files = source_files()
    passed = True
    for language in args.language or TOOLS:
        selected = [
            name
            for name in files
            if Path(name).suffix in EXTENSIONS[language]
            or (language == "cpp" and name.endswith(".metal.txt"))
        ]
        if selected:
            try:
                passed = check(language, selected, args.fix) and passed
            except (RuntimeError, subprocess.CalledProcessError, OSError) as error:
                print(error, file=sys.stderr)
                passed = False
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
