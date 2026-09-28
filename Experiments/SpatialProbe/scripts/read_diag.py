#!/usr/bin/env python3
"""Read local PRTS Diagnostics exports. No network or image generation.
Reports data gaps honestly; depth frames are measurements, not safety ground truth.
"""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib
from summarize_session import stats

MAX_ATTACHMENT = 64 * 1024 * 1024


def records(path, issues):
    if not path.exists():
        return
    with path.open("rb") as f:
        for n, line in enumerate(f, 1):
            try:
                if not line.endswith(b"\n"):
                    raise ValueError("unfinished line; possible interrupted write")
                value = json.loads(line)
                if not isinstance(value, dict) or not isinstance(value.get("payload"), dict):
                    raise ValueError("invalid diagnostic envelope")
                yield value
            except (ValueError, UnicodeDecodeError) as e:
                issues.append({"file": path.name, "line": n, "error": str(e)})


def attachment(directory, ref):
    name = ref.get("file", "")
    if not re.fullmatch(r"data-[0-9]{5,}\.bin", name) or ref.get("codec") != "deflate-raw":
        raise ValueError("invalid attachment filename or codec")
    offset, length, expected = (ref.get(k) for k in ("offset", "compressedBytes", "uncompressedBytes"))
    if not all(isinstance(x, int) and not isinstance(x, bool) for x in (offset, length, expected)):
        raise ValueError("invalid attachment sizes")
    if offset < 0 or not 0 < length <= MAX_ATTACHMENT or not 0 <= expected <= MAX_ATTACHMENT:
        raise ValueError("attachment outside size bounds")
    path = directory / name
    if path.is_symlink():
        raise ValueError("attachment must not be a symlink")
    with path.open("rb") as f:
        f.seek(offset)
        header = f.read(8)
        if len(header) != 8 or struct.unpack("<II", header) != (length, expected):
            raise ValueError("missing/mismatched binary header")
        encoded = f.read(length)
        if len(encoded) != length:
            raise ValueError("truncated binary payload")
    decoder = zlib.decompressobj(-15)
    raw = decoder.decompress(encoded, expected + 1)
    if len(raw) != expected or not decoder.eof or decoder.unused_data or decoder.unconsumed_tail:
        raise ValueError("invalid decompressed size or stream")
    if hashlib.sha256(raw).hexdigest() != ref.get("sha256"):
        raise ValueError("attachment checksum mismatch")
    return raw


def depth_frame(raw):
    if len(raw) < 4:
        raise ValueError("missing depth header")
    size = struct.unpack_from("<I", raw)[0]
    if not 0 < size <= len(raw) - 4:
        raise ValueError("invalid depth header length")
    header = json.loads(raw[4:4 + size])
    if header.get("kind") != "depth_frame" or header.get("schemaVersion") != 1:
        raise ValueError("unsupported depth container")
    w, h = header.get("width"), header.get("height")
    if not isinstance(w, int) or not isinstance(h, int) or w <= 0 or h <= 0 or w * h > MAX_ATTACHMENT // 4:
        raise ValueError("invalid depth dimensions")
    count = w * h
    if header.get("depthBytes") != count * 4 or header.get("confidenceBytes") not in (0, count):
        raise ValueError("depth/confidence byte count mismatch")
    support = header.get("predictionSupportBytes", 0)
    if support not in (0, count):
        raise ValueError("prediction support byte count mismatch")
    if support and (header.get("confidenceBytes") or header.get("depthEvidence") != "model_prediction_arkit_aligned_not_sensor_confidence"):
        raise ValueError("prediction support cannot masquerade as sensor confidence")
    pos = 4 + size
    if len(raw) != pos + header["depthBytes"] + header["confidenceBytes"] + support:
        raise ValueError("depth payload length mismatch")
    return header, raw[pos:pos + count * 4], raw[pos + count * 4:pos + count * 4 + header["confidenceBytes"]]


def relative_frame(raw):
    if len(raw) < 4:
        raise ValueError("missing prediction header")
    size = struct.unpack_from("<I", raw)[0]
    if not 0 < size <= len(raw) - 4:
        raise ValueError("invalid prediction header length")
    header = json.loads(raw[4:4 + size])
    w, h = header.get("width"), header.get("height")
    if header.get("schemaVersion") != 1 or header.get("kind") != "relative_depth_frame" or header.get("units") != "relative_inverse_depth_not_meters":
        raise ValueError("unsupported prediction container or ambiguous units")
    if not isinstance(w, int) or not isinstance(h, int) or w <= 0 or h <= 0 or w*h > MAX_ATTACHMENT//4:
        raise ValueError("invalid prediction dimensions")
    if header.get("depthBytes") != w*h*4 or len(raw) != 4+size+w*h*4:
        raise ValueError("prediction payload length mismatch")
    return header, raw[4+size:]


