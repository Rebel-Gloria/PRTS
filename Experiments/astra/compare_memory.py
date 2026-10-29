"""Compare scene-memory replays: python3 Experiments/astra/compare_memory.py mem-off mem-route mem-scenario

Product metrics per run, plus one cross-run check: how many drawn routes pass within half a
body width of an obstacle the memory run knew about (measured now or remembered) on that frame.
"""
import json, sys
from pathlib import Path

ROOT = Path(__file__).parent / "results/round3"
HALF_BODY = 0.25


def rows(label):
    with open(ROOT / label / "product-replay.jsonl") as f:
        for line in f:
            yield json.loads(line)


def hits(points, footprints):
    for a, b in zip(points, points[1:]):
        steps = max(1, int(sum((b[i] - a[i]) ** 2 for i in range(3)) ** 0.5 / 0.05))
        for s in range(steps + 1):
            p = [a[i] + (b[i] - a[i]) * s / steps for i in range(3)]
            for fp in footprints:
                d = [p[i] - fp["center"][i] for i in range(3)]
                x = abs(sum(d[i] * fp["right"][i] for i in range(3)))
                z = abs(sum(d[i] * fp["forward"][i] for i in range(3)))
                if x <= fp["size"] / 2 + HALF_BODY and z <= fp["size"] / 2 + HALF_BODY:
                    return True
    return False


labels = sys.argv[1:] or ["mem-off", "mem-route", "mem-scenario"]
known = {(r["epoch"], r["frameID"]): r["confirmed"] for r in rows(labels[-1])}
print("| 指标 | " + " | ".join(labels) + " |")
print("|---" * (len(labels) + 1) + "|")
table = {}
for label in labels:
    m = json.load(open(ROOT / label / "product_metrics.json"))["metrics"]["feedback"]
    paths = through = 0
    for r in rows(label):
        path = r["variants"]["feedback"].get("path")
        if not path:
            continue
        paths += 1
        through += hits(path["points"], known.get((r["epoch"], r["frameID"]), []))
    table[label] = {
        "漏报 FN1 帧/秒": f'{m["near1"]["missFrames"]} / {m["near1"]["missSeconds"]:.2f}',
        "误报 FP1.5": m["falseProxy"]["1.5"],
        "语音误报": m["speechFalseProxy"],
        "危险语音": m["speechRequests"],
        "clear↔障碍切换": m["flips"],
        "blocked 帧": m["blockedFrames"],
        "有路线帧": m["pathFrames"],
        "无可见目标帧": m["noVisibleFrames"],
        "规划 p95 ms": f'{m["planningMS"]["p95"]:.2f}',
        f"路线穿过已知障碍（{labels[-1]} 的记忆）": f"{through} / {paths}",
    }
for key in table[labels[0]]:
    print(f"| {key} | " + " | ".join(str(table[l][key]) for l in labels) + " |")
