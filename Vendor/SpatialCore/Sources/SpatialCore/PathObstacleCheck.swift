import Foundation
import simd

/// Final current-depth veto shared by retained and newly planned lines.
enum PathObstacleCheck {
    static func intersects(
        _ path: PredictedPath, result r: AnalysisResult, observation: DepthObservation?, includeApproach: Bool = true
    ) -> Bool {
        reason(path, result: r, observation: observation, includeApproach: includeApproach) != nil
    }

    static func reason(
        _ path: PredictedPath, result r: AnalysisResult, observation: DepthObservation?, includeApproach: Bool = true
    ) -> String? {
        var worldSegments = Array(zip(path.points, path.points.dropFirst()))
        if includeApproach, let pose = r.sourcePose ?? observation?.pose, let first = path.points.first {
            worldSegments.append((path.plane.project(pose.position), first))
        }
        if let footprints = r.planningObstacles {
            return worldSegments.contains { a,b in
                footprints.contains { $0.overlaps(from:a,to:b,radius:path.requiredWidth/2) }
            } ? "confirmed_world_occupancy" : nil
        }
        if let grid = r.grid {
            for (a, b) in worldSegments {
                let aa = grid.basis.local(a)
                let bb = grid.basis.local(b)
                if !PathClearance.segment(
                    grid: grid, from: SIMD2(aa.x, aa.z), to: SIMD2(bb.x, bb.z), radius: path.requiredWidth / 2,
                    allowUnknown: true)
                {
                    return "grid_occupancy"
                }
            }
        }
        // Use CURRENT depth against the retained plane even when fitting a new ground failed.
        // Square-distance checks agree with planning; a circle around each cell would falsely
        // invalidate an exactly 0.50 m corridor on every following frame.
        if let o = observation, let basis = GroundBasis.geometry(plane: path.plane, pose: o.pose, previousForward: nil)
        {
            var counts: [SIMD2<Int>: Int] = [:]
            for p in o.points(parameters: r.parameters) {
                let q = basis.local(p)
                guard q.y > max(0.05, r.parameters.planeTolerance),
                    q.y < r.parameters.bodyHeight + r.parameters.depthMargin
                else { continue }
                counts[SIMD2(Int(floor(q.x / 0.1)), Int(floor(q.z / 0.1))), default: 0] += 1
            }
            let segments = worldSegments.map { a, b -> (SIMD2<Float>, SIMD2<Float>) in
                let aa = basis.local(a)
                let bb = basis.local(b)
                return (SIMD2(aa.x, aa.z), SIMD2(bb.x, bb.z))
            }
            for (key, count) in counts {
                // A supported cluster can straddle a cell boundary. Requiring three samples
                // in exactly one quantization bin misses a centred narrow obstacle.
                var support = count
                for dz in -1...1 {
                    for dx in -1...1 where dx != 0 || dz != 0 {
                        support += counts[key &+ SIMD2(dx, dz), default: 0]
                    }
                }
                guard support >= 3 else { continue }
                let center = SIMD2((Float(key.x) + 0.5) * 0.1, (Float(key.y) + 0.5) * 0.1)
                if segments.contains(where: {
                    PathClearance.overlapsCell(
                        from: $0.0, to: $0.1, center: center, cellSize: 0.1, radius: path.requiredWidth / 2)
                }) {
                    return "depth_occupancy"
                }
            }
        }
        return nil
    }
}
