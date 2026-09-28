#!/usr/bin/env python3
"""Offline metrics and independent-human-reference evaluation. Standard library only.
No ARKit output is treated as ground truth. Never fabricates absent measurements.
"""
import argparse
import csv
import json
import math
from pathlib import Path


def number(value):
    try:
        x = float(value)
        return x if math.isfinite(x) else None
    except (TypeError, ValueError):
        return None


def stats(values):
    xs = sorted(x for value in values if (x := number(value)) is not None)
    if not xs:
        return {"n": 0, "mean": None, "p50": None, "p95": None, "max": None}
    def percentile(q):
        at = (len(xs)-1)*q
        lo, hi = math.floor(at), math.ceil(at)
        return xs[lo]+(xs[hi]-xs[lo])*(at-lo)
    return {"n": len(xs), "mean": sum(xs)/len(xs), "p50": percentile(.5), "p95": percentile(.95), "max": xs[-1]}


def evaluate(frames, labels):
    index = {(str(r["epoch"]), str(r["frameID"])): r for r in frames}
    distances, widths = [], []
    out = {"labels": len(labels), "missingFrames": 0, "referenceDistances": 0,
           "distanceUnavailable": 0, "referenceWidths": 0, "widthUnavailable": 0,
           "unsafeCandidateEvents": 0, "unreviewedCandidateEvents": 0,
           "reviewedCandidateEvents": 0, "failures": []}
    seen = set()
    for label in labels:
        key = (label["epoch"], label["frameID"])
        sector = label["sector"]
        if sector not in ("left", "center", "right"):
            raise ValueError("sector must be left/center/right")
        identity = key+(sector,)
        if identity in seen:
            raise ValueError("Duplicate human label: " + repr(identity))
        seen.add(identity)
        r = index.get(key)
        if not r:
            out["missingFrames"] += 1
            continue
        eligible = r.get("metrics", {}).get("outputEligible", False)
        d = next((x for x in r.get("distances", []) if x["sector"] == sector), None) if eligible else None
        c = next((x for x in r.get("segments", []) if x["sector"] == sector), None) if eligible else None
        gd = number(label.get("gt_obstacle_ground_m"))
        gw = number(label.get("gt_channel_width_m"))
        if gd is not None:
            out["referenceDistances"] += 1
            if d and number(d.get("groundDistance")) is not None:
                distances.append(abs(d["groundDistance"]-gd))
            else:
                out["distanceUnavailable"] += 1
        if gw is not None:
            out["referenceWidths"] += 1
            if c and number(c.get("minimumObservedWidth")) is not None:
                widths.append(abs(c["minimumObservedWidth"]-gw))
            else:
                out["widthUnavailable"] += 1
        review = label.get("candidate_label", "unknown")
        if review not in ("safe", "unsafe", "unknown", ""):
            raise ValueError("candidate_label must be safe/unsafe/unknown (human judgement, not system state)")
        if c:
            if review in ("safe", "unsafe"):
                out["reviewedCandidateEvents"] += 1
            else:
                out["unreviewedCandidateEvents"] += 1
            if review == "unsafe":
                out["unsafeCandidateEvents"] += 1
                out["failures"].append({"epoch": key[0], "frameID": key[1], "sector": sector, "notes": label.get("notes", "")})
    out["distanceAbsoluteErrorMeters"] = stats(distances)
    out["widthAbsoluteErrorMeters"] = stats(widths)
    out["acceptance"] = "FAIL: unsafe candidate observed" if out["unsafeCandidateEvents"] else "NOT ESTABLISHED: absence of labeled failures is not validation"
    return out


def summarize(session, reference=None):
    session = Path(session)
    manifest = json.loads((session/"manifest.json").read_text())
    with (session/"metrics.csv").open(newline="") as f:
        rows = list(csv.DictReader(f))
    frames = []
    frame_file = session/"frames.jsonl"
    if frame_file.exists():
        for line in frame_file.read_text().splitlines():
            if line.strip():
                frames.append(json.loads(line))
    columns = ["coverage", "unknownFraction", "captureFPS", "analysisFPS", "displayFPS", "captureMS", "depthMS",
               "groundGridMS", "meshMS", "channelMS", "surfaceModelMS", "cpuDrawMS", "gpuMS", "presentAgeMS", "sourceAgeMS"]
    thermal = {}
    for r in rows:
        key = r.get("thermal", "unknown")
        thermal[key] = thermal.get(key, 0)+1
    times = [x for r in rows if (x := number(r.get("timestamp"))) is not None]
    bins = {}
    if times:
        for r in rows:
            t = number(r.get("timestamp"))
            if t is None:
                continue
            b = int((t-min(times))//300)
            bins.setdefault(b, []).append(r)
    result = {"schemaVersion": 1, "source": manifest.get("source", "unspecified"), "device": manifest.get("device"),
              "analyzedRows": len(rows), "analysisTimeSpanSeconds": max(times)-min(times) if times else None,
              "metrics": {c: stats(r.get(c) for r in rows) for c in columns}, "thermalAnalyzedRowCounts": thermal,
              "fiveMinuteBins": {str(b): {c: stats(r.get(c) for r in rs) for c in ("displayFPS", "analysisFPS", "sourceAgeMS")} for b, rs in bins.items()},
              "cumulativeDroppedFramesMax": max((number(r.get("droppedFrames")) or 0 for r in rows), default=0),
              "limitations": ["Rows sample completed analyses, not every capture/display frame.",
                  "Missing ground estimates count as fully unknown in the nominal observation window; no ground basis is asserted.",
                  "An emitted candidate event requires metrics.outputEligible; computation alone is not presentation proof.",
                  "Independent sensor timestamp skew is unavailable; sourceAge is not hardware LiDAR latency.",
                  "Manual labels cover only labeled frames/sectors; no labels means no accuracy/safety conclusion."]}
    status_file = session/"export-status.json"
    result["recordingStatus"] = json.loads(status_file.read_text()) if status_file.exists() else {"status": "export status unavailable"}
    result["frameLogRows"] = len(frames)
    if len(frames) != len(rows):
        result["limitations"].append("Frame JSONL and CSV row counts differ: partial writes or incomplete export; inspect recording errors.")
    if reference:
        with Path(reference).open(newline="") as f:
            result["humanReferenceEvaluation"] = evaluate(frames, list(csv.DictReader(f)))
    else:
        result["humanReferenceEvaluation"] = {"status": "UNVERIFIED: no independent human reference supplied"}
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("session", type=Path)
    p.add_argument("--reference", type=Path)
    p.add_argument("--out", type=Path)
    args = p.parse_args()
    result = json.dumps(summarize(args.session, args.reference), ensure_ascii=False, indent=2, allow_nan=False)
    if args.out:
        args.out.write_text(result+"\n")
    else:
        print(result)

if __name__ == "__main__":
    main()
