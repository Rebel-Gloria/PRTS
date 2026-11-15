import SpatialCore
import simd

/// Vertex layout shared with ProbeShaders; CPU overlay construction does not own Metal resources.
nonisolated struct WorldVertex: Sendable {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    init(_ p: V3, _ c: SIMD4<Float>) {
        position = SIMD4(p, 1)
        color = c
    }
}
/// Builds diagnostic overlays from already selected spatial values. The renderer retains all
/// cache, freshness and visibility decisions, so constructing vertices cannot authorize guidance.
nonisolated enum ProbeOverlayGeometry {
    static func nativePlanes(
        _ planes: [NativePlaneObservation],
        retainedPlaneID: String?
    ) -> [WorldVertex] {
        var vertices: [WorldVertex] = []
        for plane in planes {
            let color: SIMD4<Float> =
                retainedPlaneID == plane.id
                ? SIMD4(1, 0.55, 0.12, 0.4)
                : plane.classification == "floor"
                    ? SIMD4(0.05, 0.5, 1, 0.75) : SIMD4(1, 0.7, 0.1, 0.6)
            for i in plane.boundary.indices {
                vertices.append(WorldVertex(plane.pose.world(plane.boundary[i]), color))
                vertices.append(
                    WorldVertex(
                        plane.pose.world(plane.boundary[(i + 1) % plane.boundary.count]),
                        color
                    )
                )
            }
        }
        return vertices
    }

    static func blockingColumns(_ model: BlockingVolumeModel, grid: LocalGrid) -> (
        triangles: [WorldVertex], lines: [WorldVertex]
    ) {
        var triangles: [WorldVertex] = []
        var lines: [WorldVertex] = []
        let heights = Dictionary(
            uniqueKeysWithValues: model.columns.map { ($0.cellIndex, $0.ceiling) }
        )
        for column in model.columns {
            let i = column.cellIndex
            let center = grid.center(i)
            let half = grid.cellSize / 2
            let x = i % grid.columns
            let z = i / grid.columns
            let points: [V3] = [Float(0), column.ceiling].flatMap { height in
                [center.y - half, center.y + half].flatMap { forward in
                    [center.x - half, center.x + half].map { right in
                        grid.basis.world(x: right, h: height, z: forward)
                    }
                }
            }
            func face(_ indices: [Int]) {
                for v in [0, 1, 2, 2, 1, 3] {
                    triangles.append(WorldVertex(points[indices[v]], SIMD4(1, 0.04, 0.02, 0.12)))
                }
                for (a, b) in [(0, 1), (1, 3), (3, 2), (2, 0)] {
                    lines.append(WorldVertex(points[indices[a]], SIMD4(1, 0.12, 0.07, 0.65)))
                    lines.append(WorldVertex(points[indices[b]], SIMD4(1, 0.12, 0.07, 0.65)))
                }
            }
            face([4, 5, 6, 7])  // Diagnostic ceiling; no claim that a physical surface exists here.
            for (dx, dz, indices) in [
                (-1, 0, [0, 2, 4, 6]), (1, 0, [1, 3, 5, 7]), (0, -1, [0, 1, 4, 5]),
                (0, 1, [2, 3, 6, 7]),
            ] {
                let nx = x + dx
                let nz = z + dz
                if nx >= 0, nx < grid.columns, nz >= 0, nz < grid.rows,
                    let neighbor = heights[nz * grid.columns + nx], neighbor >= column.ceiling
                {
                    continue
                }
                face(indices)
            }
        }
        return (triangles, lines)
    }

    static func surface(_ triangles: [SurfaceTriangle], historical: Bool) -> [WorldVertex] {
        triangles.flatMap { triangle -> [WorldVertex] in
            let color: SIMD4<Float> =
                triangle.surface == .ground
                ? SIMD4(0.1, 0.45, 1, historical ? 0.22 : 0.50)
                : SIMD4(1, 0.08, 0.04, historical ? 0.22 : 0.75)
            let points =
                historical
                ? [triangle.a, triangle.b, triangle.b, triangle.c, triangle.c, triangle.a]
                : [triangle.a, triangle.b, triangle.c]
            return points.map { WorldVertex($0, color) }
        }
    }

    static func grid(_ grid: LocalGrid, segments: [CandidateSegment]) -> (
        triangles: [WorldVertex], lines: [WorldVertex]
    ) {
        var triangles: [WorldVertex] = []
        var lines: [WorldVertex] = []
        for i in grid.cells.indices {
            let center = grid.center(i)
            let h = grid.cellSize * 0.46
            let cell = grid.cells[i]
            let color: SIMD4<Float>
            switch cell.state {
            case .unknown: color = SIMD4(0.6, 0.6, 0.65, 0.18)
            case .obstacle: color = SIMD4(1, 0.2, 0.1, 0.55)
            case .candidate: color = SIMD4(0.1, 0.85, 0.7, 0.3)
            }
            let corners = [(-h, -h), (h, -h), (-h, h), (h, h)].map {
                grid.basis.world(x: center.x + $0.0, h: 0.015, z: center.y + $0.1)
            }
            for c in [0, 1, 2, 2, 1, 3] { triangles.append(WorldVertex(corners[c], color)) }
        }
        for segment in segments {
            for n in 1..<segment.cellIndices.count {
                for i in [segment.cellIndices[n - 1], segment.cellIndices[n]] {
                    let c = grid.center(i)
                    lines.append(
                        WorldVertex(
                            grid.basis.world(x: c.x, h: 0.04, z: c.y),
                            SIMD4(1, 0.85, 0.05, 1)
                        )
                    )
                }
            }
        }
        return (triangles, lines)
    }
}
