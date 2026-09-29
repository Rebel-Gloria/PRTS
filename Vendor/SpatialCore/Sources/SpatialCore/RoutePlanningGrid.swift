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

    public init?(result: AnalysisResult, options: PathOptions = .init(), requireBodyClearance: Bool = false, obstacleVeto: Bool = false) {
        self.obstacleVeto = obstacleVeto
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

    public func supports(_ points: [V3]) -> Bool {
        guard points.count >= 2 else { return false }
        return zip(points, points.dropFirst()).allSatisfy { a, b in
            let aa = grid.basis.local(a)
            let bb = grid.basis.local(b)
            return PathClearance.segment(
                grid: grid, from: SIMD2(aa.x, aa.z), to: SIMD2(bb.x, bb.z), radius: requiredWidth / 2, allowUnknown: obstacleVeto)
        }
    }
}
