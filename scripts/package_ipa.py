#!/usr/bin/env python3
"""Package a real, unsigned iPhone build for re-signing; never publish CI stubs."""

import argparse
import hashlib
import json
import plistlib
import re
import shutil
import stat
import subprocess
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ASSET_LIMIT = 2 * 1024**3


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def model_checksums():
    entries = {}
    for line in (ROOT / "Packages/LocalVLM/models.sha256").read_text(encoding="utf-8").splitlines():
        digest, name = line.split()
        if not re.fullmatch(r"[a-f0-9]{64}", digest) or Path(name).name != name:
            raise ValueError("Invalid pinned model checksum")
        entries[name] = digest
    return entries


def validate_app(app, commit, expected_models):
    with (app / "Info.plist").open("rb") as source:
        info = plistlib.load(source)
    if info.get("CFBundlePackageType") != "APPL" or info.get("DTPlatformName") != "iphoneos":
        raise ValueError("Only a device application can be distributed")
    if info.get("PRTSCommit") != commit:
        raise ValueError("Application source commit does not match the tested commit")
    executable = info.get("CFBundleExecutable", "")
    if not executable or Path(executable).name != executable or not (app / executable).is_file():
        raise ValueError("Missing application executable")
    if (app / "embedded.mobileprovision").exists() or (app / "_CodeSignature").exists():
        raise ValueError("Expected an unsigned application")
    if not expected_models:
        raise ValueError("Missing pinned model inventory")
    for name, digest in expected_models.items():
        path = app / "LocalVLM" / name
        if not path.is_file() or sha256(path) != digest:
            raise ValueError("Missing, placeholder or mismatched model: " + name)
    return info


def write_ipa(app, destination, size_limit=ASSET_LIMIT):
    """Stream the app into Payload without another multi-gigabyte staging copy."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        raise FileExistsError(destination)
    partial = destination.with_suffix(".ipa.partial")
    if partial.exists():
        raise FileExistsError(partial)
    try:
        with zipfile.ZipFile(
            partial, "x", compression=zipfile.ZIP_DEFLATED, compresslevel=6
        ) as archive:
            for path in sorted(app.rglob("*")):
                member = "Payload/" + app.name + "/" + path.relative_to(app).as_posix()
                if path.is_symlink():
                    if not path.resolve().is_relative_to(app.resolve()):
                        raise ValueError("Application symlink escapes the bundle")
                    info = zipfile.ZipInfo(member)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    archive.writestr(info, str(path.readlink()))
                elif path.is_file():
                    archive.write(path, member)
        if partial.stat().st_size >= size_limit:
            raise ValueError("IPA exceeds the GitHub release asset limit of 2 GiB")
        with zipfile.ZipFile(partial) as archive:
            if archive.testzip() is not None:
                raise ValueError("IPA archive integrity check failed")
        partial.rename(destination)
    finally:
        partial.unlink(missing_ok=True)


def add_notices(app, library):
    notices = app / "ThirdPartyNotices"
    notices.mkdir(exist_ok=True)
    for source, name in (
        (ROOT / "LICENSE", "PRTS-MIT.txt"),
        (library / "LICENSE.llama.cpp", "llama.cpp-MIT.txt"),
        (ROOT / "PRTS/Spatial/Models/LICENSE-DepthAnythingV2.txt", "Apache-2.0.txt"),
    ):
        shutil.copyfile(source, notices / name)
    (notices / "Sources.txt").write_text(
        "PRTS: https://github.com/Rebel-Gloria/PRTS (MIT)\n"
        "llama.cpp: https://github.com/ggml-org/llama.cpp (MIT; built using prepare.sh)\n"
        "MiniCPM-V 4.7 1B: https://huggingface.co/openbmb/MiniCPM-V-4.7-1B-gguf (Apache-2.0)\n"
        "Depth Anything V2 Small: see the bundled AppleModelCard.txt (Apache-2.0)\n",
        encoding="utf-8",
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path)
    parser.add_argument("--configuration", required=True, choices=("Release", "Dev"))
    parser.add_argument("--commit", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-f0-9]{40}", args.commit):
        parser.error("--commit must be a full source SHA")
    app = args.app.resolve()
    if app.suffix != ".app":
        parser.error("Expected an .app bundle")
    models = model_checksums()
    info = validate_app(app, args.commit, models)
    executable = app / info["CFBundleExecutable"]
    architectures = subprocess.check_output(["lipo", "-archs", str(executable)], text=True).split()
    if architectures != ["arm64"]:
        raise ValueError("Expected an arm64 device executable")
    library = ROOT / "Packages/LocalVLM/PRTSLocalVLM.xcframework"
    # The test stub exposes prts_vlm_* but has no real llama model loader.
    archives = list(library.glob("ios-arm64/*.a"))
    if len(archives) != 1:
        raise ValueError("Missing device inference library")
    symbols = subprocess.check_output(["nm", "-gU", str(archives[0])], text=True)
    if not re.search(r"\bT _llama_model_load_from_file$", symbols, re.MULTILINE):
        raise ValueError("Refusing to package the test inference stub")
    add_notices(app, library)
    stem = f"PRTS-{args.configuration}-{args.commit[:12]}-unsigned"
    output = args.output / (stem + ".ipa")
    write_ipa(app, output)
    metadata = {
        "commit": args.commit,
        "configuration": args.configuration,
        "signed": False,
        "version": info["CFBundleShortVersionString"],
        "build": info["CFBundleVersion"],
        "bundleID": info["CFBundleIdentifier"],
        "minimumOS": info["MinimumOSVersion"],
        "models": models,
        "file": output.name,
        "bytes": output.stat().st_size,
        "sha256": sha256(output),
    }
    (args.output / (stem + ".json")).write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(json.dumps(metadata, indent=2))


if __name__ == "__main__":
    main()
