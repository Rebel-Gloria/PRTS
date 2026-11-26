"""Render metric corridors; the generated image supplies only interior material swatches."""

import argparse
import json
from math import cos, pi, radians, sin
from pathlib import Path
from typing import NamedTuple

import numpy as np
from PIL import Image

W, H = 640, 480
FX = FY = 400.0
CX, CY = (W - 1) / 2, (H - 1) / 2  # Integer pixel centers; image edges at -0.5 and size-0.5.
FLOOR, BOX, FAR, SIDE, CEILING = range(1, 6)
UV = ((2, 1), (0, 2), (0, 1))  # In-plane world axes for faces perpendicular to X, Y, Z.


class Face(NamedTuple):
    surface: int
    axis: int
    at: float
    u: tuple[float, float]
    v: tuple[float, float]


def box(x, z, height):
    y = (0, height)
    sides = [Face(BOX, 0, k, z, y) for k in x] + [Face(BOX, 2, k, x, y) for k in z]
    return sides + [Face(BOX, 1, height, x, z)]


X, Y, Z = (-1.65, 1.65), (0, 2.7), (-6.5, 1.0)  # Meters; open behind the camera.
ROOM = [Face(FLOOR, 1, Y[0], X, Z), Face(CEILING, 1, Y[1], X, Z), Face(FAR, 2, Z[0], X, Y)]
NORMAL = ROOM + [Face(SIDE, 0, x, Z, Y) for x in X] + box((-1.24, -0.24), (-3.45, -2.55), 0.82)
BLOCKER = box((-0.16, 1.18), (-2.95, -2.18), 1.12)
# Start the near face just inside 1.5 m, not on the scorer's strict cutoff.
NEAR_BOX = box((-0.46, 0.20), (-1.995, -1.495), 0.44)
SCENES = {
    "normal": (NORMAL, 1.18),
    "occluded": (NORMAL + BLOCKER, 1.18),
    "near": (NORMAL + NEAR_BOX, 0.52),  # Lower only this camera to keep floor contact in frame.
}
# Independent finite floor anchor, +Y winding; it intentionally continues under the boxes.
BOUNDARY = [[-1.35, 0, -1.4], [1.35, 0, -1.4], [1.35, 0, -5.8], [-1.35, 0, -5.8]]


def intersect(pos, rays, faces):
    """First positive intersection of pos + t * ray with a bounded face."""
    depth = np.full(rays.shape[:-1], np.inf)
    index = np.full(depth.shape, -1, dtype=np.int8)
    for i, (_, axis, at, u, v) in enumerate(faces):
        d = rays[..., axis]
        t = np.divide(at - pos[axis], d, out=np.full_like(depth, -1), where=np.abs(d) > 1e-12)
        a, b = UV[axis]
        x, y = pos[a] + t * rays[..., a], pos[b] + t * rays[..., b]
        hit = (t > 0) & (t < depth) & (u[0] <= x) & (x <= u[1]) & (v[0] <= y) & (y <= v[1])
        depth[hit], index[hit] = t[hit], i
    return depth, index


def raster(w, h, pos, right, back, faces):
    v, u = np.indices((h, w))
    # Map each target center back to RGB: u_rgb=(u+0.5)*W/w-0.5; same for v.
    x = ((u + 0.5) * (W / w) - 0.5 - CX) / FX
    y = (CY + 0.5 - (v + 0.5) * (H / h)) / FY
    rays = x[..., None] * right - back  # +right, +up, -back; not normalized: t is axial Z.
    rays[..., 1] = y
    depth, index = intersect(pos, rays, faces)
    if np.any(index < 0):
        raise ValueError("A camera ray escaped the corridor")
    return rays, depth, index


def load_tiles(path):
    # Normalized interior crops only: no carton edges, door frame, grout or vanishing lines.
    bounds = {
        "tile": (0.53, 0.885, 0.62, 0.965),
        "red": (0.19, 0.70, 0.255, 0.79),
        "door": (0.466, 0.151, 0.55, 0.265),
        "wall": (0.83, 0.14, 0.915, 0.255),
    }
    with Image.open(path) as source:
        rgb = source.convert("RGB")
        scale = np.array(rgb.size * 2)
        return {
            name: np.asarray(rgb.resize((64, 64), Image.Resampling.BILINEAR, tuple(rect * scale)))
            for name, rect in bounds.items()
        }


def sample(tile, u, v):
    # Mirrored repeat in world space, bilinear within each swatch (including the edges).
    h, w = tile.shape[:2]
    x, y = (1 - abs(u % 2 - 1)) * (w - 1), (1 - abs(v % 2 - 1)) * (h - 1)
    x0, y0 = x.astype(int), y.astype(int)
    x1, y1 = np.minimum(x0 + 1, w - 1), np.minimum(y0 + 1, h - 1)
    a, b = (x - x0)[:, None], (y - y0)[:, None]
    return (1 - b) * ((1 - a) * tile[y0, x0] + a * tile[y0, x1]) + b * (
        (1 - a) * tile[y1, x0] + a * tile[y1, x1]
    )


