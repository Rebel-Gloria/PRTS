import Foundation
import simd

/// Rebase only elevation. Normal projection would also move the retained horizontal intent.
enum LocalGroundRebase {
    static func accepts(_ plane: GroundPlane) -> Bool {
        plane.offset.isFinite && plane.normal.x.isFinite && plane.normal.y.isFinite &&
            plane.normal.z.isFinite && plane.normal.y > 0.25 && abs(simd_length(plane.normal)-1) < 0.001
    }
    static func needed(from old: GroundPlane, to next: GroundPlane, at camera: V3) -> Bool {
        abs(next.height(old.project(camera))) > 0.04 || simd_dot(old.normal,next.normal) < cos(3 * .pi / 180)
    }
    static func lift(_ point: V3, to plane: GroundPlane) -> V3 {
        V3(point.x, -(plane.offset+plane.normal.x*point.x+plane.normal.z*point.z)/plane.normal.y, point.z)
    }
}
