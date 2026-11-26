import XCTest
import simd

@testable import SpatialCore

final class WaypointSurveyTests: XCTestCase {
    private let scene = RoutingTestScene()
    private let options = PathOptions()

    func testEmptyFramesCannotStartOrRenewGuidance() {
        var predictor = PathPredictor()
        var missing = scene.frame()
        missing.grid = nil
        XCTAssertNil(
            predictor.update(result: missing, observation: nil, options: options).continuity
        )
        let open = scene.frame(2, 1.1)
        XCTAssertEqual(
            predictor.update(result: open, observation: nil, options: options).waypointGuidance?
                .scenario,
            .clear
        )
        let blank = scene.frame(3, 1.2, cells: { _ in .unknown })
        XCTAssertNil(predictor.update(result: blank, observation: nil, options: options).continuity)
    }

    func testUnobservedIntervalDoesNotConfirmFleetingObstacle() {
        var predictor = PathPredictor()
        _ = predictor.update(
            result: scene.frame(cells: scene.box),
            observation: nil,
            options: options
        )
        _ = predictor.update(
            result: scene.frame(2, 1.2, cells: { _ in .unknown }),
            observation: nil,
            options: options
        )
        let latest = predictor.update(
            result: scene.frame(3, 1.4, cells: scene.box),
            observation: nil,
            options: options
        )
        XCTAssertEqual(latest.occupancyFilter?.confirmedCells, 0)
        XCTAssertNotEqual(latest.waypointGuidance?.scenario, .nearObstacle)
    }