def shade(f, pos, u, v, tiles):
    if f.surface == FLOOR:
        s, t = u / 0.56, v / 0.56  # Square 56 cm tiles, metric grout, not photographed seams.
        color = sample(tiles["tile"], s, t)
        grout = np.minimum(abs(s - np.rint(s)), abs(t - np.rint(t)))
        color *= (0.75 + 0.25 * np.clip(grout / 0.012, 0, 1))[:, None]
    elif f.surface == BOX:
        color = sample(tiles["red"], u / 0.35, v / 0.35)
        tape = (abs(u - sum(f.u) / 2) < 0.035) & ((f.axis == 1) | (v > f.v[1] - 0.12))
        if f.axis != 0:
            color[tape] = 0.65 * color[tape] + 0.35 * np.array([205, 183, 156])
    else:
        color = sample(tiles["wall"], u / 0.7, v / 0.7)
        if f.surface != CEILING:
            color[v < 0.10] *= 0.69  # Skirting board.
        if f.surface == FAR:  # Door, frame and handle are decals on the virtual far wall.
            frame = (abs(u) < 0.59) & (v < 2.20)
            door = (abs(u) < 0.55) & (v < 2.16)
            color[frame] = 0.8 * sample(tiles["door"], u[frame], v[frame])
            color[door] = sample(tiles["door"], u[door] / 0.45, v[door] / 0.45)
            color[(abs(u + 0.43) < 0.06) & (abs(v - 1.02) < 0.014)] = (167, 161, 147)
    # Diffuse daylight from upper left/front. Only the visible face normal affects lighting.
    light = (-0.48, 0.80, 0.36)[f.axis] * np.sign(pos[f.axis] - f.at)
    return np.clip(color * (0.77 + 0.40 * max(light, 0)), 0, 255).astype(np.uint8)


def landmarks():
    rng = np.random.Generator(np.random.PCG64(20261126))
    groups, surfaces = [], []
    for f in NORMAL:  # Shared sparse map: neither added box has any native landmarks.
        n = {FLOOR: 32, BOX: 8, FAR: 24, SIDE: 28, CEILING: 12}[f.surface]
        p = np.full((n, 3), f.at, dtype=float)
        for axis, (lo, hi) in zip(UV[f.axis], (f.u, f.v), strict=True):
            p[:, axis] = lo + (hi - lo) * rng.uniform(0.04, 0.96, n)
        groups.append(p)
        surfaces.extend([f.surface] * n)
    return np.concatenate(groups), surfaces


def visible(points, surfaces, pos, right, back, faces):
    rays = points - pos
    z = -(rays @ back)
    inside = (abs(rays @ right) * FX < z * W / 2) & (abs(rays[:, 1]) * FY < z * H / 2)
    t, _ = intersect(pos, rays, faces)  # Endpoint is at t=1; use its own ray, not a depth pixel.
    return [
        {"id": int(i), "world": points[i].tolist(), "surface": surfaces[i]}
        for i in np.flatnonzero(inside & (abs(t - 1) < 1e-9))
    ]


def poses(camera_height, trajectory):
    if trajectory == "approach":
        for i in range(12):
            yield np.array([0, camera_height, -i / 20]), radians(2 * i / 11)
    else:
        # Walk across the corridor, hold the pose, then retrace it. Same fixed world landmarks.
        for step in [*range(10), *([9] * 4), *range(9, -1, -1)]:
            t = step / 9
            yield (
                np.array([-0.30 + 0.60 * t, camera_height, -0.25 * sin(pi * t)]),
                radians(-8 + 16 * t),
            )


def render(directory, faces, camera_height, tiles, points, surfaces, trajectory):
    directory.mkdir(parents=True, exist_ok=True)
    frames = []
    labels = np.array([f.surface for f in faces], dtype=np.uint8)
    for i, (pos, yaw) in enumerate(poses(camera_height, trajectory)):
        stem = f"{i:03d}"
        right, back = np.array([cos(yaw), 0, -sin(yaw)]), np.array([sin(yaw), 0, cos(yaw)])
        rays, depth, index = raster(W, H, pos, right, back, faces)
        rgb = np.empty((H, W, 3), dtype=np.uint8)
        for j, f in enumerate(faces):
            mask = index == j
            if mask.any():
                hits = pos + depth[mask, None] * rays[mask]
                a, b = UV[f.axis]
                rgb[mask] = shade(f, pos, hits[:, a], hits[:, b], tiles)
        Image.fromarray(rgb).save(directory / f"{stem}.png")
        # Scorer-only, row-major (v, u): cast at the output centers rather than resize RGB depth.
        _, truth, index = raster(256, 192, pos, right, back, faces)
        truth.astype("<f4").tofile(directory / f"{stem}.z.f32")
        labels[index].tofile(directory / f"{stem}.surface.u8")
        frames.append(
            dict(
                stem=stem,
                time=i / 10,
                position=pos.tolist(),
                yaw=yaw,
                features=visible(points, surfaces, pos, right, back, faces),
            )
        )
    manifest = dict(
        width=W, height=H, fx=FX, fy=FY, cx=CX, cy=CY, floorBoundary=BOUNDARY, frames=frames
    )
    (directory / "manifest.json").write_text(
        json.dumps(manifest, allow_nan=False) + "\n", encoding="utf-8"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("texture", type=Path)
    parser.add_argument("outputDirectory", type=Path)
    parser.add_argument("--case", choices=SCENES, help="Write only this case (default: all).")
    parser.add_argument("--trajectory", choices=("approach", "lateral-return"), default="approach")
    args = parser.parse_args()
    try:
        tiles = load_tiles(args.texture)
    except OSError as error:
        parser.error(str(error))
    points, surfaces = landmarks()
    for name, (faces, camera_height) in SCENES.items():
        if args.case is None or name == args.case:
            render(
                args.outputDirectory / name,
                faces,
                camera_height,
                tiles,
                points,
                surfaces,
                args.trajectory,
            )


if __name__ == "__main__":
    main()
