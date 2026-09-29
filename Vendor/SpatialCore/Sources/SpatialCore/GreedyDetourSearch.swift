import Foundation
import simd

/// Try a short rectangle-like bypass before graph search. Greedy candidates increase lateral
/// displacement and rejoin distance; every swept segment still checks the full footprint.
enum GreedyDetourSearch {
  static func plan(
    raster: RoutePlanningGrid, reference: ForwardRouteReference,
    obstacle: ForwardObstacle, entry: V3?, side: Int
  ) -> (FanPathPlan, V3)? {
    guard let entry else { return nil }
    let radius = raster.requiredWidth / 2
    let step = max(raster.grid.cellSize, 0.1)
    let start = reference.coordinates(entry)
    let cornerProgress = obstacle.near - radius - step
    guard cornerProgress > start.y + step else { return nil }
    let edge = side < 0 ? obstacle.minLateral - radius - step : obstacle.maxLateral + radius + step
    for extensionStep in 0..<4 {
      let joinProgress = obstacle.far + radius + step * Float(2 + extensionStep)
      let join = reference.point(joinProgress)
      guard raster.contains(join) else { continue }
      for lateralStep in 0..<6 {
        let offset = edge + Float(side * lateralStep) * step
        let before = reference.point(cornerProgress) + reference.right * offset
        let after = reference.point(obstacle.far + radius + step) + reference.right * offset
        var points = [entry, before, after, join]
        guard raster.supports(points) else { continue }
        // Greedily remove waypoints only when the entire shortcut is supported.
        var simplified = [points[0]]
        var index = 0
        while index < points.count - 1 {
          var next = points.count - 1
          while next > index + 1 && !raster.supports([points[index], points[next]]) { next -= 1 }
          simplified.append(points[next])
          index = next
        }
        points = simplified
        let tail = ForwardPathSearch.straight(raster: raster, reference: reference, foot: join,
            maxProgress:reference.coordinates(raster.grid.basis.origin).y+raster.maxDistance)
        if let end = tail.points.last, raster.supports([join, end]) { points.append(end) }
        var plan = FanPathPlan()
        plan.points = points
        plan.targetDistance = simd_distance(raster.grid.basis.origin, points.last!)
        return (plan, join)
      }
    }
    return nil
  }
}