    func testIntermittentMeasurementsConfirmPersistentObstacleWithoutCountingMissingTime() {
        var predictor = PathPredictor()
        for i in 0..<20 {
            var frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10, cells: scene.box)
            if i % 4 == 3 { frame.grid = nil }
            let update = predictor.update(result: frame, observation: nil, options: options)
            if frame.grid == nil {
                XCTAssertNil(update.continuity)
            } else if i == 4 {
                XCTAssertEqual(update.occupancyFilter?.confirmedCells, 0)
                XCTAssertNotEqual(update.waypointGuidance?.scenario, .clear)
            } else if i >= 5 {
                XCTAssertGreaterThan(update.occupancyFilter?.confirmedCells ?? 0, 0)
                XCTAssertEqual(update.waypointGuidance?.scenario, .nearObstacle)
            }
        }
    }

    func testInterruptedSideNoiseAndMeasuredNegativeLeaveForwardGroundClear() {
        for lateral: Float in [0, 1.3] {
            var predictor = PathPredictor()
            for i in 0...6 {
                var frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10) { point in
                    i == 6 ? .candidate : self.scene.box(point - V3(lateral, 0, 0))
                }
                if i == 2 || i == 4 { frame.grid = nil }
                let result = predictor.update(result: frame, observation: nil, options: options)
                if frame.grid != nil && (lateral != 0 || i == 6) {
                    XCTAssertEqual(result.waypointGuidance?.scenario, .clear)
                }
                if lateral == 0 && (i == 3 || i == 5) {
                    XCTAssertNil(result.waypointGuidance)
                }
            }
        }
    }

    func testShortGapPreservesWallButMeasuredEmptyAndLongGapDoNot() {
        let wall: (V3) -> CellState = { (0.21...0.59).contains(-$0.z) ? .obstacle : .candidate }
        for interruption in ["missing", "empty", "long"] {
            var predictor = PathPredictor()
            for i in 0...3 {
                let frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10, cells: wall)
                let update = predictor.update(result: frame, observation: nil, options: options)
                if i == 3 { XCTAssertEqual(update.waypointGuidance?.scenario, .blocked) }
            }
            var gap = scene.frame(5, 1.4)
            if interruption != "empty" { gap.grid = nil }
            _ = predictor.update(result: gap, observation: nil, options: options)
            let frame = scene.frame(6, interruption == "long" ? 2.3 : 1.5, cells: wall)
            let update = predictor.update(result: frame, observation: nil, options: options)
            if interruption == "missing" {
                XCTAssertGreaterThan(update.occupancyFilter?.confirmedCells ?? 0, 0)
                XCTAssertEqual(update.waypointGuidance?.scenario, .blocked)
                XCTAssertNil(update.path)
            } else {
                XCTAssertEqual(update.occupancyFilter?.confirmedCells, 0)
            }
        }
    }

    func testMeasuredOpenFloorDoesNotRenewOldObstacleOrInventAnEscapeFromAWall() throws {
        for wall in [false, true] {
            for gap in [0.2, 1.6, 6.0] {
                var predictor = PathPredictor()
                var last = PathUpdate()
                let cells: (V3) -> CellState = { p in
                    wall
                        ? ((0.21...0.59).contains(-p.z) ? .obstacle : .candidate)
                        : self.scene.box(p)
                }
                for i in 0...10 {
                    let frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10, cells: cells)
                    last = predictor.update(result: frame, observation: nil, options: options)
                }
                XCTAssertEqual(last.waypointGuidance?.scenario, wall ? .blocked : .nearObstacle)
                var missing = scene.frame(12, 2.1)
                missing.grid = nil
                _ = predictor.update(result: missing, observation: nil, options: options)
                let open = scene.frame(13, 2 + gap)
                let recovered = predictor.update(result: open, observation: nil, options: options)
                XCTAssertEqual(recovered.occupancyFilter?.confirmedCells, 0)
                if let state = recovered.waypointGuidance?.scenario, state != .clear {
                    XCTAssertEqual(try XCTUnwrap(recovered.continuity).timestamp, 2, accuracy: 1e-6)
                    XCTAssertEqual(recovered.waypointGuidance?.retainedObstacleAt, 2)
                    XCTAssertEqual(recovered.goal?.id, last.goal?.id)
                    if let path = recovered.path {
                        XCTAssertEqual(path.observedAt, 2, accuracy: 1e-6)
                        XCTAssertFalse(wall)
                    }
                }
                for i in 1...7 {
                    let frame = scene.frame(UInt64(13 + i), open.timestamp + Double(i) / 10)
                    last = predictor.update(result: frame, observation: nil, options: options)
                }
                XCTAssertEqual(last.waypointGuidance?.scenario, .clear)
            }
        }
    }

    func testArrivingAtAHistoricalGoalDoesNotKeepOrPromoteItsSegment() throws {
        var predictor = PathPredictor()
        var current = PathUpdate()
        for i in 0...4 {
            let frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10, cells: scene.box)
            current = predictor.update(result: frame, observation: nil, options: options)
        }
        let goal = try XCTUnwrap(current.goal)
        XCTAssertNotNil(current.waypointGuidance?.nextTarget)
        let arrived = scene.pose(yaw: 0, position: goal.point + V3(0, 1.4, 0))
        for i in 5...7 {
            let frame = scene.frame(UInt64(i + 1), 1 + Double(i) / 10, pose: arrived)
            let candidate = predictor.update(result: frame, observation: nil, options: options)
            var gate = ResultPresentationGate()
            gate.enabled = true
            gate.trackingNormal = true
            gate.epoch = frame.epoch
            gate.frameID = frame.frameID
            gate.frameTimestamp = frame.timestamp
            current =
                RoutePublicationPolicy.decide(
                    current: current,
                    candidate: candidate,
                    gate: gate,
                    hazardWatermark: 0,
                    now: frame.timestamp,
                    expectedPolicy: .obstacleVeto
                ).update
            XCTAssertNil(current.path)
            XCTAssertNil(current.goal)
            XCTAssertNil(current.waypointGuidance?.nextTarget)
            XCTAssertNotEqual(current.waypointGuidance?.scenario, .blocked)
        }
    }

    func testObstacleOffToTheSideDoesNotProveThatAheadIsClear() {
        var predictor = PathPredictor()
        for i in 0...5 {
            let frame = scene.frame(
                UInt64(i + 1),
                1 + Double(i) / 10,
                cells: {
                    $0.x > 1 && -$0.z < 2 ? .obstacle : .unknown
                }
            )
            let output = predictor.update(result: frame, observation: nil, options: options)
            XCTAssertNotEqual(output.waypointGuidance?.scenario, .clear)
        }
    }

    func testRetainOnlyMeasuredStepWithinTimeEvenWhenPoseKeepsUpdating() throws {
        let raw = scene.frame(cells: { abs($0.x) < 0.7 && -$0.z < 2.1 ? .candidate : .unknown })
        var survey = WaypointSurvey()
        survey.record(try XCTUnwrap(raw.grid), pose: try XCTUnwrap(raw.sourcePose), retention: 2)
        let inside = scene.pose(yaw: 0, position: V3(0, 1.4, -0.5))
        XCTAssertTrue(survey.coversStep(from: inside, target: nil, options: options, now: 3))
        XCTAssertFalse(survey.coversStep(from: inside, target: nil, options: options, now: 3.01))
        let edge = scene.pose(yaw: 0, position: V3(0, 1.4, -1.8))
        XCTAssertFalse(survey.coversStep(from: edge, target: nil, options: options, now: 1.2))
        XCTAssertFalse(survey.leftMappedArea(pose: edge, options: options))
        for yaw: Float in [90, 180] {
            let turned = scene.pose(yaw: yaw, position: edge.position)
            XCTAssertFalse(survey.leftMappedArea(pose: turned, options: options))
        }
        let outside = scene.pose(yaw: 180, position: V3(0, 1.4, -2.5))
        XCTAssertTrue(survey.leftMappedArea(pose: outside, options: options))
        XCTAssertFalse(survey.leftMappedArea(pose: scene.pose(yaw: 180), options: options))
    }

    func testNewFloorCannotAuthorizeAnOldDetourButOriginalCoverageCan() throws {
        var survey = WaypointSurvey()
        let pose = scene.pose(yaw: 0, position: V3(0, 1.4, -0.5))
        let target = V3(0, 0, -1.6)
        let original = scene.frame(cells: { abs($0.x) < 0.7 ? .candidate : .unknown })
        survey.record(
            try XCTUnwrap(original.grid),
            pose: try XCTUnwrap(original.sourcePose),
            retention: 2
        )
        let new = scene.frame(2, 1.4)
        survey.record(try XCTUnwrap(new.grid), pose: try XCTUnwrap(new.sourcePose), retention: 2)
        XCTAssertEqual(
            survey.measuredAt(
                from: pose,
                target: target,
                options: options,
                now: 1.4,
                noLaterThan: 1
            ),
            1
        )
        let other = scene.pose(yaw: 0, position: V3(1, 1.4, -0.5))
        XCTAssertTrue(survey.coversStep(from: other, target: nil, options: options, now: 1.4))
        XCTAssertNil(
            survey.measuredAt(from: other, target: nil, options: options, now: 1.4, noLaterThan: 1)
        )
    }

    func testUnknownHoleAndDifferentViewCannotRenewOldCoverage() throws {
        var survey = WaypointSurvey()
        let raw = scene.frame(cells: { (-$0.z > 0.9 && -$0.z < 1.2) ? .unknown : .candidate })
        survey.record(try XCTUnwrap(raw.grid), pose: try XCTUnwrap(raw.sourcePose), retention: 2)
        XCTAssertFalse(
            survey.coversStep(
                from: scene.pose(yaw: 0, position: V3(0, 1.4, -0.6)),
                target: nil,
                options: options,
                now: 1.2
            )
        )
        let other = scene.frame(2, 2.5, pose: scene.pose(yaw: 180))
        survey.record(
            try XCTUnwrap(other.grid),
            pose: try XCTUnwrap(other.sourcePose),
            retention: 2
        )
        XCTAssertFalse(
            survey.coversStep(
                from: scene.pose(yaw: 0, position: V3(0, 1.4, -1.5)),
                target: nil,
                options: options,
                now: 3.1
            )
        )
    }
}
