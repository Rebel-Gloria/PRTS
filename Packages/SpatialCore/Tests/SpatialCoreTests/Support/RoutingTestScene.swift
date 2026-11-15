import Foundation
import simd

@testable import SpatialCore

/// Shared synthetic geometry only; this fixture has no XCTest lifecycle or test methods.
struct RoutingTestScene {
    func frame(
        _ id: UInt64 = 1,
        _ time: Double = 1,
        pose: RigidPose = .init(position: V3(0, 1.4, 0)),
        cells: (V3) -> CellState = { _ in .candidate }
    ) -> AnalysisResult {
        let p = ProbeParameters()
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0, floorPriorConfirmed: true)
        var grid = LocalGrid(
            basis: GroundBasis(plane: plane, pose: pose)!,
            parameters: p,
            timestamp: time,
            frameID: id,
            epoch: 1
        )
        var triangles: [SurfaceTriangle] = []
        for i in grid.cells.indices {
            let c = grid.center(i)
            let world = grid.basis.world(x: c.x, h: 0, z: c.y)
            let state: CellState = c.y < 0.2 ? .unknown : cells(world)
            grid.cells[i].state = state
            grid.cells[i].obstacleSamples = state == .obstacle ? 6 : 0
            if state == .candidate {
                let s = grid.cellSize / 2
                let a = grid.basis.world(x: c.x - s, h: 0, z: c.y - s)
                let b = grid.basis.world(x: c.x + s, h: 0, z: c.y - s)
                let d = grid.basis.world(x: c.x - s, h: 0, z: c.y + s)
                let e = grid.basis.world(x: c.x + s, h: 0, z: c.y + s)
                triangles += [
                    .init(a: a, b: b, c: d, surface: .ground),
                    .init(a: b, b: e, c: d, surface: .ground),
                ]
            }
        }
        var r = AnalysisResult(
            epoch: 1,
            frameID: id,
            timestamp: time,
            parameters: p,
            status: "synthetic",
            source: "synthetic"
        )
        r.grid = grid
        r.plane = plane
        r.sourcePose = pose
        r.sourceDirectionStable = true
        r.diagnostics = AnalysisDiagnostics()
        r.diagnostics?.groundReferenceMode = "current_confirmed"
        r.surfaceModel = .init(
            triangles: triangles,
            summary: .init(
                groundTriangles: triangles.count,
                protrusionTriangles: 0,
                minimumProtrusionHeight: 0.05,
                maximumObservedProtrusionHeight: nil,
                samplingStep: 2
            )
        )
        return r
    }
    func box(_ p: V3) -> CellState {
        abs(p.x) < 0.1 && -p.z > 0.8 && -p.z < 1 ? .obstacle : .candidate
    }
    func pose(yaw: Float, position: V3 = V3(0, 1.4, 0)) -> RigidPose {
        let a = yaw * Float.pi / 180
        return .init(
            right: V3(cos(a), 0, -sin(a)),
            up: V3(0, 1, 0),
            back: V3(sin(a), 0, cos(a)),
            position: position
        )
    }
}
