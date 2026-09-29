#!/usr/bin/env python3
"""Validate dev-capture samples and lossless attachments. Does not decode video or upload data."""
import argparse
import hashlib
import json
from pathlib import Path
import zlib

from read_diag import depth_frame

MAX_BYTES = 64 * 1024 * 1024

def decode(folder, ref):
    name = ref["file"]
    if not isinstance(name, str) or Path(name).name != name or "\\" in name or name in (".", ".."):
        raise ValueError("unsafe attachment path")
    if ref["codec"] != "deflate-raw":
        raise ValueError("unsupported codec")
    compressed, expected = ref["compressedBytes"], ref["uncompressedBytes"]
    if not 0 < compressed <= MAX_BYTES or not 0 < expected <= MAX_BYTES:
        raise ValueError("attachment exceeds limits")
    path = (folder / name).resolve()
    if path.parent != folder.resolve():
        raise ValueError("attachment escapes folder")
    if path.stat().st_size != compressed:
        raise ValueError("compressed size mismatch")
    decoder = zlib.decompressobj(-15)
    raw = decoder.decompress(path.read_bytes(), expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("uncompressed size/stream mismatch")
    if hashlib.sha256(raw).hexdigest() != ref["sha256"]:
        raise ValueError("checksum mismatch")
    return raw

def summarize(folder):
    manifest = json.loads((folder / "manifest.json").read_text())
    status = json.loads((folder / "status.json").read_text())
    result = dict(source=manifest.get("source"), phase=status.get("phase"), samples=0,
                  depthFrames=0, relativeFrames=0, missingDepth=0, sparseFeatures=0,
                  meshReferences=0, issues=[], videoDecoded=False)
    last_pts = -1.0
    seen = set()
    for number, line in enumerate((folder / "samples.jsonl").read_text().splitlines(), 1):
        try:
            row = json.loads(line)
            identity = (row["epoch"], row["frameID"])
            if identity in seen:
                raise ValueError("duplicate frame identity")
            seen.add(identity)
            pts = row["videoPTSValue"] / row["videoPTSTimescale"]
            if pts <= last_pts or abs(pts - (row["timestamp"] - manifest["originARTimestamp"])) > 1/60000:
                raise ValueError("invalid video/source timestamp mapping")
            last_pts = pts
            evidence = json.loads(decode(folder, row["evidence"]))
            analysis = evidence["analysis"]
            if (analysis["epoch"], analysis["frameID"]) != identity:
                raise ValueError("analysis identity mismatch")
            if row.get("depth"):
                header, _, _ = depth_frame(decode(folder, row["depth"]))
                if (header["epoch"], header["frameID"]) != identity:
                    raise ValueError("depth identity mismatch")
                result["depthFrames"] += 1
            else:
                result["missingDepth"] += 1
            if row.get("relative"):
                raw = decode(folder, row["relative"])
                model = evidence["model"]
                if len(raw) != model["width"] * model["height"] * 4:
                    raise ValueError("relative output shape mismatch")
                result["relativeFrames"] += 1
            result["sparseFeatures"] += len(evidence.get("sparseFeatures", []))
            result["meshReferences"] += len(evidence.get("meshReferences", []))
            result["samples"] += 1
        except (ValueError, KeyError, OSError, TypeError, ZeroDivisionError) as error:
            result["issues"].append(f"line {number}: {error}")
    if not (folder / "camera.mp4").is_file():
        result["issues"].append("missing camera.mp4")
    if status.get("phase") != "completed":
        result["issues"].append("capture not finalized; video may be incomplete")
    result["note"] = "Index and attachments verified only; verify MP4 playback/PTS on device. Mesh payloads are in parent DIAG and must be checked separately."
    return result

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="dev-capture-* directory inside a DIAG run")
    args = parser.parse_args()
    summary = summarize(args.directory)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    raise SystemExit(bool(summary["issues"]))
