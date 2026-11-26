#!/usr/bin/env python3
"""Score virtual-camera depth on a per-frame pixel holdout; write metrics.json and compare.png."""

import argparse
import json
import math
from pathlib import Path

import numpy as np
from numpy.lib.stride_tricks import sliding_window_view
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 256, 192
STEP, RADIUS = 5, 2
SURFACES = {1: "floor", 2: "box", 3: "far_wall", 4: "side_wall", 5: "ceiling"}
NEAR, FAR = 0.3, 8.0  # Display limits only; never clip or discard scored depths here.
NO_DATA = (128, 128, 128)


def read_map(path, dtype):
    data = path.read_bytes()
    expected = WIDTH * HEIGHT * np.dtype(dtype).itemsize
    if len(data) != expected:
        raise ValueError(f"{path}: expected {expected} bytes, got {len(data)}")
    return np.frombuffer(data, dtype=dtype).reshape(HEIGHT, WIDTH)


def index_frames(rows, path):
    if not isinstance(rows, list) or not rows:
        raise ValueError(f"{path}: expected a nonempty frame list")
    result = {}
    for row in rows:
        stem = row["stem"]
        if not isinstance(stem, str) or not stem or Path(stem).name != stem or stem in result:
            raise ValueError(f"{path}: invalid or duplicate frame stem {stem!r}")
        result[stem] = row
    return result


def matched_frames(scene, predictions):
    manifest = scene / "manifest.json"
    index = predictions / "frames.json"
    frames = index_frames(json.loads(manifest.read_text())["frames"], manifest)
    rows = index_frames(json.loads(index.read_text()), index)
    if frames.keys() != rows.keys():
        missing, extra = frames.keys() - rows.keys(), rows.keys() - frames.keys()
        raise ValueError(f"{index}: missing stems {sorted(missing)}, extra stems {sorted(extra)}")
    for stem, frame in frames.items():  # Manifest order, not filename or prediction order.
        row = rows[stem]
        if (row["width"], row["height"]) != (WIDTH, HEIGHT):
            raise ValueError(f"{index}: {stem}: expected {WIDTH}x{HEIGHT} analysis maps")
        if not isinstance(row["confirmed"], bool):
            raise ValueError(f"{index}: {stem}: confirmed must be a boolean")
        if not math.isclose(frame["time"], row["time"], rel_tol=0, abs_tol=1e-6):
            raise ValueError(f"{index}: {stem}: timestamp differs from scene manifest")
        yield row


def holdout(truth, surface, used):
    # Full neighborhoods, including diagonals. Inspect the original dense masks, not their
    # grid-subsampled versions: a calibration center or a label change may be off-grid.
    r = RADIUS
    y, x = np.mgrid[r : HEIGHT - r : STEP, r : WIDTH - r : STEP]
    labels, z = surface[y, x], truth[y, x]
    valid = np.isfinite(z) & (z > 0) & np.isin(labels, list(SURFACES))
    neighbors = sliding_window_view(surface, (3, 3))[y - 1, x - 1]
    interior = (neighbors == labels[..., None, None]).all(axis=(-2, -1))
    window = sliding_window_view(used, (2 * r + 1, 2 * r + 1))
    near_used = window[y - r, x - r].any(axis=(-2, -1))
    keep = valid & interior & ~near_used
    return (y[keep], x[keep]), {
        "grid_pixels": int(z.size),
        "excluded_invalid_truth_or_label": int((~valid).sum()),
        "excluded_surface_edge": int((valid & ~interior).sum()),
        "excluded_near_calibration": int((valid & interior & near_used).sum()),
    }


def metric_stats(truth, fused):
    valid = np.isfinite(fused)  # Nonpositive and unconfirmed values were set to NaN on input.
    z = truth[valid]
    error = fused[valid] - z
    n, eligible = len(error), len(truth)
    absolute = np.abs(error)
    p50, p90 = np.percentile(absolute, [50, 90]).tolist() if n else (None, None)
    over, under = int((error > 0.2 * z).sum()), int((error < -0.2 * z).sum())
    return {
        "eligible_pixels": eligible,
        "valid_pixels": n,
        "missing_pixels": eligible - n,
        "coverage": n / eligible if eligible else None,
        "mae_m": float(absolute.mean()) if n else None,
        "bias_m": float(error.mean()) if n else None,
        "p50_abs_error_m": p50,
        "p90_abs_error_m": p90,
        "over_20pct_pixels": over,
        "over_20pct_rate": over / n if n else None,
        "under_20pct_pixels": under,
        "under_20pct_rate": under / n if n else None,
    }


