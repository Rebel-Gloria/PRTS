import Foundation
import simd

/// Search raster, independent of rendered triangles. The caller selects input semantics:
/// obstacle-veto supplies an adapted grid (all non-vetoed cells candidate); the explicit
/// verified comparator supplies body-clear evidence. Never mutates the raw sensor result.
public struct RoutePlanningGrid: Sendable {
    public var grid: LocalGrid
    public var mask: [Bool]
    public var blueCells: Int
    public var requiredWidth: Float
    public var maxDistance: Float
    public var obstacleVeto: Bool
    public var obstacles: [OccupancyFootprint]?

    public init?(result: AnalysisResult, options: PathOptions = .init(), requireBodyClearance: Bool = false, obstacleVeto: Bool = false) {
        self.obstacleVeto = obstacleVeto
        obstacles = obstacleVeto ? result.planningObstacles : nil
        guard var grid = result.grid, result.plane != nil,
            grid.epoch == result.epoch, grid.frameID == result.frameID,
            grid.timestamp == result.timestamp
        else { return nil }
        var supported = 0
        for i in grid.cells.indices {
            let cell = grid.cells[i]
            if cell.obstacleSamples > 0 || cell.state == .obstacle {
                grid.cells[i].state = .obstacle
            } else if cell.state == .candidate || (!requireBodyClearance && cell.groundSamples >= 3 && cell.observedAt == result.timestamp) {
                grid.cells[i].state = .candidate
                supported += 1
            } else {
                grid.cells[i].state = .unknown
            }
        }
        self.grid = grid
        blueCells = supported
        requiredWidth = requireBodyClearance ? options.minimumWidth : options.validated().minimumWidth
        maxDistance = result.parameters.forwardRange
        mask = PathClearance.mask(grid: grid, radius: requiredWidth / 2, allowUnknown: obstacleVeto)
    }

    public func contains(_ world: V3) -> Bool {
        let q = grid.basis.local(world)
        return grid.index(x: q.x, z: q.z).map { mask[$0] } ?? false
    }

    func supportsDisk(at point: V3, radius: Float) -> Bool {
        if let obstacles { return !obstacles.contains { $0.overlaps(from:point,to:point,radius:radius) } }
        let p = grid.basis.local(point)
        return PathClearance.segment(grid:grid,from:SIMD2(p.x,p.z),to:SIMD2(p.x,p.z),radius:radius,allowUnknown:obstacleVeto)
    }

    public func supports(_ points: [V3]) -> Bool {
        guard points.count >= 2 else { return false }
        // Exact world geometry is authoritative, including occupied cells outside this
        // search window. Unknown/boundary permission never erases a known obstacle.
        if let obstacles {
            return zip(points,points.dropFirst()).allSatisfy { a,b in
                !obstacles.contains { $0.overlaps(from:a,to:b,radius:requiredWidth/2) }
            }
        }
        return zip(points, points.dropFirst()).allSatisfy { a, b in
            let aa = grid.basis.local(a)
            let bb = grid.basis.local(b)
            return PathClearance.segment(
                grid: grid, from: SIMD2(aa.x, aa.z), to: SIMD2(bb.x, bb.z), radius: requiredWidth / 2, allowUnknown: obstacleVeto)
        }
    }
}
