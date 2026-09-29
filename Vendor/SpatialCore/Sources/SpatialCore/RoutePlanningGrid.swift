import Foundation
import simd

/// Planning uses measured ground samples, not the renderer's triangle edge/pixel-hole budget.
/// This is a ground-supported route proposal; full-height clearance remains a separate grid output.
/// No floor plane is extended into unobserved cells, and every measured obstacle takes precedence.
public struct RoutePlanningGrid: Sendable {
    public var grid: LocalGrid
    public var mask: [Bool]
    public var blueCells: Int
    public var requiredWidth: Float
    public var maxDistance: Float

    public init?(result: AnalysisResult, options: PathOptions = .init()) {
        guard var grid = result.grid, result.plane != nil,
            grid.epoch == result.epoch, grid.frameID == result.frameID,
            grid.timestamp == result.timestamp
        else { return nil }
        var supported = 0
        for i in grid.cells.indices {
            let cell = grid.cells[i]
            if cell.obstacleSamples > 0 || cell.state == .obstacle {
                grid.cells[i].state = .obstacle
            } else if cell.state == .candidate || (cell.groundSamples >= 3 && cell.observedAt == result.timestamp) {
                grid.cells[i].state = .candidate
                supported += 1
            } else {
                grid.cells[i].state = .unknown
            }
        }
        self.grid = grid
        blueCells = supported
        requiredWidth = options.validated().minimumWidth
        maxDistance = result.parameters.forwardRange
        mask = PathClearance.mask(grid: grid, radius: requiredWidth / 2)
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
                grid: grid, from: SIMD2(aa.x, aa.z), to: SIMD2(bb.x, bb.z), radius: requiredWidth / 2)
        }
    }
}
