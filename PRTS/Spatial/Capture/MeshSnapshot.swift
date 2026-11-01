import ARKit
import Foundation
import SpatialCore
import simd

nonisolated struct MeshSnapshot: Codable, Sendable {
    let id: String
    let epoch: UInt64
    let revision: UInt64
    let callbackTime: Double
    let transform: RigidPose
    let vertices: [V3]  // anchor-local
    let indices: [UInt32]
    let classifications: [UInt8]
    let floorPriors: [FloorPrior]
    var byteCount: Int { vertices.count * 16 + indices.count * 4 + classifications.count }
    static func copy(_ anchor: ARMeshAnchor, epoch: UInt64, revision: UInt64, time: Double)
        -> MeshSnapshot?
    {
        let geometry = anchor.geometry
        let source = geometry.vertices
        let faces = geometry.faces
        guard source.format == .float3, faces.indexCountPerPrimitive == 3,
            faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
            source.count <= 150_000, faces.count <= 200_000
        else { return nil }
        var vertices: [V3] = []
        vertices.reserveCapacity(source.count)
        let ptr = source.buffer.contents()
        for i in 0..<source.count {
            let p = ptr.advanced(by: source.offset + i * source.stride).assumingMemoryBound(
                to: Float.self
            )
            let vertex = V3(p[0], p[1], p[2])
            guard vertex.x.isFinite, vertex.y.isFinite, vertex.z.isFinite else { return nil }
            vertices.append(vertex)
        }
        let ip = faces.buffer.contents()
        var indices: [UInt32] = []
        indices.reserveCapacity(faces.count * 3)
        for i in 0..<(faces.count * 3) {
            let index =
                faces.bytesPerIndex == 2
                ? UInt32(ip.load(fromByteOffset: i * 2, as: UInt16.self))
                : ip.load(fromByteOffset: i * 4, as: UInt32.self)
            guard index < vertices.count else { return nil }
            indices.append(index)
        }
        var classes = [UInt8](repeating: 0, count: faces.count)
        if let source = geometry.classification, source.format == .uchar,
            source.count == faces.count
        {
            for i in 0..<source.count {
                classes[i] = source.buffer.contents().load(
                    fromByteOffset: source.offset + i * source.stride,
                    as: UInt8.self
                )
            }
        }
        let transform = RigidPose(anchor.transform)
        var priors: [FloorPrior] = []
        let sampleStep = max(1, faces.count / 128)
        for face in stride(from: 0, to: faces.count, by: sampleStep)
        where classes[face] == UInt8(ARMeshClassification.floor.rawValue) {
            let a = transform.world(vertices[Int(indices[face * 3])])
            let b = transform.world(vertices[Int(indices[face * 3 + 1])])
            let c = transform.world(vertices[Int(indices[face * 3 + 2])])
            let cross = simd_cross(b - a, c - a)
            guard simd_length(cross) > 0.0001 else { continue }
            var normal = simd_normalize(cross)
            if normal.y < 0 { normal = -normal }
            priors.append(
                .init(
                    center: (a + b + c) / 3,
                    normal: normal,
                    anchorID: anchor.identifier.uuidString,
                    revision: revision,
                    callbackTime: time
                )
            )
        }
        return .init(
            id: anchor.identifier.uuidString,
            epoch: epoch,
            revision: revision,
            callbackTime: time,
            transform: transform,
            vertices: vertices,
            indices: indices,
            classifications: classes,
            floorPriors: priors
        )
    }
}
