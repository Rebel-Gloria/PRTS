import Foundation
import simd

public struct PathHeading: Codable, Sendable {
    public var angleDegrees: Float  // signed: positive means target to the right
    public var crossTrack: Float
    public var startDistance: Float
    public var target: V3
    public var remainingLength: Float
}
public enum PathTracking {
    public static func distance(_ p: V3, to a: V3, end b: V3) -> Float {
        let d = b - a
        let t = max(0, min(1, simd_dot(p - a, d) / max(0.000001, simd_length_squared(d))))
        return simd_distance(p, a + d * t)
    }
    public static func remaining(_ points: [V3], plane: GroundPlane, pose: RigidPose) -> [V3] {
        guard points.count >= 2 else { return [] }
        let p = plane.project(pose.position)
        var nearest = 0
        var best = Float.infinity
        for i in 0..<(points.count - 1) {
            let d = distance(p, to: points[i], end: points[i + 1])
            if d < best {
                best = d
                nearest = i
            }
        }
        let a = points[nearest]
        let b = points[nearest + 1]
        let d = b - a
        let t = max(0, min(1, simd_dot(p - a, d) / max(0.000001, simd_length_squared(d))))
        let first = a + d * t
        let tail = Array(points.dropFirst(nearest + 1))
        return simd_distance(first, tail[0]) < 0.001 ? tail : [first] + tail
    }
    /// Pure-pursuit-style look-ahead target; this is heading feedback, NOT steering control.
    public static func heading(path: PredictedPath, pose: RigidPose, lookAhead: Float)
        -> PathHeading?
    {
        guard let basis = GroundBasis(plane: path.plane, pose: pose) else { return nil }
        let points =
            path.verifiedEvidence == true || path.planningPolicy == .obstacleVeto
            ? RouteProgressWindow.remaining(
                path.points,
                plane: path.plane,
                pose: pose,
                maximumAdvance: 0.5
            )
            : remaining(path.points, plane: path.plane, pose: pose)
        guard points.count >= 2 else { return nil }
        let length = zip(points, points.dropFirst()).reduce(Float(0)) {
            $0 + simd_distance($1.0, $1.1)
        }
        guard length >= 0.25 else { return nil }
        var target = points.last!
        var left = lookAhead
        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            let (a, b) = pair
            let d = simd_distance(a, b)
            if d >= left {
                target = a + (b - a) * (left / max(0.001, d))
                break
            }
            // A long pure-pursuit carrot can point through the inside of a box even though
            // the polyline avoids it. Stop at a significant next corner until it is reached.
            if path.forwardStrategy == true, index + 2 < points.count, d > 0.001 {
                let next = points[index + 2] - b
                if simd_length(next) > 0.001,
                    simd_dot((b - a) / d, simd_normalize(next)) < cos(15 * Float.pi / 180),
                    simd_distance(basis.origin, b) > 0.08
                {
                    target = b
                    break
                }
            }
            left -= d
        }
        let q = basis.local(target)
        guard hypot(q.x, q.z) > 0.05 else { return nil }
        let start = basis.local(points[0])
        let tangent = simd_normalize(points[1] - points[0])
        let lateral = abs(
            simd_dot(basis.origin - points[0], simd_cross(tangent, path.plane.normal))
        )
        guard lateral.isFinite else { return nil }
        return .init(
            angleDegrees: atan2(q.x, q.z) * 180 / .pi,
            crossTrack: lateral,
            startDistance: hypot(start.x, start.z),
            target: target,
            remainingLength: length
        )
    }
}
