import Foundation
import simd

struct StraightPathTrace: Sendable {
    var points: [V3] = []
    var entry: V3?
    var observedLength: Float = 0
}

/// Reusable geometry searches on the selected policy raster. In obstacle-veto mode the
/// facade has already opened all non-obstacle cells. Swept width checks use that same raster.
enum ForwardPathSearch {
    static func straight(
        raster: RoutePlanningGrid, reference: ForwardRouteReference, foot: V3,
        maxProgress: Float? = nil
    ) -> StraightPathTrace {
        let grid = raster.grid
        let radius = raster.requiredWidth / 2
        let startProgress = max(0, reference.coordinates(foot).y)
        let limit = min(maxProgress ?? .infinity, startProgress + raster.maxDistance)
        guard limit > startProgress else { return .init() }
        if raster.obstacleVeto {
            return occupancyStraight(raster:raster,reference:reference,foot:foot,start:startProgress,end:limit)
        }
        let step = grid.cellSize / 4
        var trace = StraightPathTrace()
        var last: V3?
        for n in 0...Int(ceil((limit - startProgress) / step)) {
            let point = reference.point(min(limit, startProgress + Float(n) * step))
            let q = grid.basis.local(point)
            let center = SIMD2(q.x, q.z)
            let f = grid.basis.local(foot)
            if simd_distance(foot, point) > raster.maxDistance { break }
            let supported = PathClearance.segment(grid: grid, from: center, to: center, radius: radius)
            if trace.entry == nil {
                // The only unknown connection is the separately dashed near-field approach.
                // Known/suspected occupancy in that approach still vetoes the entire line.
                guard
                    PathClearance.segment(
                        grid: grid, from: SIMD2(f.x, f.z), to: center, radius: radius, allowUnknown: true)
                else { break }
                if supported {
                    trace.entry = point
                    last = point
                }
            } else {
                guard supported, let previous = last else { break }
                let a = grid.basis.local(previous)
                guard PathClearance.segment(grid: grid, from: SIMD2(a.x, a.z), to: center, radius: radius) else {
                    break
                }
                last = point
            }
        }
        if let entry = trace.entry, let last {
            trace.observedLength = simd_distance(entry, last)
            if trace.observedLength >= 0.3 - 0.00001 { trace.points = [entry, last] }
        }
        return trace
    }

    /// Test the full extension first. If occupied, bisect a monotonic prefix instead of
    /// walking hundreds of 2.5cm samples. The result still uses the identical swept width.
    private static func occupancyStraight(raster: RoutePlanningGrid,reference: ForwardRouteReference,
                                          foot: V3,start: Float,end: Float) -> StraightPathTrace {
        let entry = reference.point(start)
        guard raster.supports([foot,entry]) else { return .init() }
        var reach = end
        if !raster.supports([entry,reference.point(end)]) {
            var lo = start,hi = end
            for _ in 0..<16 {
                if hi-lo <= raster.grid.cellSize/4 { break }
                let middle = (lo+hi)/2
                if raster.supports([entry,reference.point(middle)]) { lo = middle }
                else { hi = middle }
            }
            reach = lo
        }
        let length = reach-start
        return .init(points:length >= 0.3 ? [entry,reference.point(reach)] : [],
                     entry:entry,observedLength:length)
    }

    /// Return to the earliest footprint-supported point past the obstacle, then continue along
    /// the original line. Choosing the fixed far goal alone cuts a long diagonal instead.
    static func detour(
        raster: RoutePlanningGrid, reference: ForwardRouteReference, obstacle: ForwardObstacle,
        entry: V3?, side: Int, goal: V3?
    ) -> (FanPathPlan, V3)? {
        let radius = raster.requiredWidth / 2
        let start = max(obstacle.far + radius + 0.2, reference.coordinates(entry ?? raster.grid.basis.origin).y + 0.35)
        let end = reference.coordinates(raster.grid.basis.origin).y + raster.maxDistance
        guard end > start else { return nil }
        for n in 0...min(12, Int(ceil((end - start) / max(0.2, raster.grid.cellSize)))) {
            let join = reference.point(start + Float(n) * max(0.2, raster.grid.cellSize))
            guard raster.contains(join) else { continue }
            let search = FanPathSearch.plan(
                grid: raster.grid, mask: raster.mask, width: raster.requiredWidth,
                halfAngleDegrees: 90, maxDistance: raster.maxDistance, fixedTarget: join, start: entry, allowUnknown:raster.obstacleVeto,
                cellFilter: { p in
                    let q = reference.coordinates(raster.grid.basis.world(x: p.x, h: 0, z: p.y))
                    // Commit to a side only through the obstacle's longitudinal envelope.
                    return q.y < obstacle.near - radius || q.y > obstacle.far + radius || Float(side) * q.x >= -0.00001
                })
            guard search.points.count >= 2 else { continue }
            var plan = search
            let continuation = straight(
                raster: raster, reference: reference, foot: join,
                maxProgress: goal.flatMap {
                    reference.coordinates($0).y > start + 0.3 ? reference.coordinates($0).y : nil
                })
            if let last = continuation.points.last, simd_distance(last, join) >= 0.3,
                raster.supports([join, last])
            {
                plan.points.append(last)
            }
            return (plan, join)
        }
        return nil
    }

    static func sideRoute(
        raster: RoutePlanningGrid, reference: ForwardRouteReference, obstacle: ForwardObstacle,
        entry: V3?, side: Int
    ) -> FanPathPlan {
        FanPathSearch.plan(
            grid: raster.grid, mask: raster.mask, width: raster.requiredWidth,
            halfAngleDegrees: 90, maxDistance: raster.maxDistance, start: entry, allowUnknown:raster.obstacleVeto,
            cellFilter: { p in
                let q = reference.coordinates(raster.grid.basis.world(x: p.x, h: 0, z: p.y))
                return q.y < obstacle.near - raster.requiredWidth / 2 || Float(side) * q.x >= -0.00001
            },
            targetFilter: { p in
                let q = reference.coordinates(raster.grid.basis.world(x: p.x, h: 0, z: p.y))
                let outside =
                    side < 0
                    ? q.x < obstacle.minLateral - raster.requiredWidth / 2
                    : q.x > obstacle.maxLateral + raster.requiredWidth / 2
                return outside
                    && q.y
                        >= max(
                            obstacle.near + raster.requiredWidth / 2,
                            reference.coordinates(entry ?? raster.grid.basis.origin).y + 0.3)
            })
    }
}