def raw_relative(truth, q):
    # Midranks handle ties. Ranking -Z is equivalent to ranking 1/Z for positive truth.
    def ranks(values):
        _, inverse, counts = np.unique(values, return_inverse=True, return_counts=True)
        return (counts.cumsum() - (counts + 1) / 2)[inverse]

    valid = np.isfinite(q)
    n = int(valid.sum())
    rho = None
    if n >= 2:
        a, b = ranks(q[valid]), ranks(-truth[valid])
        if np.ptp(a) and np.ptp(b):
            rho = float(np.corrcoef(a, b)[0, 1])
    return {"paired_pixels": n, "spearman_q_vs_inverse_z": rho}


def summarize(samples):
    def with_bins(z, m):
        bins = {"lt_1_5m": z < 1.5, "1_5_to_3m": (z >= 1.5) & (z <= 3), "gt_3m": z > 3}
        return {
            **metric_stats(z, m),
            "by_truth_distance": {name: metric_stats(z[v], m[v]) for name, v in bins.items()},
        }

    if samples:
        z, m, labels = (np.concatenate(parts) for parts in zip(*samples))
    else:
        z = m = labels = np.empty(0)
    return {
        "frame_count": len(samples),
        "overall": with_bins(z, m),
        "by_surface": {
            name: with_bins(z[labels == label], m[labels == label])
            for label, name in SURFACES.items()
        },
    }


def depth_colors(z):
    # One linear color map for both images and the legend; invalid pixels never enter it.
    palette = np.array(
        [[255, 231, 96], [127, 211, 139], [35, 145, 146], [58, 89, 143], [47, 32, 79]]
    )
    valid = np.isfinite(z) & (z > 0)
    colors = np.full((*z.shape, 3), NO_DATA, dtype=np.uint8)
    stops = np.linspace(NEAR, FAR, len(palette))
    colors[valid] = np.column_stack([np.interp(z[valid], stops, c) for c in palette.T]).round()
    return Image.fromarray(colors)


def font(size):
    for face in ("/System/Library/Fonts/Supplemental/Arial.ttf", "DejaVuSans.ttf"):
        try:
            return ImageFont.truetype(face, size)
        except OSError:
            continue
    return ImageFont.load_default()


def write_preview(path, rgb_path, row, truth, fused):
    panel = (512, 384)
    with Image.open(rgb_path) as original:
        if original.size != (640, 480):
            raise ValueError(f"{rgb_path}: expected 640x480 RGB input, got {original.size}")
        rgb = original.convert("RGB").resize(panel, Image.Resampling.LANCZOS)
    image = Image.new("RGB", (3 * panel[0] + 64, 552), "#151c26")
    draw = ImageDraw.Draw(image)
    large, small = font(24), font(18)
    status = "confirmed" if row["confirmed"] else "unconfirmed"
    stats = row["metric"]
    title = f"Virtual camera  /  Frame {row['stem']}  /  {status}"
    title += f"  /  held-out metric pixels: {stats['valid_pixels']} of {stats['eligible_pixels']}"
    draw.text((16, 10), title + "  /  full maps below", fill="white", font=large)
    for i, (label, view) in enumerate(
        [("RGB", rgb), ("Truth Z", depth_colors(truth)), ("Fused Z", depth_colors(fused))]
    ):
        x = 16 + i * (panel[0] + 16)
        draw.text((x, 50), label, fill="white", font=large)
        image.paste(view.resize(panel, Image.Resampling.NEAREST), (x, 83))
    draw.text((16, 488), "Axial depth (m)", fill="white", font=small)
    left, top, width = 205, 489, 820
    bar = depth_colors(np.linspace(NEAR, FAR, width)[None, :])
    image.paste(bar.resize((width, 14), Image.Resampling.NEAREST), (left, top))
    for value, label in [(NEAR, "0.3 near"), (2, "2"), (4, "4"), (6, "6"), (FAR, "8 far")]:
        x = left + round((width - 1) * (value - NEAR) / (FAR - NEAR))
        draw.line((x, top + 14, x, top + 19), fill="white")
        draw.text((x, top + 23), label, anchor="mt", fill="white", font=small)
    draw.rectangle((1100, top, 1123, top + 17), fill=NO_DATA)
    draw.text((1135, top - 2), "No estimate / invalid Z", fill="white", font=small)
    image.save(path)