def mesh_frame(raw):
    """Read full build 5 binary mesh; legacy JSON mesh remains supported by the caller."""
    if len(raw) < 4:
        raise ValueError("missing mesh header")
    size = struct.unpack_from("<I", raw)[0]
    if not 0 < size <= len(raw) - 4:
        raise ValueError("invalid mesh header length")
    header = json.loads(raw[4:4 + size])
    if header.get("kind") != "mesh_frame" or header.get("schemaVersion") != 1:
        raise ValueError("unsupported mesh container")
    v, i, c = (header.get(k) for k in ("vertexCount", "indexCount", "classificationCount"))
    if not all(isinstance(n, int) and not isinstance(n, bool) for n in (v, i, c)) or not (0 <= v <= 150_000 and 0 <= i <= 600_000 and i % 3 == 0 and c == i // 3):
        raise ValueError("invalid mesh counts")
    pos = 4 + size
    if len(raw) != pos + v * 12 + i * 4 + c:
        raise ValueError("mesh payload length mismatch")
    vertices, indices, classes = raw[pos:pos + v * 12], raw[pos + v * 12:pos + v * 12 + i * 4], raw[pos + v * 12 + i * 4:]
    if any(index >= v for (index,) in struct.iter_unpack("<I", indices)):
        raise ValueError("mesh index outside vertex array")
    import math
    if any(not math.isfinite(x) for (x,) in struct.iter_unpack("<f", vertices)):
        raise ValueError("non-finite mesh vertex")
    return header, vertices, indices, classes


def summarize(directory, verify=False):
    manifest = json.loads((directory / "manifest.json").read_text())
    issues = []
    output = {"runID": manifest.get("runID"), "source": manifest.get("source"), "metadata": manifest.get("metadata"),
              "launchedAt": manifest.get("launchedAt"), "status": None,
              "counts": {}, "tracking": {}, "depthReadStatus": {}, "modelBlockReasons": {},
              "modelStates": {}, "geometryGateReasons": {}, "guidanceGateReasons": {},
              "renderPhases": {}, "attachmentVerified": 0, "attachmentErrors": [],
              "note": "Analysis frames are not display frames. A rendered overlay is not proof of accurate/safe geometry. No RGB is recorded."}
    if (directory / "status.json").exists():
        output["status"] = json.loads((directory / "status.json").read_text())
    tracking, depth, blocks, models, geometry, guidance, phases = (Counter() for _ in range(7))
    reference_modes, surface_modes = Counter(), Counter()
    ages, coverage = [], []
    scale_reasons, prediction_ground = Counter(), Counter()
    temporal_errors, temporal_inliers = [], []
    confirmed_predictions = provisional_fits = 0
    raw_frames = models_present = moving_models = 0
    path_reasons, haptic_status, pulse_kinds = Counter(), Counter(), Counter()
    goal_changes, goal_ids, held_without_path = Counter(), set(), 0
    path_lengths, path_ms, path_angles = [], [], []
    path_targets, path_approaches, path_reachable = [], [], []
    path_approach_renders = path_target_renders = 0
    path_present = path_renders = historical_path_renders = 0
    for stream in ("events", "capture", "analysis", "render", "mesh", "heartbeat", "prediction", "path"):
        count = 0
        for row in records(directory / (stream + ".jsonl"), issues):
            count += 1
            p = row["payload"]
            if stream == "capture":
                tracking[p.get("tracking", "missing")] += 1
            elif stream == "analysis":
                frame, diagnostic = p.get("frame", {}), p.get("diagnostics") or {}
                depth[diagnostic.get("depthReadStatus", "missing")] += 1
                models[diagnostic.get("modelState", "missing")] += 1
                blocks.update(diagnostic.get("modelBlockReasons", []))
                reference_modes[diagnostic.get("groundReferenceMode") or "legacy_or_unavailable"] += 1
                ages.append(frame.get("metrics", {}).get("sourceAgeMS"))
                coverage.append(frame.get("validDepthCoverage"))
                if frame.get("surfaceModel") is not None:
                    models_present += 1
                    moving_models += frame.get("sourceDirectionStable") is False
                raw_frames += "attachment" in row
                if p.get("depthAttachmentExpected") and "attachment" not in row:
                    issues.append({"file": "analysis.jsonl", "sequence": row.get("sequence"), "error": "depth expected but attachment absent"})
            elif stream == "prediction" and not p.get("manual", False):
                decision = p.get("scaleDecision") or {}
                scale_reasons[decision.get("reason", "legacy_unavailable")] += 1
                prediction_ground[(p.get("groundReference") or {}).get("mode", "legacy_unavailable")] += 1
                confirmed_predictions += p.get("calibration") is not None
                provisional_fits += p.get("provisionalFit") is not None
                temporal_errors.append(decision.get("medianRelativeError"))
                temporal_inliers.append(decision.get("inliers"))
            elif stream == "path":
                if p.get("phase") == "prediction":
                    update = p.get("update") or {}
                    path_reasons[update.get("reason", "unknown")] += 1
                    if update.get("goalChangeReason"):
                        goal_changes[update["goalChangeReason"]] += 1
                    goal = update.get("goal")
                    if goal:
                        goal_ids.add((goal.get("epoch"), goal.get("id")))
                        held_without_path += update.get("path") is None
                    path_ms.append(update.get("milliseconds"))
                    path_targets.append(update.get("targetGroundDistance"))
                    path_approaches.append(update.get("approachDistance"))
                    path_reachable.append(update.get("reachableCells"))
                    path_present += update.get("path") is not None
                    points = (update.get("path") or {}).get("points", [])
                    if len(points) > 1:
                        path_lengths.append(sum(sum((float(a[k])-float(b[k]))**2 for k in range(3))**.5 for a, b in zip(points, points[1:])))
                elif p.get("phase") == "feedback":
                    haptic_status[p.get("status", "unknown")] += 1
                    path_angles.append((p.get("heading") or {}).get("angleDegrees"))
                    if p.get("pulse"):
                        pulse_kinds[p["pulse"].get("kind", "unknown")] += 1
            elif stream == "render":
                phases[p.get("phase", "missing")] += 1
                if p.get("phase") == "submitted":
                    path_renders += (p.get("pathVertices") or 0) > 0
                    path_approach_renders += (p.get("pathApproachVertices") or 0) > 0
                    path_target_renders += (p.get("pathTargetVertices") or 0) > 0
                    historical_path_renders += (p.get("pathVertices") or 0) > 0 and p.get("pathHistorical") is True
                    geometry[p.get("geometryBlockReason") or "eligible"] += 1
                    surface_modes[p.get("surfacePresentationMode") or "legacy_or_unavailable"] += 1
                    guidance[p.get("guidanceBlockReason") or "eligible"] += 1
            if verify and "attachment" in row:
                try:
                    raw = attachment(directory, row["attachment"])
                    if stream == "analysis":
                        header, _, _ = depth_frame(raw)
                        frame = p.get("frame", {})
                        for key in ("epoch", "frameID"):
                            if frame.get(key) is not None and header.get(key) != frame[key]:
                                raise ValueError("depth/log identity mismatch")
                    elif stream == "prediction":
                        header, _ = relative_frame(raw)
                        for key in ("epoch", "frameID", "modelRevision"):
                            if header.get(key) != p.get(key):
                                raise ValueError("prediction/log identity mismatch")
                    elif stream == "mesh":
                        if p.get("attachmentKind") == "mesh_frame_binary_v1":
                            mesh, _, _, _ = mesh_frame(raw)
                        else:
                            mesh = json.loads(raw)
                        for key in ("id", "epoch", "revision"):
                            if mesh.get(key) != p.get(key):
                                raise ValueError("mesh/log identity mismatch")
                    output["attachmentVerified"] += 1
                except (ValueError, OSError, zlib.error) as e:
                    output["attachmentErrors"].append({"stream": stream, "sequence": row.get("sequence"), "error": str(e)})
        output["counts"][stream] = count
    output.update(fixedGoalChanges=dict(goal_changes), distinctFixedGoals=len(goal_ids), fixedGoalWithoutPathFrames=held_without_path,
                  pathReasons=dict(path_reasons), pathAvailableAnalysisFrames=path_present,
                  pathLengthMeters=stats(path_lengths), pathPlanningMilliseconds=stats(path_ms), pathAngleDegrees=stats(path_angles),
                  pathRenderSubmissions=path_renders, historicalPathRenderSubmissions=historical_path_renders,
                  pathTargetDistanceMeters=stats(path_targets), pathUnknownApproachMeters=stats(path_approaches),
                  pathReachableCells=stats(path_reachable), pathApproachRenderSubmissions=path_approach_renders,
                  pathTargetRenderSubmissions=path_target_renders,
                  hapticStatuses=dict(haptic_status), hapticRequestedPulseKinds=dict(pulse_kinds))
    output.update(predictionScaleReasons=dict(scale_reasons), predictionGroundModes=dict(prediction_ground),
                  predictionConfirmedFrames=confirmed_predictions, predictionProvisionalFits=provisional_fits,
                  predictionTemporalRelativeResidual=stats(temporal_errors), predictionTemporalInliers=stats(temporal_inliers))
    output.update(groundReferenceModes=dict(reference_modes), surfacePresentationModes=dict(surface_modes), tracking=dict(tracking), depthReadStatus=dict(depth), modelBlockReasons=dict(blocks), modelStates=dict(models),
                  geometryGateReasons=dict(geometry), guidanceGateReasons=dict(guidance), renderPhases=dict(phases),
                  depthFrameAttachments=raw_frames, modelAnalysisFrames=models_present, unstableDirectionModelFrames=moving_models,
                  sourceAgeMilliseconds=stats(ages), depthCoverage=stats(coverage), jsonIssues=issues)
    output["unexpectedImageFiles"] = [str(p.relative_to(directory)) for p in directory.rglob("*") if p.suffix.lower() in (".jpg", ".jpeg", ".png", ".heic", ".mp4", ".mov")]
    return output


def extract(directory, identity, destination):
    epoch, frame_id = (int(x) for x in identity.split(":"))
    issues = []
    for row in records(directory / "analysis.jsonl", issues):
        frame = row["payload"].get("frame", {})
        if frame.get("epoch") == epoch and frame.get("frameID") == frame_id:
            if "attachment" not in row:
                raise ValueError("This analysis frame has no saved depth; inspect depthReadStatus")
            raw = attachment(directory, row["attachment"])
            header, depth, confidence = depth_frame(raw)
            # Unique destination prevents overwriting another measurement or leaving stale confidence.
            target = destination / f"epoch-{epoch}-frame-{frame_id}"
            target.mkdir(parents=True, exist_ok=False)
            (target / "metadata.json").write_text(json.dumps(header, ensure_ascii=False, indent=2))
            (target / "depth.f32le").write_bytes(depth)
            if confidence:
                (target / "confidence.u8").write_bytes(confidence)
            if header.get("predictionSupportBytes"):
                (target / "prediction-support.u8").write_bytes(raw[-header["predictionSupportBytes"]:])
            return target
    raise ValueError("Frame not found; it may not have been analyzed, or its diagnostic packet was dropped")


def extract_prediction(directory, identity, destination):
    epoch, frame_id = (int(x) for x in identity.split(":"))
    for row in records(directory / "prediction.jsonl", []):
        p = row["payload"]
        if p.get("epoch") == epoch and p.get("frameID") == frame_id and "attachment" in row:
            header, data = relative_frame(attachment(directory, row["attachment"]))
            target = destination / f"prediction-epoch-{epoch}-frame-{frame_id}"
            target.mkdir(parents=True, exist_ok=False)
            (target / "metadata.json").write_text(json.dumps(header, ensure_ascii=False, indent=2))
            (target / "relative-inverse-depth.f32le").write_bytes(data)
            return target
    raise ValueError("Saved prediction not found; it may have been dropped or inference failed")


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("directory", type=Path)
    p.add_argument("--verify-data", action="store_true")
    group = p.add_mutually_exclusive_group()
    group.add_argument("--extract-depth", metavar="EPOCH:FRAME")
    group.add_argument("--extract-prediction", metavar="EPOCH:FRAME")
    p.add_argument("--output", type=Path)
    args = p.parse_args()
    if args.extract_depth or args.extract_prediction:
        if args.output is None:
            p.error("--extract-depth requires --output directory")
        print(extract_prediction(args.directory, args.extract_prediction, args.output) if args.extract_prediction else extract(args.directory, args.extract_depth, args.output))
    else:
        result = summarize(args.directory, args.verify_data)
        text = json.dumps(result, ensure_ascii=False, indent=2)
        if args.output:
            args.output.write_text(text)
        else:
            print(text)
        if result["jsonIssues"] or result["attachmentErrors"]:
            raise SystemExit(2)


if __name__ == "__main__":
    main()
