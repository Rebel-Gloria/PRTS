import XCTest

@testable import SpatialCore

final class MonocularReferenceTests: XCTestCase {
    private func boundaryReferences(otherRow: Float) -> MonocularReferencePixels {
        let k = CameraIntrinsics(fx: 160, fy: 160, cx: 127.5, cy: 95.5, width: 256, height: 192)
        let edge = Float(119.5).nextDown
        XCTAssertEqual(edge.rounded(), 119)
        XCTAssertEqual(edge / Float(k.height) * Float(k.height), 119.5)
        var relative = [Float](repeating: .nan, count: k.width * k.height)
        relative[119 * k.width + 72] = 0.75
        relative[120 * k.width + 72] = 0.875
        var references = MonocularReferencePixels()
        for (i, p) in [SIMD2<Float>(72.32, edge), SIMD2<Float>(71.68, otherRow)].enumerated() {
            let pixel = Int(p.y.rounded()) * k.width + Int(p.x.rounded())
            references.append(
                pixelIndex: pixel,
                relativeMap: relative,
                meters: 2.55,
                u: p.x / Float(k.width),
                v: p.y / Float(k.height),
                source: "feature",
                featureID: UInt64(i)
            )
        }
        return references
    }

    func testDistinctSampledRowsDoNotMergeAtNormalizedRayBoundary() {
        let references = boundaryReferences(otherRow: 120)
        XCTAssertEqual(references.pixelIndices, [119 * 256 + 72, 120 * 256 + 72])
        let votes = references.independentSamples()
        XCTAssertEqual(votes.map(\.relative), [0.75, 0.875])
        XCTAssertEqual(votes.compactMap(\.featureID), [0, 1])
    }

    func testSameSampledRowDoesNotSplitAtNormalizedRayBoundary() {
        let references = boundaryReferences(otherRow: 119)
        XCTAssertEqual(references.pixelIndices, [119 * 256 + 72, 119 * 256 + 72])
        XCTAssertTrue(references.independentSamples().isEmpty)
        // Rejected fit votes still have their original rays and IDs for drift checks.
        XCTAssertEqual(references.samples.map(\.u), [72.32 / 256, 71.68 / 256])
        XCTAssertEqual(references.samples.map(\.v), [Float(119.5).nextDown / 192, 119.0 / 192])
        XCTAssertEqual(references.samples.compactMap(\.featureID), [0, 1])
    }

    // The camera sees one surface per model pixel. Half the rays also cross a hidden map layer;
    // repeated landmarks behind that surface cannot provide extra independent observations.
    func testHiddenLandmarksCannotVoteOneSurfaceFartherAway() throws {
        let k = CameraIntrinsics(fx: 50, fy: 50, cx: 31.5, cy: 23.5, width: 64, height: 48)
        var relative = [Float](repeating: .nan, count: k.width * k.height)
        var references = MonocularReferencePixels()
        for i in 0..<64 {
            let x = 4 + (i % 8) * 8
            let y = 3 + (i / 8) * 6
            let z = 1 + Float((i * 19) % 64) / 30
            let q = 0.1 + 0.72 / z
            relative[y * k.width + x] = q
            let factors: [Float] = i.isMultiple(of: 2) ? [1.65, 1.68, 1.72, 1.75, 1] : [1]
            for (j, factor) in factors.enumerated() {
                references.append(
                    pixelIndex: y * k.width + x,
                    relativeMap: relative,
                    meters: z * factor,
                    u: Float(x) / Float(k.width),
                    v: Float(y) / Float(k.height),
                    source: "arkit_sparse_feature",
                    featureID: UInt64(i * 8 + j)
                )
            }
        }
        let fit = InverseDepthCalibration.fit(references.independentSamples())
        var tracker = MetricScaleTracker()
        var decision = MetricScaleDecision()
        for step in 0..<3 {
            decision = tracker.update(
                .init(
                    timestamp: 1 + Double(step) / 10,
                    epoch: 0,
                    parameterVersion: 1,
                    orientation: .landscapeRight,
                    intrinsics: k,
                    pose: .init(),
                    relative: relative,
                    samples: references.samples,
                    fit: fit
                )
            )
        }
        let meters = try XCTUnwrap(decision.calibration?.meters(0.1 + 0.72 / 2))
        XCTAssertEqual(meters, 2, accuracy: 0.03)
    }

    func testAmbiguousPixelRejectsBothNearAndFarAndCannotFallBackToFloor() {
        var relative = [Float](repeating: 0.5, count: 100)
        relative[58] = .nan
        let rays: [(x: Float, meters: Float, id: UInt64?)] = [
            (2, 5, nil), (2.01, 2, 1), (1.98, 0.5, 2), (2, 3, nil), (5, 2.2, 3),
            (5, 4, nil), (7, 2.6, nil), (7, 0.05, 4), (8, 1, 5), (9, 1.2, nil), (9, 1.2, nil),
        ]
        for order in [rays, Array(rays.reversed())] {
            var references = MonocularReferencePixels()
            for ray in order {
                references.append(
                    pixelIndex: 50 + Int(ray.x.rounded()),
                    relativeMap: relative,
                    meters: ray.meters,
                    u: ray.x / 10,
                    v: 0.5,
                    source: ray.id == nil ? "floor" : "feature",
                    featureID: ray.id
                )
            }
            // Hold out every actual lookup, even with a bad depth or a subsequently rejected vote.
            XCTAssertEqual(references.pixelIndices, order.map { 50 + Int($0.x.rounded()) })
            let chosen = references.independentSamples()
            XCTAssertEqual(chosen.map(\.meters).sorted(), [1.2, 2.2, 2.6])
            XCTAssertEqual(chosen.compactMap(\.featureID), [3])
        }
    }
}
