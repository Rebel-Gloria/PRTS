import Foundation
import simd

public enum PathDrawingRole: String, Sendable {
  case observed, history, unknownApproach, target, prediction
}
public struct PathDrawingMesh: Sendable {
  public var role: PathDrawingRole
  public var vertices: [V3]
}
/// World-space ribbons and target marker shared by the actual renderer and deterministic tests.
/// Dashes are metric, not vertex-index based, so a simplified two-point line remains dashed.
public enum PathDrawing {
  public static func meshes(_ p: PathPresentation) -> [PathDrawingMesh] {
    let normal = p.path.plane.normal
    let lift = normal * 0.025
    var result = [
      PathDrawingMesh(
        role: .unknownApproach,
        vertices: ribbon(p.approach, normal: normal, width: 0.024, dashed: true)),
      PathDrawingMesh(
        role: p.historical ? .history : .observed,
        vertices: ribbon(p.path.points, normal: normal, width: 0.036, dashed: p.historical)),
    ]
    if let target = p.path.points.last {
      let right = simd_normalize(V3(1, 0, 0) - normal * normal.x)
      let forward = simd_cross(normal, right)
      let center = target + lift
      var ring: [V3] = []
      for i in 0..<24 {
        func point(_ j: Int, _ radius: Float) -> V3 {
          let angle = Float(j) / 24 * 2 * Float.pi
          return center + (right * cos(angle) + forward * sin(angle)) * radius
        }
        let a = point(i, 0.06)
        let b = point(i, 0.09)
        let c = point(i + 1, 0.06)
        let d = point(i + 1, 0.09)
        ring += [a, b, c, c, b, d]
      }
      result.append(.init(role: .target, vertices: ring))
    }
    return result
  }
  /// Draw no goal ring at the arbitrary far clipping plane.
  public static func projectionMesh(_ projection: RouteProjection, observed: PathPresentation?)
    -> PathDrawingMesh
  {
    var points = projection.points
    if let observed, !observed.historical, let end = observed.path.points.last,
      points.count == 2
    {
      let direction = simd_normalize(points[1] - points[0])
      let progress = simd_dot(end - points[0], direction)
      if progress > 0 && simd_distance(end, points[0] + direction * progress) < 0.08 {
        points[0] += direction * min(progress, simd_distance(points[0], points[1]))
      }
    }
    return .init(
      role: .prediction,
      vertices: ribbon(points, normal: projection.plane.normal, width: 0.036, dashed: false))
  }
  private static func ribbon(_ points: [V3], normal: V3, width: Float, dashed: Bool) -> [V3] {
    let lift = normal * 0.025
    var vertices: [V3] = []
    var travel: Float = 0
    for (a0, b0) in zip(points, points.dropFirst()) {
      let a = a0 + lift
      let b = b0 + lift
      let length = simd_distance(a, b)
      guard length.isFinite, length > 0.001 else { continue }
      let direction = (b - a) / length
      let side = simd_normalize(simd_cross(direction, normal)) * (width / 2)
      func quad(_ start: Float, _ end: Float) {
        let aa = a + direction * start
        let bb = a + direction * end
        vertices += [aa - side, aa + side, bb - side, bb - side, aa + side, bb + side]
      }
      if !dashed {
        quad(0, length)
      } else {
        var at: Float = 0
        while at < length - 0.00001 {
          let phase = (travel + at).truncatingRemainder(dividingBy: 0.22)
          let on = phase < 0.13
          let end = min(length, at + max(0.0001, (on ? 0.13 : 0.22) - phase))
          if on { quad(at, end) }
          at = end
        }
      }
      travel += length
    }
    return vertices
  }

}
