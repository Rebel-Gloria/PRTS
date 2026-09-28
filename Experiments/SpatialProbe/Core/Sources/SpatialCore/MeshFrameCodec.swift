import Foundation

public struct MeshFrameHeader: Codable, Sendable {
    public var schemaVersion = 1
    public var kind = "mesh_frame"
    public var id: String,epoch: UInt64,revision: UInt64,callbackTime: Double
    public var transform: RigidPose,floorPriors: [FloorPrior],source: String
    public var vertexCount: Int,indexCount: Int,classificationCount: Int
}
public struct DecodedMeshFrame: Sendable {
    public var header: MeshFrameHeader
    public var vertices: [V3],indices: [UInt32],classifications: [UInt8]
}
/// Same complete mesh as the legacy JSON attachment, without decimal-encoding every vertex/index.
/// UInt32 LE header length + JSON metadata + Float32 LE xyz + UInt32 LE indices + UInt8 classes.
public enum MeshFrameCodec {
    private static func validCounts(_ h: MeshFrameHeader) -> Bool {
        h.kind == "mesh_frame" && h.schemaVersion == 1 && h.vertexCount >= 0 && h.vertexCount <= 150_000 &&
        h.indexCount >= 0 && h.indexCount <= 600_000 && h.indexCount % 3 == 0 && h.classificationCount == h.indexCount/3
    }
    public static func encode(id: String,epoch: UInt64,revision: UInt64,callbackTime: Double,transform: RigidPose,
                              vertices: [V3],indices: [UInt32],classifications: [UInt8],floorPriors: [FloorPrior],source: String) throws -> Data {
        let h = MeshFrameHeader(id:id,epoch:epoch,revision:revision,callbackTime:callbackTime,transform:transform,
                               floorPriors:floorPriors,source:source,vertexCount:vertices.count,indexCount:indices.count,classificationCount:classifications.count)
        guard validCounts(h),indices.allSatisfy({ $0 < vertices.count }),
              vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw CocoaError(.coderInvalidValue) }
        let json = try DiagnosticJSON.encode(h)
        var length = UInt32(json.count).littleEndian
        var data = withUnsafeBytes(of:&length) { Data($0) }
        data.reserveCapacity(4+json.count+vertices.count*12+indices.count*4+classifications.count)
        data.append(json)
        var words = [UInt32](); words.reserveCapacity(vertices.count*3+indices.count)
        for p in vertices { words.append(p.x.bitPattern.littleEndian); words.append(p.y.bitPattern.littleEndian); words.append(p.z.bitPattern.littleEndian) }
        words.append(contentsOf:indices.map(\.littleEndian))
        words.withUnsafeBytes { data.append(contentsOf:$0) }
        data.append(contentsOf:classifications)
        return data
    }
    public static func decode(_ data: Data) throws -> DecodedMeshFrame {
        guard data.count >= 4 else { throw CocoaError(.coderReadCorrupt) }
        let n = Int(data.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self).littleEndian })
        guard n > 0,n <= data.count-4 else { throw CocoaError(.coderReadCorrupt) }
        let header = try JSONDecoder().decode(MeshFrameHeader.self,from:data.subdata(in:4..<4+n))
        guard validCounts(header),data.count == 4+n+header.vertexCount*12+header.indexCount*4+header.classificationCount else { throw CocoaError(.coderReadCorrupt) }
        let vertices: [V3] = data.withUnsafeBytes { bytes in (0..<header.vertexCount).map { i in
            let p = 4+n+i*12
            return V3(Float(bitPattern:bytes.loadUnaligned(fromByteOffset:p,as:UInt32.self).littleEndian),
                      Float(bitPattern:bytes.loadUnaligned(fromByteOffset:p+4,as:UInt32.self).littleEndian),
                      Float(bitPattern:bytes.loadUnaligned(fromByteOffset:p+8,as:UInt32.self).littleEndian))
        }}
        let indices: [UInt32] = data.withUnsafeBytes { bytes in (0..<header.indexCount).map {
            bytes.loadUnaligned(fromByteOffset:4+n+header.vertexCount*12+$0*4,as:UInt32.self).littleEndian
        }}
        guard indices.allSatisfy({ $0 < header.vertexCount }),vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { throw CocoaError(.coderReadCorrupt) }
        return .init(header:header,vertices:vertices,indices:indices,classifications:Array(data.suffix(header.classificationCount)))
    }
}