def score(scene, predictions):
    rows, all_samples, confirmed_samples = [], [], []
    for row in matched_frames(scene, predictions):
        stem = row["stem"]
        truth = read_map(scene / f"{stem}.z.f32", "<f4")
        surface = read_map(scene / f"{stem}.surface.u8", "u1")
        used = read_map(predictions / f"{stem}.used.u8", "u1")
        fused = read_map(predictions / f"{stem}.m.f32", "<f4")
        q = read_map(predictions / f"{stem}.q.f32", "<f4")
        idx, audit = holdout(truth, surface, used)
        z = truth[idx].astype(np.float64)
        positive = np.isfinite(fused) & (fused > 0)
        ignored = 0 if row["confirmed"] else int(positive[idx].sum())
        fused = np.where(positive & row["confirmed"], fused, np.nan)
        m = fused[idx].astype(np.float64)
        sample = (z, m, surface[idx])
        all_samples.append(sample)
        if row["confirmed"]:
            confirmed_samples.append(sample)
        counts = np.bincount(surface[used != 0], minlength=max(SURFACES) + 1)
        detail = {
            **row,
            "holdout": audit,
            "used_pixels_by_surface": {name: int(counts[k]) for k, name in SURFACES.items()},
            "ignored_unconfirmed_metric_pixels": ignored,
            "metric": metric_stats(z, m),
            "raw_relative": raw_relative(z, q[idx]),
        }
        rows.append(detail)
        if row["confirmed"] or not confirmed_samples:
            preview = (scene / f"{stem}.png", detail, truth, fused)

    raw = [row["raw_relative"] for row in rows]
    rhos = [r["spearman_q_vs_inverse_z"] for r in raw if r["spearman_q_vs_inverse_z"] is not None]
    report = {
        "protocol": {
            "scope": "Per-frame pixels only; the same world point can recur across frames. "
            "Not an independent scene test or physical validation.",
            "grid_stride_px": STEP,
            "grid_offset_xy_px": [RADIUS, RADIUS],
            "exclude_used_chebyshev_radius_px": RADIUS,
            "surface_interior": "All 3x3 labels agree; positive finite axial Z, known surface.",
            "calibration_mask": "Nonzero used.u8 centers, not just fit inliers; masks vary by run. "
            "used_pixels_by_surface counts centers by visible label, not by reference source.",
            "metric": "Coverage = confirmed finite positive estimates / eligible pixels in scope. "
            "Errors pool valid frame-pixels only, without clipping; bias = fused Z - truth Z.",
            "tails": "Strictly above +20% or below -20% of truth; rates divide by valid pixels.",
            "truth_distance_m": ["Z < 1.5", "1.5 <= Z <= 3", "Z > 3"],
            "raw": "Within-frame Spearman(q, 1/Z), averaged over defined frames; never metric.",
            "display_range_m": [NEAR, FAR],
        },
        "all_frames": summarize(all_samples),
        "confirmed_frames": summarize(confirmed_samples),
        "used_pixels_by_surface": {
            name: sum(row["used_pixels_by_surface"][name] for row in rows)
            for name in SURFACES.values()
        },
        "raw_relative": {
            "paired_pixels": sum(r["paired_pixels"] for r in raw),
            "frames_with_spearman": len(rhos),
            "mean_frame_spearman": float(np.mean(rhos)) if rhos else None,
        },
        "preview": {"file": "compare.png", "stem": preview[1]["stem"]},
        "frames": rows,
    }
    payload = json.dumps(report, indent=2, ensure_ascii=False, allow_nan=False)
    write_preview(predictions / "compare.png", *preview)
    (predictions / "metrics.json").write_text(payload + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("scene_dir", type=Path, metavar="SCENE_DIR")
    parser.add_argument("predictions_dir", type=Path, metavar="PREDICTIONS_DIR")
    args = parser.parse_args()
    try:
        score(args.scene_dir, args.predictions_dir)
    except (OSError, ValueError, KeyError, TypeError) as exc:
        parser.exit(1, f"{parser.prog}: {exc}\n")
    print(
        f"Wrote {args.predictions_dir / 'metrics.json'} and {args.predictions_dir / 'compare.png'}"
    )


if __name__ == "__main__":
    main()
