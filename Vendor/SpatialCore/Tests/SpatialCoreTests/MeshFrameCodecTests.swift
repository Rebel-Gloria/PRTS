import XCTest
@testable import SpatialCore

final class MeshFrameCodecTests: XCTestCase {
    private let vertices = [V3(-0.0,1.25,-2),V3(0.25,1.25,-2),V3(0,1.5,-2)]
    private func encode(indices: [UInt32] = [0,1,2],classes: [UInt8] = [2]) throws -> Data {
        try MeshFrameCodec.encode(id:"synthetic-mesh",epoch:2,revision:7,callbackTime:10.5,transform:.init(position:V3(1,0,2)),
            vertices:vertices,indices:indices,classifications:classes,
            floorPriors:[.init(center:V3(0,1.25,-2),normal:V3(0,1,0))],source:"synthetic")
    }
    func testCompleteMeshLosslessRoundTripPreservesBitsAndProvenance() throws {
        let decoded = try MeshFrameCodec.decode(encode())
        XCTAssertEqual(decoded.header.source,"synthetic"); XCTAssertEqual(decoded.header.id,"synthetic-mesh")
        XCTAssertEqual(decoded.header.epoch,2); XCTAssertEqual(decoded.header.revision,7)
        XCTAssertEqual(decoded.header.transform.position,V3(1,0,2)); XCTAssertEqual(decoded.header.floorPriors.count,1)
        XCTAssertEqual(decoded.indices,[0,1,2]); XCTAssertEqual(decoded.classifications,[2])
        for i in vertices.indices { for axis in 0..<3 { XCTAssertEqual(vertices[i][axis].bitPattern,decoded.vertices[i][axis].bitPattern) } }
    }
    func testInvalidIndexOrMissingClassificationIsRejected() {
        XCTAssertThrowsError(try encode(indices:[0,1,3])); XCTAssertThrowsError(try encode(classes:[]))
    }
    func testTruncationAndMalformedLengthAreRejected() throws {
        var bytes = try encode(); bytes.removeLast(); XCTAssertThrowsError(try MeshFrameCodec.decode(bytes))
        bytes = try encode(); bytes.replaceSubrange(0..<4,with:[255,255,255,255]); XCTAssertThrowsError(try MeshFrameCodec.decode(bytes))
    }
    func testCorruptIndexInBinaryIsRejected() throws {
        var bytes = try encode()
        let n = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self).littleEndian })
        bytes.replaceSubrange(4+n+vertices.count*12..<4+n+vertices.count*12+4,with:[255,255,255,255])
        XCTAssertThrowsError(try MeshFrameCodec.decode(bytes))
    }
    func testBinaryMeshSurvivesDiagnosticCompression() throws {
        let raw = try encode(),compressed = try (raw as NSData).compressed(using:.zlib)
        let restored = try compressed.decompressed(using:.zlib) as Data
        XCTAssertEqual(raw,restored); XCTAssertEqual(try MeshFrameCodec.decode(restored).vertices.count,3)
    }
    func testEmptyRemovedMeshHasValidEmptyEncoding() throws {
        let data = try MeshFrameCodec.encode(id:"empty",epoch:1,revision:1,callbackTime:0,transform:.init(),
            vertices:[],indices:[],classifications:[],floorPriors:[],source:"synthetic")
        let d = try MeshFrameCodec.decode(data); XCTAssertTrue(d.vertices.isEmpty); XCTAssertTrue(d.classifications.isEmpty)
    }
}
