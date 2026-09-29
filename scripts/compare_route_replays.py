#!/usr/bin/env python3
"""Compare identical sampled inputs, not display FPS or independent obstacle ground truth."""
import argparse
import collections
import json
import math
from pathlib import Path
from summarize_session import stats


def read(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def summarize(rows):
    updates = [row["update"] for row in rows]
    paths = [row["path"] for row in updates if row.get("path")]
    return {
        "samples": len(rows),
        "pathSamples": len(paths),
        "pathFraction": len(paths) / len(rows) if rows else None,
        "lengthMeters": stats(
            sum(math.dist(a, b) for a, b in zip(path["points"], path["points"][1:])) for path in paths
        ),
        "planningMilliseconds": stats(row["milliseconds"] for row in updates),
        "modes": dict(collections.Counter((row.get("strategy") or {}).get("mode", "none") for row in updates)),
        "reasons": dict(collections.Counter(row["reason"] for row in updates)),
        "freshUnsupported": sum(row.get("fresh", False) and row.get("supportedByCurrentGrid") is False for row in rows),
        "currentObstacleConflicts": sum(row.get("currentObstacleFree") is False for row in rows),
        "invariantChecksPresent": sum("fresh" in row and (not row["update"].get("path") or
                                     "currentObstacleFree" in row) for row in rows),
    }


def compare(before, after):
    key = lambda row: (row["epoch"], row["frameID"], row["timestamp"])
    if [key(row) for row in before] != [key(row) for row in after]:
        raise ValueError("Inputs/order differ; this is not a paired comparison")
    return {
        "note": "Same low-rate recorded inputs; no new on-device run. Collision checks use recorded evidence, not human ground truth.",
        "epochs": {
            str(epoch): {
                "before": summarize([r for r in before if r["epoch"] == epoch]),
                "after": summarize([r for r in after if r["epoch"] == epoch]),
            }
            for epoch in sorted({row["epoch"] for row in before})
        },
        "total": {"before": summarize(before), "after": summarize(after)},
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("before", type=Path)
    parser.add_argument("after", type=Path)
    args = parser.parse_args()
    result = compare(read(args.before), read(args.after))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    after = result["total"]["after"]
    raise SystemExit(bool(after["freshUnsupported"] or after["currentObstacleConflicts"]))
