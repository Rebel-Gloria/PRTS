import XCTest
import simd

@testable import SpatialCore

final class GroundFeedbackEvidenceTests: XCTestCase {
    private func wall(
        _ depth: Float = 0.25,
        width: Int = 12,
        height: Int = 9
    ) -> DepthObservation {
        DepthObservation(
            width: width,
            height: height,
            depth: Array(repeating: depth, count: width * height),
            confidence: Array(repeating: 2, count: width * height),
            intrinsics: .init(
                fx: Float(width) / 2,
                fy: Float(height) / 2,
                cx: Float(width - 1) / 2,
                cy: Float(height - 1) / 2,
                width: width,
                height: height
            ),
            pose: .init(position: V3(0, 1.3, 0)),
            timestamp: 1,
            frameID: 1,
            epoch: 1
        )
    }

    private func analyze(
        _ o: DepthObservation,
        _ analyzer: SpatialAnalyzer = SpatialAnalyzer(),
        parameters: ProbeParameters = .init(),
        priors: [FloorPrior] = []
    ) -> AnalysisResult {
        analyzer.analyze(
            o,
            priors: priors,
            parameters: parameters,
            parameterVersion: 1,
            directionStable: true
        )
    }

    func testStrictOpticalDepthAndAnyReliableFarPixelVetoes() {
        XCTAssertEqual(
            analyze(wall(Float(0.4).nextDown)).groundFeedbackEvidence,
            .fullFieldObstacle
        )
        for far: Float in [0.4, Float(0.4).nextUp, 5, 6] {
            var frame = wall(width: 13, height: 10)
            frame.depth[frame.depth.count - 1] = far
            XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped, "far=\(far)")
        }
        var p = ProbeParameters()
        p.minDepth = 0.2
        p.maxDepth = 0.3
        for near in [p.minDepth, p.maxDepth] {
            XCTAssertEqual(
                analyze(wall(near), parameters: p).groundFeedbackEvidence,
                .fullFieldObstacle
            )
        }
        var frame = wall()
        frame.depth[0] = p.maxDepth.nextUp
        XCTAssertEqual(analyze(frame, parameters: p).groundFeedbackEvidence, .unmapped)
        XCTAssertNil(analyze(wall(p.minDepth.nextDown), parameters: p).groundFeedbackEvidence)
    }

    func testEveryTileUsesAllPixelsAndStrictlyMoreThanTwoThirds() {
        var frame = wall()
        // Each tile has 9 pixels. Six are not enough even if every other tile is perfect.
        for (u, v) in [(0, 0), (1, 0), (2, 0)] { frame.confidence?[v * frame.width + u] = 1 }
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped)
        frame.confidence?[2] = 2
        frame.depth[0] = 10  // Low/medium confidence far is unknown, not a sensor veto.
        frame.depth[1] = .nan
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .fullFieldObstacle)
        for y in 6..<9 {
            for x in 9..<12 { frame.confidence?[y * frame.width + x] = 0 }
        }
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped)
        XCTAssertEqual(analyze(wall(width: 3)).groundFeedbackEvidence, .unmapped)
    }

    func testCutoffAtMaximumRangeDistinguishesFarEvidenceFromMissingDepth() {
        let cutoff: Float = 0.40
        var p = ProbeParameters()
        p.maxDepth = cutoff
        var frame = wall(cutoff.nextUp)
        let last = frame.depth.count - 1
        let missing = analyze(frame, parameters: p)
        XCTAssertEqual(missing.diagnostics?.depth?.acceptedHighConfidence, 0)
        XCTAssertEqual(missing.validDepthCoverage, 0)
        XCTAssertNil(missing.groundFeedbackEvidence)

        frame.depth[last] = cutoff
        let oneAtMaximum = analyze(frame, parameters: p)
        XCTAssertEqual(oneAtMaximum.diagnostics?.depth?.acceptedHighConfidence, 1)
        XCTAssertEqual(oneAtMaximum.groundFeedbackEvidence, .unmapped)
        p.maxDepth = cutoff.nextDown
        XCTAssertNil(analyze(frame, parameters: p).groundFeedbackEvidence)

        frame = wall(p.maxDepth)
        XCTAssertEqual(analyze(frame, parameters: p).groundFeedbackEvidence, .fullFieldObstacle)
        frame.depth[last] = cutoff
        let vetoed = analyze(frame, parameters: p)
        XCTAssertEqual(vetoed.diagnostics?.depth?.acceptedHighConfidence, last)
        XCTAssertEqual(vetoed.groundFeedbackEvidence, .unmapped)
    }

    func testNoReliableSampleIsNilButAnOffStrideMeasurementIsUnmapped() {
        var frame = wall()
        for conf: UInt8? in [nil, 0, 1, 3] {
            frame.confidence = conf.map { Array(repeating: $0, count: frame.depth.count) }
            XCTAssertNil(analyze(frame).groundFeedbackEvidence)
        }
        for z: Float in [.nan, .infinity, 0, 0.1, 6] {
            XCTAssertNil(analyze(wall(z)).groundFeedbackEvidence)
        }
        frame.confidence?[frame.width + 1] = 2
        let result = analyze(frame)
        XCTAssertEqual(result.diagnostics?.sampledPoints, 0)
        XCTAssertEqual(result.groundFeedbackEvidence, .unmapped)
        XCTAssertNil(result.grid)
    }

    func testHorizonUsesBothSensorAxesAndActualIntrinsics() {
        var frame = wall()
        frame.intrinsics.fy = 20
        func pose(_ pitch: Float, roll: Float = 0) -> RigidPose {
            let a = pitch * .pi / 180
            let b = roll * .pi / 180
            let right = V3(1, 0, 0)
            let up = V3(0, cos(a), -sin(a))
            return .init(
                right: cos(b) * right + sin(b) * up,
                up: cos(b) * up - sin(b) * right,
                back: V3(0, sin(a), cos(a))
            )
        }
        for pitch: Float in [-85, -25, 25, 85] {
            frame.pose = pose(pitch)
            XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped)
            frame.pose = pose(pitch, roll: 90)
            XCTAssertEqual(
                analyze(frame).groundFeedbackEvidence,
                abs(pitch) == 25 ? .fullFieldObstacle : .unmapped
            )
        }
        // Only the corner rays span the horizon at this roll, not the center row or column.
        frame.pose = pose(36, roll: 45)
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .fullFieldObstacle)
        frame.pose = .init()
        frame.intrinsics.cy = 0  // Touches the first row, does not cross the measured field.
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped)
        frame.intrinsics.cy = -2
        XCTAssertEqual(analyze(frame).groundFeedbackEvidence, .unmapped)
    }

    private var floorPrior: FloorPrior { .init(center: V3(0, 0, -3), normal: V3(0, 1, 0)) }

    private func floorFrame(_ id: Int) -> DepthObservation {
        var frame = wall(width: 160, height: 120)
        for y in 0..<frame.height {
            let ray = frame.intrinsics.unproject(u: 0, v: Float(y), depth: 1)
            let z = ray.y < 0 ? min(5, -frame.pose.position.y / ray.y) : 5
            for x in 0..<frame.width { frame.depth[y * frame.width + x] = z }
        }
        frame.frameID = UInt64(id)
        frame.timestamp = 1 + Double(id) * 0.1
        return frame
    }

    func testUnpolledNativeFullFieldVetoWithdrawsThePublishedDetourAcrossMissingDepth() throws {
        let analyzer = SpatialAnalyzer()
        var predictor = PathPredictor(policy: .obstacleVeto)
        var published = PathUpdate()
        var serialPublication = PathUpdate()
        var watermark: UInt64 = 0
        var gate = ResultPresentationGate()
        gate.enabled = true
        gate.trackingNormal = true
        gate.epoch = 1
        gate.parameterVersion = 1

        func decide(_ current: PathUpdate, _ candidate: PathUpdate, _ hazard: UInt64)
            -> RoutePublicationDecision
        {
            RoutePublicationPolicy.decide(
                current: current,
                candidate: candidate,
                gate: gate,
                hazardWatermark: hazard,
                now: gate.frameTimestamp,
                expectedPolicy: .obstacleVeto
            )
        }
        @discardableResult
        func publish(_ frame: DepthObservation) -> GroundFeedbackEvidence? {
            let result = analyze(frame, analyzer, priors: [floorPrior])
            gate.frameID = frame.frameID
            gate.frameTimestamp = frame.timestamp
            let candidate = predictor.update(
                result: result,
                observation: frame,
                options: .init(),
                hazardWatermark: watermark,
                committedPath: published.path,
                onOccupancyConflict: {
                    watermark = $0
                    published = .init(reason: "confirmed_occupancy_conflict")
                }
            )
            published = decide(published, candidate, watermark).update
            // Serial consumers can publish the result without subscribing to fast preemption.
            serialPublication = decide(serialPublication, candidate, 0).update
            return result.groundFeedbackEvidence
        }
        func floorWithPost(_ id: Int) -> DepthObservation {
            var frame = floorFrame(id)
            for y in 0..<frame.height {
                for x in 74..<86 { frame.depth[y * frame.width + x] = 0.9 }
            }
            return frame
        }

        for id in 1...7 { publish(floorWithPost(id)) }
        let old = published
        let oldGoal = try XCTUnwrap(old.goal)
        XCTAssertNotNil(old.path)
        XCTAssertEqual(serialPublication.goal?.id, oldGoal.id)
        let oldWatermark = watermark
        var near = wall()
        near.frameID = 8
        near.timestamp = 1.8
        near.depth[0] = 0.4
        XCTAssertEqual(publish(near), .unmapped)
        XCTAssertEqual(published.goal?.id, oldGoal.id)
        XCTAssertEqual(watermark, oldWatermark)

        near.frameID = 9
        near.timestamp = 1.9
        near.depth[0] = 0.25
        XCTAssertEqual(publish(near), .fullFieldObstacle)
        // No presentation poll between the veto and a frame without a usable native sample.
        near.frameID = 10
        near.timestamp = 2.0
        near.confidence = nil
        XCTAssertNil(publish(near))
        XCTAssertEqual(watermark, 9)
        for (current, hazard) in [(published, watermark), (serialPublication, 0)] {
            XCTAssertNil(current.path)
            XCTAssertNil(current.goal)
            XCTAssertNil(current.waypointGuidance)
            XCTAssertFalse(decide(current, old, hazard).accepted)
            XCTAssertNil(decide(current, old, hazard).update.path)
        }

        // Open floor during the old obstacle latch cannot reinstate the pre-veto detour.
        for id in 11...12 { publish(floorFrame(id)) }
        XCTAssertEqual(publish(floorFrame(13)), .mapped)
        XCTAssertEqual(published.waypointGuidance?.scenario, .clear)
        XCTAssertNil(published.path)
        for id in 14...18 { publish(floorWithPost(id)) }
        XCTAssertNotNil(published.path)
        XCTAssertGreaterThan(try XCTUnwrap(published.goal).id, 9)
        XCTAssertEqual(published.continuity?.hazardWatermark, watermark)
        XCTAssertEqual(serialPublication.goal?.id, published.goal?.id)
    }

    func testNativeGroundConfirmationRetainedReferenceAndMissingFrame() {
        let analyzer = SpatialAnalyzer()
        for id in 1...3 {
            let result = analyze(floorFrame(id), analyzer, priors: [floorPrior])
            XCTAssertNotNil(result.grid)
            XCTAssertEqual(result.diagnostics?.groundConfirmed, id == 3)
            XCTAssertEqual(result.groundFeedbackEvidence, id == 3 ? .mapped : .unmapped)
        }
        var frame = wall()
        frame.frameID = 4
        frame.timestamp = 1.4
        let close = analyze(frame, analyzer)
        XCTAssertEqual(close.diagnostics?.groundReferenceMode, "retained_world_reference")
        XCTAssertNotNil(close.grid)
        XCTAssertEqual(close.groundFeedbackEvidence, .fullFieldObstacle)
        frame.frameID += 1
        frame.timestamp += 0.1
        frame.depth = Array(repeating: Float(5).nextUp, count: frame.depth.count)
        let noLegalPixels = analyze(frame, analyzer)
        XCTAssertEqual(noLegalPixels.diagnostics?.groundReferenceMode, "retained_world_reference")
        XCTAssertEqual(noLegalPixels.diagnostics?.depth?.high, frame.depth.count)
        XCTAssertEqual(noLegalPixels.diagnostics?.depth?.acceptedHighConfidence, 0)
        XCTAssertEqual(noLegalPixels.validDepthCoverage, 0)
        XCTAssertNil(noLegalPixels.groundFeedbackEvidence)
        frame.frameID += 1
        frame.timestamp += 0.1
        frame.confidence = nil
        XCTAssertNil(analyze(frame, analyzer).groundFeedbackEvidence)
    }

    func testPredictionCannotSupplyOrPrimeNativeGroundEvidence() {
        let analyzer = SpatialAnalyzer()
        for id in 1...3 {
            var frame = floorFrame(id)
            frame.predictionSupport = Array(repeating: 1, count: frame.depth.count)
            if id == 1 { frame.confidence = nil }
            XCTAssertNil(analyze(frame, analyzer, priors: [floorPrior]).groundFeedbackEvidence)
        }
        let firstNative = analyze(floorFrame(4), analyzer, priors: [floorPrior])
        XCTAssertEqual(firstNative.diagnostics?.groundConfirmed, false)
        XCTAssertEqual(firstNative.groundFeedbackEvidence, .unmapped)
        var close = wall()
        close.predictionSupport = Array(repeating: 1, count: close.depth.count)
        XCTAssertNil(analyze(close).groundFeedbackEvidence)
    }

    func testConfirmedGroundWithoutUsableDirectionalGridIsUnmapped() {
        let analyzer = SpatialAnalyzer()
        let prior = FloorPrior(center: .zero, normal: V3(0, 1, 0))
        var frame = wall(1.3, width: 64, height: 48)
        frame.pose = .init(
            right: V3(1, 0, 0),
            up: V3(0, 0, -1),
            back: V3(0, 1, 0),
            position: V3(0, 1.3, 0)
        )
        for id in 1...3 {
            frame.frameID = UInt64(id)
            frame.timestamp = 1 + Double(id) * 0.1
            let result = analyze(frame, analyzer, priors: [prior])
            XCTAssertEqual(result.diagnostics?.groundConfirmed, id == 3)
            XCTAssertNotNil(result.grid)
            XCTAssertEqual(result.groundFeedbackEvidence, .unmapped)
        }
    }

    func testConfirmedFloorOutsideTheGridIsNotMapped() {
        let analyzer = SpatialAnalyzer()
        let prior = FloorPrior(center: V3(0, 0, -4.4), normal: V3(0, 1, 0))
        var frame = wall(width: 160, height: 120)
        frame.intrinsics.fy = 200
        frame.intrinsics.cy = 5
        for y in 0..<frame.height {
            let ray = frame.intrinsics.unproject(u: 0, v: Float(y), depth: 1)
            let z = -frame.pose.position.y / ray.y
            for x in 0..<frame.width {
                frame.depth[y * frame.width + x] = (4.2...4.7).contains(z) ? z : 0
            }
        }
        for id in 1...3 {
            frame.frameID = UInt64(id)
            frame.timestamp = 1 + Double(id) * 0.1
            let result = analyze(frame, analyzer, priors: [prior])
            XCTAssertEqual(result.diagnostics?.groundConfirmed, id == 3)
            XCTAssertEqual(result.grid?.cells.contains { $0.groundSamples > 0 }, false)
            XCTAssertEqual(result.groundFeedbackEvidence, .unmapped)
        }
    }

    func testFullFieldWithConfirmedFloorDependsOnActualForwardGridSamples() {
        // The same wide lens sees the horizon in both poses. At 45° the visible floor
        // falls behind the camera's ground projection, outside the forward grid.
        for tilted in [false, true] {
            let analyzer = SpatialAnalyzer()
            var frame = wall(width: 96, height: 72)
            frame.intrinsics.fx = 20
            frame.intrinsics.fy = 20
            let pitch: Float = tilted ? .pi / 4 : 0
            frame.pose = .init(
                up: V3(0, cos(pitch), -sin(pitch)),
                back: V3(0, sin(pitch), cos(pitch)),
                position: V3(0, 0.60, 0)
            )
            let prior = FloorPrior(center: V3(0, 0, tilted ? 0.12 : -0.35), normal: V3(0, 1, 0))
            for y in 0..<frame.height {
                let ray = frame.intrinsics.unproject(u: 0, v: Float(y), depth: 1)
                let vertical = frame.pose.up.y * ray.y + frame.pose.back.y * ray.z
                guard vertical < 0 else { continue }
                let z = -frame.pose.position.y / vertical
                guard z < 0.40 else { continue }
                for x in 0..<frame.width { frame.depth[y * frame.width + x] = z }
            }
            XCTAssertTrue(frame.hasFullFieldObstacle(parameters: .init()))
            for id in 1...3 {
                frame.frameID = UInt64(id)
                frame.timestamp = 1 + Double(id) * 0.1
                let result = analyze(frame, analyzer, priors: [prior])
                XCTAssertEqual(result.diagnostics?.groundConfirmed, id == 3)
                XCTAssertEqual(result.grid?.cells.contains { $0.groundSamples > 0 }, !tilted)
                XCTAssertEqual(
                    result.groundFeedbackEvidence,
                    !tilted && id == 3 ? .mapped : .fullFieldObstacle,
                    "tilted=\(tilted), frame=\(id)"
                )
            }
        }
    }

    func testPixelsWithoutPositiveRangeAreNeverFeedbackEvidence() {
        var p = ProbeParameters()
        p.minDepth = 0
        XCTAssertNil(analyze(wall(0), parameters: p).groundFeedbackEvidence)
        var frame = wall()
        // Six of nine pixels in the last tile are near; zeros cannot tip the vote.
        for x in 9..<12 { frame.depth[8 * frame.width + x] = 0 }
        XCTAssertEqual(analyze(frame, parameters: p).groundFeedbackEvidence, .unmapped)
    }

    func testEvidenceRoundTripsAndOlderRecordsDoNotInferItFromDiagnostics() throws {
        let observed = analyze(wall())
        let data = try JSONEncoder().encode(observed)
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(
            fields.removeValue(forKey: "groundFeedbackEvidence") as? String,
            "fullFieldObstacle"
        )
        let current = try JSONDecoder().decode(AnalysisResult.self, from: data)
        XCTAssertEqual(current.groundFeedbackEvidence, .fullFieldObstacle)
        let legacy = try JSONDecoder().decode(
            AnalysisResult.self,
            from: JSONSerialization.data(withJSONObject: fields)
        )
        XCTAssertGreaterThan(try XCTUnwrap(legacy.diagnostics?.depth?.acceptedHighConfidence), 0)
        XCTAssertNil(legacy.groundFeedbackEvidence)
    }
}
