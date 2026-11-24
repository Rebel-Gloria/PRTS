import XCTest

@testable import SpatialCore

final class DiagnosticTests: XCTestCase {
    private func observation() -> DepthObservation {
        .init(
            width: 2,
            height: 2,
            depth: [1, .nan, -1, .infinity],
            confidence: [2, 1, 0, 255],
            intrinsics: .init(fx: 2, fy: 2, cx: 0.5, cy: 0.5, width: 2, height: 2),
            pose: .init(position: V3(0, 1.3, 0)),
            timestamp: 12,
            frameID: 18,
            epoch: 3
        )
    }

    func testDepthFrameCodecPreservesDepthBitsWithoutRGB() throws {
        let o = observation()
        let raw = try DepthFrameCodec.encode(
            o,
            parameters: .init(),
            parameterVersion: 4,
            priors: [],
            directionStable: false,
            source: "synthetic"
        )
        let headerSize = Int(
            raw.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        )
        let header = try XCTUnwrap(
            JSONSerialization.jsonObject(with: raw.subdata(in: 4..<(4 + headerSize)))
                as? [String: Any]
        )
        XCTAssertEqual(header["source"] as? String, "synthetic")
        XCTAssertEqual(header["confidenceBytes"] as? Int, 4)
        let start = 4 + headerSize
        for i in o.depth.indices {
            let bits = raw.withUnsafeBytes {
                UInt32(
                    littleEndian: $0.loadUnaligned(fromByteOffset: start + i * 4, as: UInt32.self)
                )
            }
            XCTAssertEqual(bits, o.depth[i].bitPattern)
        }
        XCTAssertEqual(Array(raw.suffix(4)), o.confidence)
        XCTAssertFalse(header.keys.contains("capturedImage"))
        XCTAssertFalse(header.keys.contains("rgb"))
    }

    func testMissingConfidenceIsNotFabricated() throws {
        var o = observation()
        o.confidence = nil
        let data = try DepthFrameCodec.encode(
            o,
            parameters: .init(),
            parameterVersion: 0,
            priors: [],
            directionStable: false,
            source: "synthetic"
        )
        let size = Int(
            data.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        )
        let h = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data.subdata(in: 4..<(4 + size))) as? [String: Any]
        )
        XCTAssertEqual(h["confidenceBytes"] as? Int, 0)
        XCTAssertEqual(data.count, 4 + size + 16)
    }

    func testDepthQualityAccountsForInvalidPixelsAndConfidence() {
        let stats = DepthStatistics(observation(), parameters: .init())
        XCTAssertEqual(stats.nonFinite, 2)
        XCTAssertEqual(stats.nonPositive, 1)
        XCTAssertEqual(stats.acceptedHighConfidence, 1)
        XCTAssertEqual(stats.minimum, 1)
        XCTAssertEqual(stats.low, 1)
        XCTAssertEqual(stats.medium, 1)
        XCTAssertEqual(stats.high, 1)
        XCTAssertEqual(stats.unrecognizedConfidence, 1)
        var o = observation()
        o.confidence = nil
        XCTAssertFalse(DepthStatistics(o, parameters: .init()).confidenceAvailable)
        XCTAssertEqual(DepthStatistics(o, parameters: .init()).acceptedHighConfidence, 0)
    }

    func testNonFiniteTelemetryIsExplicitValidJSON() throws {
        struct Values: Encodable { let a = Float.nan, b = Double.infinity }
        let data = try DiagnosticJSON.encode(Values())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(object["a"], "nan")
        XCTAssertEqual(object["b"], "+inf")
    }

    func testAnalysisExplainsMissingEvidenceWithoutChangingSafetyDecision() {
        let o = observation()
        let analyzer = SpatialAnalyzer()
        let result = analyzer.analyze(
            o,
            priors: [],
            parameters: .init(),
            parameterVersion: 0,
            directionStable: false,
            source: "synthetic"
        )
        XCTAssertEqual(result.diagnostics?.modelBlockReasons, ["ground_fit_failed"])
        XCTAssertEqual(result.diagnostics?.sampledPoints, 1)
        XCTAssertNil(result.surfaceModel)
        XCTAssertTrue(result.segments.isEmpty)
    }
}
