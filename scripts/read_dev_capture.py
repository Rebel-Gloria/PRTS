#!/usr/bin/env python3
"""Validate recording HEIC references and lossless evidence without decoding images or uploading."""

import argparse
import hashlib
import json
import math
import zlib
from pathlib import Path

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
    status = json.loads((folder / "recording-status.json").read_text())
    result = dict(
        source=manifest.get("source"),
        phase=status.get("phase"),
        samples=0,
        depthFrames=0,
        relativeFrames=0,
        missingDepth=0,
        sparseFeatures=0,
        meshReferences=0,
        issues=[],
        images=0,
        imagesDecoded=False,
        droppedSamples=status.get("droppedSamples", 0),
    )
    last_timestamp = -math.inf
    seen = set()
    for number, line in enumerate((folder / "samples.jsonl").read_text().splitlines(), 1):
        try:
            row = json.loads(line)
            identity = (row["epoch"], row["frameID"])
            if identity in seen:
                raise ValueError("duplicate frame identity")
            seen.add(identity)
            timestamp = row["timestamp"]
            if not math.isfinite(timestamp) or timestamp <= last_timestamp:
                raise ValueError("invalid source timestamp order")
            last_timestamp = timestamp
            image = row["image"]
            expected_name = f"{identity[0]}-{identity[1]}.heic"
            if image["file"] != expected_name:
                raise ValueError("image identity/path mismatch")
            path = (folder / image["file"]).resolve()
            if path.parent != folder.resolve():
                raise ValueError("image escapes folder")
            if path.stat().st_size != image["bytes"] or not 0 < image["bytes"] <= MAX_BYTES:
                raise ValueError("image size mismatch")
            data = path.read_bytes()
            if hashlib.sha256(data).hexdigest() != image["sha256"]:
                raise ValueError("image checksum mismatch")
            if len(data) < 16 or data[4:8] != b"ftyp":
                raise ValueError("invalid HEIC container")
            header_size = int.from_bytes(data[:4], "big")
            if not 16 <= header_size <= len(data):
                raise ValueError("invalid HEIC header size")
            heic_brands = {b"heic", b"heix"}
            if data[8:12] not in heic_brands and not any(
                data[i : i + 4] in heic_brands for i in range(16, header_size, 4)
            ):
                raise ValueError("missing HEIC brand")
            if image["width"] <= 0 or image["height"] <= 0:
                raise ValueError("invalid image dimensions")
            result["images"] += 1
            evidence = json.loads(decode(folder, row["evidence"]))
            analysis = evidence["analysis"]
            if (analysis["epoch"], analysis["frameID"]) != identity:
                raise ValueError("analysis identity mismatch")
            if analysis["timestamp"] != timestamp:
                raise ValueError("analysis timestamp mismatch")
            capture = evidence.get("capture")
            if capture and (
                capture["timestamp"] != timestamp
                or (capture["epoch"], capture["frameID"]) != identity
            ):
                raise ValueError("capture identity/timestamp mismatch")
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
    if status.get("phase") != "completed":
        result["issues"].append("recording ended with failure: " + status.get("stopReason", "unknown"))
    if result["samples"] != status.get("savedSamples"):
        result["issues"].append("saved sample count mismatch")
    result["note"] = (
        "HEIC container, checksums and evidence verified without image decoding. "
        "Run read_diag.py --verify-data on this directory for depth and full mesh attachments."
    )
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path, help="unzipped recording DIAG directory")
    args = parser.parse_args()
    summary = summarize(args.directory)
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    raise SystemExit(bool(summary["issues"]))
