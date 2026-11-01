import Foundation
import simd

/// Arc-window matching on the currently committed prefix. It cannot jump to a geometrically
/// close return leg far along the polyline. Keep 20cm behind the match for bounded reverse motion.
public enum RouteProgressWindow {
    public static func remaining(
        _ points: [V3],
        plane: GroundPlane,
        pose: RigidPose,
        maximumAdvance: Float
    ) -> [V3] {
        guard points.count >= 2 else { return points }
        let p = plane.project(pose.position)
        var arc: Float = 0
        var best = Float.infinity
        var matched: Float = 0
        for (a, b) in zip(points, points.dropFirst()) {
            let length = simd_distance(a, b)
            guard length > 0.00001 else { continue }
            if arc > maximumAdvance { break }
            let limit = min(1, max(0, (maximumAdvance - arc) / length))
            let t = min(limit, max(0, simd_dot(p - a, b - a) / (length * length)))
            let d = simd_distance(p, a + (b - a) * t)
            if d < best {
                best = d
                matched = arc + t * length
            }
            arc += length
        }
        var discard = max(0, matched - 0.2)
        for (index, pair) in zip(points, points.dropFirst()).enumerated() {
            let length = simd_distance(pair.0, pair.1)
            if discard < length {
                return [pair.0 + (pair.1 - pair.0) * (discard / max(0.00001, length))]
                    + Array(points.dropFirst(index + 1))
            }
            discard -= length
        }
        return []
    }
}
