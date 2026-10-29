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
        raster.supportsDisk(at:point,radius:distance)
    }

    static func avoid(raster: RoutePlanningGrid, reference: ForwardRouteReference,
                      obstacle: ForwardObstacle, foot: V3, preferredSide: Int) -> Plan? {
        // Prefer a little separation from the measured edge to avoid immediate replan on
        // the next raster phase. This is a preference: retry the exact requested width so
        // a 0.50m passage stays admissible. All shortcuts use the same selected width.
        var comfortable = raster
        comfortable.requiredWidth += 0.16
        comfortable.mask = PathClearance.mask(grid:comfortable.grid,radius:comfortable.requiredWidth/2,allowUnknown:true)
        if preferredSide != 0, let retained = search(raster:comfortable,reference:reference,obstacle:obstacle,foot:foot,preferredSide:preferredSide,onlyPreferred:true)
            ?? search(raster:raster,reference:reference,obstacle:obstacle,foot:foot,preferredSide:preferredSide,onlyPreferred:true) { return retained }
        return search(raster:comfortable,reference:reference,obstacle:obstacle,foot:foot,preferredSide:preferredSide)
            ?? search(raster:raster,reference:reference,obstacle:obstacle,foot:foot,preferredSide:preferredSide)
    }

    private static func search(raster: RoutePlanningGrid, reference: ForwardRouteReference,
                               obstacle: ForwardObstacle, foot: V3, preferredSide: Int, onlyPreferred: Bool = false) -> Plan? {
        let sides = onlyPreferred ? [preferredSide] : preferredSide == 0 ? [-1, 1] : [preferredSide, -preferredSide]
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

    /// If all bend vertices are outside the image, a segment may still cross the view.
    /// Select a point ON that checked segment instead of rejecting the entire route or
    /// connecting across a corner. The suffix starts at the same inserted point.
    static func visiblePlan(_ plan: Plan, pose: RigidPose, view: RouteCameraView?, normal: V3,
                            minimumDistance: Float) -> (Plan, Int)? {
        if let index = targetIndex(in:plan.points,pose:pose,view:view,normal:normal) { return (plan,index) }
        guard let view, let start = plan.points.first else { return nil }
        for index in 1..<plan.points.count {
            let a=plan.points[index-1], b=plan.points[index]
            let steps=max(1,Int(ceil(simd_distance(a,b)/0.1)))
            for step in stride(from:steps-1,through:1,by:-1) {
                let point=a+(b-a)*Float(step)/Float(steps)
                guard simd_distance(start,point) >= minimumDistance,
                      view.contains(point+normal*0.025,pose:pose,margin:-0.04) else { continue }
                var copy=plan
                copy.points.insert(point,at:index)
                return (copy,index)
            }
        }
        return nil
    }

    /// Usually the first bend is the current goal. If it is outside the actual image,
    /// keep the checked polyline to the first visible waypoint, never shortcut the corner.
    static func targetIndex(in points: [V3], pose: RigidPose, view: RouteCameraView?, normal: V3 = V3(0,1,0)) -> Int? {
        guard points.count >= 2 else { return nil }
        let eligible = (1..<points.count).filter { simd_distance(points[0], points[$0]) > 0.1 }
        return eligible.first(where: { view?.contains(points[$0] + normal * 0.025, pose: pose) ?? true })
    }
}
