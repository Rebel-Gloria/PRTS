import Foundation
import simd

/// Rasterizes the actual BLUE triangles, not the infinite plane. Nine subcell tests must ALL be
/// supported. Unknown holes and red projections remain closed, including diagonal corner gaps.
public struct BluePathGrid: Sendable {
    public var grid: LocalGrid
    public var mask: [Bool]
    public var blueCells: Int
    public var requiredWidth: Float
    public var halfAngle: Float
    public var maxDistance: Float
    public init?(result: AnalysisResult, options: PathOptions = .init()) {
        guard var grid = result.grid, let model = result.surfaceModel else { return nil }
        grid.cells = Array(repeating: GridCell(), count: grid.cells.count)
        var coverage = Array(repeating: UInt16(0), count: grid.cells.count)
        let offsets: [Float] = [-0.4, 0, 0.4]
        for t in model.triangles where t.surface == .ground {
            let vertices = [t.a, t.b, t.c].map { grid.basis.local($0) }
            guard vertices.allSatisfy({ $0.x.isFinite && $0.z.isFinite }) else { continue }
            let a = SIMD2(vertices[0].x, vertices[0].z)
            let b = SIMD2(vertices[1].x, vertices[1].z)
            let c = SIMD2(vertices[2].x, vertices[2].z)
            let cross: (SIMD2<Float>, SIMD2<Float>) -> Float = { $0.x * $1.y - $0.y * $1.x }
            let area = cross(b - a, c - a)
            guard abs(area) > 0.0000001 else { continue }
            let minX = max(0, Int(floor((min(a.x, b.x, c.x) + grid.halfWidth) / grid.cellSize)))
            let maxX = min(
                grid.columns - 1,
                Int(floor((max(a.x, b.x, c.x) + grid.halfWidth) / grid.cellSize))
            )
            let minZ = max(0, Int(floor(min(a.y, b.y, c.y) / grid.cellSize)))
            let maxZ = min(grid.rows - 1, Int(floor(max(a.y, b.y, c.y) / grid.cellSize)))
            guard minX <= maxX, minZ <= maxZ else { continue }
            for z in minZ...maxZ {
                for x in minX...maxX {
                    let i = z * grid.columns + x
                    let center = grid.center(i)
                    if coverage[i] == 511 { continue }
                    for (zz, dz) in offsets.enumerated() {
                        for (xx, dx) in offsets.enumerated() {
                            let bit = UInt16(1 << (zz * 3 + xx))
                            if coverage[i] & bit != 0 { continue }
                            let p = center + SIMD2(dx, dz) * grid.cellSize
                            let u = cross(b - p, c - p) / area
                            let v = cross(c - p, a - p) / area
                            let w = 1 - u - v
                            if min(u, v, w) >= -0.00001 { coverage[i] |= bit }
                        }
                    }
                }
            }
        }
        var count = 0
        for i in grid.cells.indices {
            let measured = result.grid!.cells[i]
            if measured.obstacleSamples > 0 || measured.state == .obstacle {
                grid.cells[i].state = .obstacle
            } else if coverage[i] == 511 {
                grid.cells[i].state = .candidate
                count += 1
            }
        }
        self.grid = grid
        blueCells = count
        requiredWidth = options.validated().minimumWidth
        halfAngle = options.validated().targetHalfAngleDegrees
        maxDistance = result.parameters.forwardRange
        mask = PathClearance.mask(grid: grid, radius: requiredWidth / 2)
    }
    public func contains(_ world: V3) -> Bool {
        let p = grid.basis.local(world)
        guard let i = grid.index(x: p.x, z: p.z) else { return false }
        return mask[i]
    }
    public func supports(_ points: [V3]) -> Bool {
        guard points.count >= 2 else { return false }
        return zip(points, points.dropFirst()).allSatisfy { a, b in
            let aa = grid.basis.local(a)
            let bb = grid.basis.local(b)
            return PathClearance.segment(
                grid: grid,
                from: SIMD2(aa.x, aa.z),
                to: SIMD2(bb.x, bb.z),
                radius: requiredWidth / 2
            )
        }
    }
    public func search(fixedTarget: V3? = nil) -> FanPathPlan {
        FanPathSearch.plan(
            grid: grid,
            mask: mask,
            width: requiredWidth,
            halfAngleDegrees: halfAngle,
            maxDistance: maxDistance,
            fixedTarget: fixedTarget
        )
    }
    public func plan() -> [V3] { search().points }

}
