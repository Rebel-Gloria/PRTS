import Foundation
import simd

/// Reuses the existing swept-width greedy/graph searches; only target scheduling changes.
enum ObstacleWaypointSearch {
    struct Plan: Sendable {
        var points: [V3]
        var side: Int
    }

    static func approach(raster: RoutePlanningGrid, reference: ForwardRouteReference,
                         obstacle: ForwardObstacle, foot: V3, standOff: Float) -> Plan? {
        let gap = max(standOff, raster.requiredWidth / 2 + raster.grid.cellSize)
        let start = reference.coordinates(foot).y
        let end = start + obstacle.distance - gap
        guard end > start + 0.1 else { return nil }
        // Also check neighbouring parts of a non-rectangular component: axial stand-off
        // alone would put the goal too close to a side protrusion.
        for retreat in stride(from: Float(0), through: end-start-0.1, by: raster.grid.cellSize) {
            let target = reference.point(end-retreat)
            if raster.supports([foot, target]) && hasStandOff(target, raster: raster, distance: standOff) {
                return .init(points: [foot, target], side: 0)
            }
        }
        return nil
    }

    static func hasStandOff(_ point: V3, raster: RoutePlanningGrid, distance: Float) -> Bool {
        let local = raster.grid.basis.local(point)
        let center = SIMD2(local.x, local.z)
        return PathClearance.segment(grid: raster.grid, from: center, to: center,
            radius: distance, allowUnknown: true)
    }

    static func avoid(raster: RoutePlanningGrid, reference: ForwardRouteReference,
                      obstacle: ForwardObstacle, foot: V3, preferredSide: Int) -> Plan? {
        let sides = preferredSide == 0 ? [-1, 1] : [preferredSide, -preferredSide]
        var choices: [Plan] = []
        for side in sides {
            let points: [V3]?
            if let (plan, _) = GreedyDetourSearch.plan(
                raster: raster, reference: reference, obstacle: obstacle, entry: foot, side: side) {
                points = plan.points
            } else if let (plan, _) = ForwardPathSearch.detour(
                raster: raster, reference: reference, obstacle: obstacle, entry: foot, side: side, goal: nil) {
                points = plan.points
            } else {
                points = ForwardPathSearch.sideRoute(
                    raster: raster, reference: reference, obstacle: obstacle, entry: foot, side: side).points
            }
            guard let points, points.count >= 2, raster.supports(points) else { continue }
            let plan = Plan(points: RouteArc.coalescingCollinear(points), side: side)
            if side == preferredSide { return plan } // Keep a viable bypass side; never force a blocked side.
            choices.append(plan)
        }
        return choices.min {
            let a = RouteArc.length($0.points), b = RouteArc.length($1.points)
            return abs(a-b) > 0.001 ? a < b : $0.side < $1.side
        }
    }

    /// Usually the first bend is the current goal. If it is outside the actual image,
    /// keep the checked polyline to the first visible waypoint, never shortcut the corner.
    static func targetIndex(in points: [V3], pose: RigidPose, view: RouteCameraView?, normal: V3 = V3(0,1,0)) -> Int? {
        guard points.count >= 2 else { return nil }
        let eligible = (1..<points.count).filter { simd_distance(points[0], points[$0]) > 0.1 }
        return eligible.first(where: { view?.contains(points[$0] + normal * 0.025, pose: pose) ?? true })
    }
}
