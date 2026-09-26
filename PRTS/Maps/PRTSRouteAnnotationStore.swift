import Foundation

struct PRTSRouteSegment: Codable, Identifiable, Equatable {
    let id: UUID
    var start: SIMD3<Float>
    var end: SIMD3<Float>

    init(start: SIMD3<Float>, end: SIMD3<Float>) {
        id = UUID(); self.start = start; self.end = end
    }
}

struct PRTSRouteAnnotationStore {
    var snapDistanceMeters: Float = 0.45

    func append(_ segment: PRTSRouteSegment, to routes: inout [PRTSRouteSegment]) {
        let snappedStart = snap(segment.start, to: routes)
        let snappedEnd = snap(segment.end, to: routes)
        routes.append(PRTSRouteSegment(start: snappedStart, end: snappedEnd))
    }

    private func snap(_ point: SIMD3<Float>, to routes: [PRTSRouteSegment]) -> SIMD3<Float> {
        let endpoints = routes.flatMap { [$0.start, $0.end] }
        return endpoints.min(by: { simd_distance($0, point) < simd_distance($1, point) }).flatMap {
            simd_distance($0, point) <= snapDistanceMeters ? $0 : nil
        } ?? point
    }
}
