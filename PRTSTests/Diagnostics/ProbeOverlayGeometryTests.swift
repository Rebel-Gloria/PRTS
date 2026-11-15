import Foundation
import SpatialCore
import Testing
import simd

@testable import PRTS

struct ProbeOverlayGeometryTests {
    private func makeGrid(_ states: [CellState]) throws -> LocalGrid {
        let basis = try #require(
            GroundBasis(plane: GroundPlane(normal: V3(0, 1, 0), offset: 0), pose: RigidPose())
        )
        var parameters = ProbeParameters()
        parameters.halfWidth = Float(states.count) * parameters.gridSize / 2
        parameters.forwardRange = parameters.gridSize
        var grid = LocalGrid(basis: basis, parameters: parameters)
        for (index, state) in states.enumerated() {
            grid.cells[index] = GridCell(state: state)
        }
        return grid
    }

    @Test func vertexLayoutMatchesTheMetalShader() {
        let vertex = WorldVertex(V3(2, 3, 4), SIMD4(1, 0, 0, 0.5))
        #expect(MemoryLayout<WorldVertex>.stride == 32)
        #expect(MemoryLayout<WorldVertex>.alignment == 16)
        #expect(MemoryLayout<WorldVertex>.offset(of: \.color) == 16)
        #expect(vertex.position == SIMD4(2, 3, 4, 1))
    }

    @Test func nativePlaneOutlineClosesInWorldCoordinatesAndMarksRetainedReferences() {
        let plane = NativePlaneObservation(
            id: "floor",
            classification: "floor",
            pose: RigidPose(position: V3(2, 3, 4)),
            boundary: [V3(0, 0, 0), V3(1, 0, 0), V3(0, 0, 1)],
            timestamp: 10
        )
        let current = ProbeOverlayGeometry.nativePlanes([plane], retainedPlaneID: nil)
        let retained = ProbeOverlayGeometry.nativePlanes([plane], retainedPlaneID: plane.id)
        #expect(current.count == 6)
        #expect(current.first?.position == SIMD4(2, 3, 4, 1))
        #expect(current.last?.position == current.first?.position)
        #expect(current.map(\.position) == retained.map(\.position))
        #expect(current.allSatisfy { $0.color == SIMD4(0.05, 0.5, 1, 0.75) })
        #expect(retained.allSatisfy { $0.color == SIMD4(1, 0.55, 0.12, 0.4) })
        #expect(ProbeOverlayGeometry.nativePlanes([], retainedPlaneID: nil).isEmpty)
    }

    @Test func gridColorsRemainDiagnosticAndChannelsStayAboveTheGrid() throws {
        let grid = try makeGrid([.unknown, .obstacle, .candidate])
        let segment = try JSONDecoder().decode(
            CandidateSegment.self,
            from: Data(
                """
                {"sector":"center","cellIndices":[0,1,2],"startDistance":0,
                 "length":0.2,"minimumObservedWidth":0.1,"stopReason":"synthetic"}
                """.utf8
            )
        )
        let geometry = ProbeOverlayGeometry.grid(grid, segments: [segment])
        #expect(geometry.triangles.count == 18)
        #expect(geometry.lines.count == 4)
        #expect(geometry.triangles[0].color == SIMD4(0.6, 0.6, 0.65, 0.18))
        #expect(geometry.triangles[6].color == SIMD4(1, 0.2, 0.1, 0.55))
        #expect(geometry.triangles[12].color == SIMD4(0.1, 0.85, 0.7, 0.3))
        #expect(geometry.triangles.allSatisfy { $0.position.y == 0.015 })
        #expect(geometry.lines.allSatisfy { $0.position.y == 0.04 })
        #expect(geometry.lines[1].position == geometry.lines[2].position)
    }

    @Test func neighboringBlockingColumnsDoNotDrawAnInternalWall() throws {
        var grid = try makeGrid([.obstacle, .obstacle])
        for index in grid.cells.indices {
            grid.cells[index].obstacleSamples = 3
            grid.cells[index].minObstacleHeight = 0.1
            grid.cells[index].maxObstacleHeight = 0.2
        }
        let model = try #require(
            BlockingVolumeBuilder.build(
                grid: grid,
                groundConfirmed: true,
                parameters: ProbeParameters()
            )
        )
        let geometry = ProbeOverlayGeometry.blockingColumns(model, grid: grid)
        #expect(geometry.triangles.count == 48)
        #expect(geometry.lines.count == 64)
        for index in stride(from: 0, to: geometry.triangles.count, by: 3) {
            let triangle = geometry.triangles[index..<(index + 3)]
            #expect(!triangle.allSatisfy { $0.position.x == 0 })
        }
        #expect(geometry.triangles.allSatisfy { $0.position.y >= 0 && $0.position.y <= 1.8 })
    }

    @Test func historicalSurfaceKeepsTheObservedPointsAsFadedWireframe() throws {
        let triangles = try JSONDecoder().decode(
            [SurfaceTriangle].self,
            from: Data(
                """
                [{"a":[0,0,0],"b":[1,0,0],"c":[0,0,1],"surface":"ground"},
                 {"a":[0,1,0],"b":[1,1,0],"c":[0,1,1],"surface":"protrusion"}]
                """.utf8
            )
        )
        let current = ProbeOverlayGeometry.surface(triangles, historical: false)
        let historical = ProbeOverlayGeometry.surface(triangles, historical: true)
        let observedPositions = current.map(\.position)
        #expect(current.count == 6)
        #expect(historical.count == 12)
        #expect(current[0].color.w == 0.5)
        #expect(current[3].color.w == 0.75)
        #expect(historical.allSatisfy { $0.color.w == 0.22 })
        #expect(historical.allSatisfy { observedPositions.contains($0.position) })
    }
}
