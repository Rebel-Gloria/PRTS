#!/usr/bin/env python3
"""Validate a PRTS recording ZIP/directory and expose its recorded spatial inputs for replay."""

import argparse
import json
import re
import struct
import tempfile
import zipfile
from pathlib import Path, PurePosixPath

from read_diag import attachment, depth_frame, records


def extract(archive_path, output):
    """Never follow archive paths or overwrite existing evidence."""
    output.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(archive_path) as archive:
        seen = set()
        for item in archive.infolist():
            path = PurePosixPath(item.filename)
            if (
                path.is_absolute()
                or ".." in path.parts
                or "\\" in item.filename
                or ":" in item.filename
                or (item.external_attr >> 16) & 0o170000 == 0o120000
                or item.filename in seen
            ):
                raise ValueError("Unsafe or duplicate ZIP member: " + item.filename)
            seen.add(item.filename)
        archive.extractall(output)


def sensor_frame(raw):
    if len(raw) < 4:
        raise ValueError("Missing sensor header")
    length = struct.unpack_from("<I", raw)[0]
    if not 0 < length <= len(raw) - 4:
        raise ValueError("Invalid sensor header length")
    header = json.loads(raw[4 : 4 + length])
    if header.get("kind") != "sensor_frame" or header.get("schemaVersion") != 1:
        raise ValueError("Unsupported sensor packet")
    payload = memoryview(raw)[4 + length :]
    end = 0
    names = set()
    for section in header["sections"]:
        name, offset, size = (section[k] for k in ("name", "offset", "bytes"))
        width, height = section["width"], section["height"]
        if not all(
            isinstance(x, int) and not isinstance(x, bool) for x in (offset, size, width, height)
        ):
            raise ValueError("Invalid sensor dimensions")
        if name in names or offset != end or size < 0 or offset + size > len(payload):
            raise ValueError("Invalid sensor section")
        if width < 0 or height < 0:
            raise ValueError("Negative sensor dimensions")
        if name == "feature_points":
            expected = header["featureCount"] * 20
        elif name in ("depth", "smoothed_depth"):
            expected = width * height * 4
        elif name in ("confidence", "smoothed_confidence"):
            expected = width * height
        else:
            raise ValueError("Unknown sensor section")
        if size != expected:
            raise ValueError("Sensor dimensions do not match payload")
        names.add(name)
        end += size
    if end != len(payload):
        raise ValueError("Trailing sensor bytes")
    return header, payload


def audio_packets(raw):
    """Decode the native PCM container without changing sample bits or channel layout."""
    position = 0
    packets = []
    while position < len(raw):
        if len(raw) - position < 4:
            raise ValueError("Missing audio packet header")
        length = struct.unpack_from("<I", raw, position)[0]
        position += 4
        if not 0 < length <= len(raw) - position:
            raise ValueError("Invalid audio header length")
        header = json.loads(raw[position : position + length])
        position += length
        sizes = header["bufferByteCounts"]
        if not sizes or not all(isinstance(size, int) and size >= 0 for size in sizes):
            raise ValueError("Invalid audio buffer sizes")
        if header["sampleRate"] <= 0 or header["channels"] <= 0 or header["frameLength"] <= 0:
            raise ValueError("Invalid audio format")
        if sum(sizes) > len(raw) - position:
            raise ValueError("Truncated audio samples")
        buffers = []
        for size in sizes:
            buffers.append(memoryview(raw)[position : position + size])
            position += size
        packets.append((header, buffers))
    return packets


def validate(directory):
    issues = []
    runs = []
    for manifest in sorted(directory.rglob("manifest.json")):
        run = manifest.parent
        metadata = json.loads(manifest.read_text(encoding="utf-8"))
        if metadata.get("format") != "prts-recording":
            continue
        count = 0
        video_files = set()
        actual_counts = {}
        sequences = set()
        strict = metadata.get("schemaVersion", 0) >= 3
        expected_counts = metadata.get("recordCounts")
        if strict and not isinstance(expected_counts, dict):
            issues.append({"run": run.name, "error": "Missing per-segment record counts"})
            expected_counts = {}
        if not strict:
            issues.append(
                {"run": run.name, "error": "Legacy manifest cannot verify stream completeness"}
            )
        for path in sorted(run.glob("*.jsonl")):
            actual_counts[path.stem] = 0
            for record in records(path, issues):
                actual_counts[path.stem] += 1
                count += 1
                try:
                    sequence = record.get("sequence")
                    if strict:
                        if type(sequence) is not int or sequence <= 0 or sequence in sequences:
                            raise ValueError("Invalid or duplicate record sequence")
                        sequences.add(sequence)
                    raw = attachment(run, record["attachment"]) if "attachment" in record else None
                    if path.name == "capture.jsonl" and raw is not None:
                        sensor_frame(raw)
                    if path.name == "analysis.jsonl" and raw is not None:
                        depth_frame(raw)
                    if record["payload"].get("kind") == "microphone_audio" and raw is not None:
                        audio_packets(raw)
                    if path.name == "video.jsonl":
                        payload = record["payload"]
                        name = payload["file"]
                        if not re.fullmatch(r"rgb-[A-Za-z0-9-]+\.mp4", name):
                            raise ValueError("Invalid video path")
                        if not (run / name).is_file() or (run / name).is_symlink():
                            raise ValueError("Missing video")
                        if payload["width"] <= 0 or payload["height"] <= 0 or payload["pts"] < 0:
                            raise ValueError("Invalid video dimensions/timestamp")
                        video_files.add(name)
                except (ValueError, KeyError, OSError, TypeError) as error:
                    issues.append({"file": str(path.relative_to(directory)), "error": str(error)})
        if strict:
            for stream in set(actual_counts) | set(expected_counts):
                expected = expected_counts.get(stream, 0)
                actual = actual_counts.get(stream, 0)
                if type(expected) is not int or expected < 0 or actual != expected:
                    issues.append(
                        {
                            "run": run.name,
                            "error": "Record count mismatch",
                            "stream": stream,
                            "expected": expected,
                            "actual": actual,
                        }
                    )
                elif expected > 0 and stream not in actual_counts:
                    issues.append(
                        {"run": run.name, "error": "Missing record stream", "stream": stream}
                    )
            last = metadata.get("lastSequence")
            if (
                type(last) is not int
                or last < 0
                or len(sequences) != last
                or (sequences and (min(sequences) != 1 or max(sequences) != last))
            ):
                issues.append({"run": run.name, "error": "Record sequence is incomplete"})
        status = metadata.get("status", {})
        if not metadata.get("finalized"):
            issues.append(
                {"run": run.name, "error": "Unfinished recording; final tail may be missing"}
            )
        if (
            status.get("error")
            or any(status.get("dropped", {}).values())
            or any(status.get("failed", {}).values())
        ):
            issues.append(
                {
                    "run": run.name,
                    "error": "Recorder reports missing or failed data",
                    "status": status,
                }
            )
        runs.append({"run": run.name, "records": count, "videos": len(video_files)})
    if not runs:
        issues.append({"error": "No PRTS recording manifests found"})
    return {"runs": runs, "issues": issues, "videoDecodeVerified": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument(
        "--extract-to", type=Path, help="New directory; keeps data for read_diag/replay tools"
    )
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="prts-read-") as temporary:
        if args.source.is_file():
            directory = args.extract_to or Path(temporary) / "unpacked"
            extract(args.source, directory)
        else:
            if args.extract_to:
                parser.error("--extract-to is only for ZIP input")
            directory = args.source
        report = validate(directory)
        print(json.dumps(report, ensure_ascii=False, indent=2))
        if report["issues"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
