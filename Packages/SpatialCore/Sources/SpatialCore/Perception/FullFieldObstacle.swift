import simd

extension DepthObservation {
    /// Only used for structurally valid native depth without usable mapped ground.
    func hasFullFieldObstacle(parameters p: ProbeParameters) -> Bool {
        guard !isPrediction, let confidence, width >= 4, height >= 3, horizonCrossesDepthField
        else { return false }

        // Use the raw lattice, not the subsampled fitting points. A missing pixel still occupies
        // space in its tile; even one reliable far return at the very last pixel vetoes the frame.
        for row in 0..<3 {
            let ys = (row * height / 3)..<((row + 1) * height / 3)
            for column in 0..<4 {
                let xs = (column * width / 4)..<((column + 1) * width / 4)
                var near = 0
                for y in ys {
                    let start = y * width
                    for x in xs {
                        let i = start + x
                        guard confidence[i] == 2, depth[i].isFinite else { continue }
                        let z = depth[i]
                        // Above maxDepth still vetoes, even when the configured range ends below 40 cm.
                        if z >= 0.40 || z > p.maxDepth { return false }
                        if z > 0, z >= p.minDepth { near += 1 }
                    }
                }
                guard 3 * near > 2 * xs.count * ys.count else { return false }
            }
        }
        return true
    }

    private var horizonCrossesDepthField: Bool {
        // A unit-depth ray's world height relative to the camera is affine in (u, v).
        // Its extrema over the measured pixel centers are at the four corners, for any roll.
        let worldUpInCamera = V3(pose.right.y, pose.up.y, pose.back.y)
        var lowest = Float.infinity
        var highest = -Float.infinity
        for v in [0, Float(height - 1)] {
            for u in [0, Float(width - 1)] {
                let elevation = simd_dot(
                    worldUpInCamera,
                    intrinsics.unproject(u: u, v: v, depth: 1)
                )
                guard elevation.isFinite else { return false }
                lowest = min(lowest, elevation)
                highest = max(highest, elevation)
            }
        }
        return lowest < 0 && highest > 0
    }
}
