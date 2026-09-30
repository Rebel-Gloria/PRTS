import Foundation
import simd

/// Current occupied cell geometry, separate from the temporal match anchor. The timer may
/// follow a nearby cell, but its old centre must never replace the newly measured footprint.
/// World footprints also survive a rotated search window clipping away the obstacle.
public struct OccupancyFootprint: Codable, Sendable {
    public var center: V3
    public var right: V3
    public var forward: V3
    public var size: Float

    func local(_ world: V3) -> SIMD2<Float> {
        let delta = world-center
        return SIMD2(simd_dot(delta,right),simd_dot(delta,forward))
    }
    public func overlaps(from a: V3, to b: V3, radius: Float) -> Bool {
        PathClearance.overlapsCell(from:local(a),to:local(b),center:.zero,cellSize:size,radius:radius)
    }
    /// Stamp every overlapping cell, not only the centre. Centre-only rebinning produces
    /// cracks in a continuous wall when sensor and planning rasters have different yaw.
    func stamp(into grid: inout LocalGrid) {
        let half = size/2
        let corners = [center-right*half-forward*half, center+right*half-forward*half,
                       center+right*half+forward*half, center-right*half+forward*half].map {
            let q = grid.basis.local($0); return SIMD2(q.x,q.z)
        }
        let low = corners.reduce(SIMD2<Float>(repeating:.infinity),simd_min)
        let high = corners.reduce(SIMD2<Float>(repeating:-.infinity),simd_max)
        let x0 = max(0,Int(floor((low.x+grid.halfWidth)/grid.cellSize)))
        let x1 = min(grid.columns-1,Int(floor((high.x+grid.halfWidth)/grid.cellSize)))
        let z0 = max(0,Int(floor(low.y/grid.cellSize))), z1 = min(grid.rows-1,Int(floor(high.y/grid.cellSize)))
        guard x0 <= x1, z0 <= z1 else { return }
        let edges = [corners[1]-corners[0],corners[3]-corners[0]]
        let axes = [SIMD2<Float>(1,0),SIMD2<Float>(0,1)] + edges.map { simd_normalize(SIMD2(-$0.y,$0.x)) }
        for z in z0...z1 { for x in x0...x1 {
            let i = z*grid.columns+x, c = grid.center(i), h = grid.cellSize/2
            let intersects = axes.allSatisfy { axis in
                let values = corners.map { simd_dot($0,axis) }
                let mid = simd_dot(c,axis), extent = h*(abs(axis.x)+abs(axis.y))
                return values.max()! > mid-extent+0.00001 && values.min()! < mid+extent-0.00001
            }
            if intersects { grid.cells[i].state = .obstacle; grid.cells[i].obstacleSamples = 3 }
        }}
    }
}
