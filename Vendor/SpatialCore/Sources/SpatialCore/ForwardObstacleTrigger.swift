import Foundation
import simd

/// Occupied-component measurement and near-field trigger geometry.
enum ForwardObstacleTrigger {
    /// Eight-connected occupied cells are measured as one component, including the part OUTSIDE
    /// the trigger. Unknown neighbours / grid boundaries make the width a lower bound, not a
    /// small-object certificate. No semantic label or single minimum depth pixel is used.
    static func trigger(
        raster: RoutePlanningGrid, device: GroundBasis, reference: ForwardRouteReference,
        options: PathOptions, laneOnly: Bool = false
    ) -> ForwardObstacle? {
        let grid = raster.grid
        let half = grid.cellSize / 2
        // Match the actual swept path footprint as well as the near-field triangle.
        // Otherwise a path can be vetoed by a box without ever activating a detour.
        let progress = max(0, reference.coordinates(device.origin).y)
        let start = grid.basis.local(reference.point(progress))
        let end = grid.basis.local(reference.point(progress + raster.maxDistance))
        let laneStart = SIMD2(start.x, start.z)
        let laneEnd = SIMD2(end.x, end.z)
        var visited = Set<Int>()
        var hits: [ForwardObstacle] = []
        for seed in grid.cells.indices where grid.cells[seed].state == .obstacle && !visited.contains(seed) {
            var queue = [seed]
            var cursor = 0
            var hit = false
            var bounded = true
            var minX = Float.infinity
            var maxX = -Float.infinity
            var near = Float.infinity
            var far = -Float.infinity
            var widthLow = Float.infinity
            var widthHigh = -Float.infinity
            var distance = Float.infinity
            visited.insert(seed)
            while cursor < queue.count {
                let i = queue[cursor]
                cursor += 1
                let c = grid.center(i)
                let corners = [
                    SIMD2(c.x - half, c.y - half), SIMD2(c.x + half, c.y - half),
                    SIMD2(c.x + half, c.y + half), SIMD2(c.x - half, c.y + half),
                ]
                var polygon: [SIMD2<Float>] = []
                var cellNear = Float.infinity
                for corner in corners {
                    let world = grid.basis.world(x: corner.x, h: 0, z: corner.y)
                    let d = device.local(world)
                    let r = reference.coordinates(world)
                    polygon.append(SIMD2(d.x, d.z))
                    widthLow = min(widthLow, d.x)
                    widthHigh = max(widthHigh, d.x)
                    minX = min(minX, r.x)
                    maxX = max(maxX, r.x)
                    near = min(near, r.y)
                    far = max(far, r.y)
                    cellNear = min(cellNear, d.z)
                    if !laneOnly, d.z >= 0 { distance = min(distance, d.z) }
                }
                let laneHit = PathClearance.overlapsCell(
                    from: laneStart, to: laneEnd, center: c, cellSize: grid.cellSize,
                    radius: raster.requiredWidth / 2)
                if laneOnly && laneHit { distance = min(distance, max(0, cellNear)) }
                hit = hit || laneHit || (!laneOnly && intersectsTrigger(
                    polygon, distance: options.obstacleTriggerDistance, width: options.obstacleTriggerWidth))
                let x = i % grid.columns
                let z = i / grid.columns
                for dz in -1...1 {
                    for dx in -1...1 where dx != 0 || dz != 0 {
                        let xx = x + dx
                        let zz = z + dz
                        guard xx >= 0, xx < grid.columns, zz >= 0, zz < grid.rows else {
                            bounded = false
                            continue
                        }
                        let j = zz * grid.columns + xx
                        if grid.cells[j].state == .unknown { bounded = false }
                        if grid.cells[j].state == .obstacle, visited.insert(j).inserted { queue.append(j) }
                    }
                }
            }
            if hit {
                hits.append(
                    .init(
                        width: widthHigh - widthLow, distance: distance, extentObserved: bounded,
                        near: near, far: far, minLateral: minX, maxLateral: maxX))
            }
        }
        // Plan around the first blocking component. Merging a nearby box with a distant
        // wall invents one oversized obstacle. The search still collision-checks ALL cells.
        return hits.min {
            if abs($0.distance - $1.distance) > 0.001 { return $0.distance < $1.distance }
            return $0.near < $1.near
        }
    }

    /// Clip a cell square against z in [0, distance] and |x| <= z*width/(2*distance).
    /// Testing only cell centres would miss obstacles grazing the narrowing triangle edges.
    static func intersectsTrigger(_ polygon: [SIMD2<Float>], distance: Float, width: Float) -> Bool {
        let slope = width / (2 * distance)
        let planes: [(SIMD2<Float>) -> Float] = [
            { $0.y }, { distance - $0.y }, { slope * $0.y - $0.x }, { slope * $0.y + $0.x },
        ]
        var clipped = polygon
        for value in planes {
            guard !clipped.isEmpty else { return false }
            var next: [SIMD2<Float>] = []
            var a = clipped.last!
            var va = value(a)
            for b in clipped {
                let vb = value(b)
                let ain = va >= -0.000001
                let bin = vb >= -0.000001
                if ain != bin {
                    let t = va / (va - vb)
                    next.append(a + (b - a) * t)
                }
                if bin { next.append(b) }
                a = b
                va = vb
            }
            clipped = next
        }
        guard clipped.count >= 3 else { return false }
        let twiceArea = zip(clipped, Array(clipped.dropFirst()) + [clipped[0]]).reduce(Float(0)) {
            $0 + $1.0.x * $1.1.y - $1.0.y * $1.1.x
        }
        return abs(twiceArea) > 0.000001  // Pure tangency does not occupy the trigger volume.
    }

}
