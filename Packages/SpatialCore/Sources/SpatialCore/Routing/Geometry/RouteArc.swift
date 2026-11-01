import Foundation
import simd

public enum RouteArc {
    /// Merge only same-direction collinear vertices. No corner shortcut, obstacle query or
    /// change to the world-space curve; repeated rolling-tail appends stay two-point lines.
    public static func coalescingCollinear(_ points: [V3]) -> [V3] {
        var output: [V3] = []
        for point in points {
            if let last = output.last, simd_distance(last, point) < 0.00001 { continue }
            while output.count >= 2 {
                let a = output[output.count - 2]
                let b = output[output.count - 1]
                let ab = b - a
                let bc = point - b
                guard simd_dot(ab, bc) > 0,
                    simd_length(simd_cross(ab, bc)) <= 0.00001 * max(1, simd_length(ab + bc))
                else { break }
                output.removeLast()
            }
            output.append(point)
        }
        return output
    }
    public static func length(_ points: [V3]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }
    public static func prefix(_ points: [V3], length: Float) -> [V3] {
        guard let first = points.first else { return [] }
        var output = [first]
        var left = length
        for (a, b) in zip(points, points.dropFirst()) {
            let d = simd_distance(a, b)
            if left >= d {
                output.append(b)
                left -= d
            } else {
                if left > 0.001 { output.append(a + (b - a) * (left / max(d, 0.000001))) }
                break
            }
        }
        return output
    }
}
