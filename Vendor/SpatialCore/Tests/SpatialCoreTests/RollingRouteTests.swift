import XCTest
import simd

@testable import SpatialCore

/// Synthetic policy regressions. Real recording comparisons live in the offline replay report.
extension ForwardRouteTests {
    func testSeparateFarWallDoesNotEnlargeNearBox() throws {
        let r = frame(cells: { p in
            if abs(p.x) < 0.1 && -p.z > 0.8 && -p.z < 1 { return .obstacle }
            if -p.z > 2.5 && -p.z < 2.7 { return .obstacle }
            return .candidate
        })
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let update = planner.update(result: r, observation: nil, options: .init())
        XCTAssertEqual(update.strategy?.mode, .detour)
        XCTAssertEqual(update.strategy?.obstacleWidth ?? 9, 0.2, accuracy: 0.001)
        let path = try XCTUnwrap(update.path)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
        XCTAssertTrue(path.points.allSatisfy { -$0.z < 2.3 })
    }

    func testPlanningDoesNotDependOnDisplayTriangles() throws {
        var r = frame()
        r.surfaceModel = nil
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let update = planner.update(result: r, observation: nil, options: .init())
        XCTAssertGreaterThan(try XCTUnwrap(update.path).length, 3)
    }

    func testRawGroundSupportExtendsButNeverFillsUnobservedStripe() throws {
        var r = frame()
        r.surfaceModel = nil
        for i in r.grid!.cells.indices {
            let center = r.grid!.center(i)
            r.grid!.cells[i].state = .unknown
            r.grid!.cells[i].groundSamples = center.y > 0.2 && (center.y < 2 || center.y > 2.3) ? 8 : 0
            r.grid!.cells[i].observedAt = r.timestamp
        }
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let path = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
        XCTAssertLessThan(-path.points.last!.z, 1.8)
        XCTAssertTrue(r.grid!.cells.allSatisfy { $0.state == .unknown })  // no verified-clearance promotion
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
    }

    func testStaleGroundSamplesCannotAuthorizeNewCells() {
        var r = frame()
        r.surfaceModel = nil
        for i in r.grid!.cells.indices {
            r.grid!.cells[i].state = .unknown
            r.grid!.cells[i].groundSamples = 20
            r.grid!.cells[i].observedAt = r.timestamp - 1
        }
        XCTAssertEqual(RoutePlanningGrid(result: r)!.blueCells, 0)
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        XCTAssertNil(planner.update(result: r, observation: nil, options: .init()).path)
    }

    func testRollingHorizonKeepsLengthWhileWalkingAndPreservesGoalIdentity() throws {
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let first = planner.update(result: frame(), observation: nil, options: .init())
        let original = try XCTUnwrap(first.path)
        for i in 1...30 {
            let r = frame(
                UInt64(i + 1), 1 + Double(i) * 0.1,
                pose: .init(position: V3(0, 1.4, -Float(i) * 0.1)))
            let update = planner.update(result: r, observation: nil, options: .init())
            let path = try XCTUnwrap(update.path)
            XCTAssertEqual(update.goal?.id, first.goal?.id)
            XCTAssertGreaterThan(path.length, 3)
            XCTAssertLessThan(path.points.last!.z, original.points.last!.z)
            XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
        }
    }

    func testTiltAtDistantOriginDoesNotResetLocallyConsistentReference() throws {
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let first = planner.update(result: frame(), observation: nil, options: .init())
        let plane = GroundPlane(normal: simd_normalize(V3(0, 1, 0.02)), offset: 0.19996, floorPriorConfirmed: true)
        var r = frame(2, 2, pose: .init(position: V3(0, 1.4, -10)))
        r.plane = plane
        r.grid!.basis = GroundBasis(plane: plane, pose: r.sourcePose!)!
        r.diagnostics?.groundConfirmed = true
        let update = planner.update(result: r, observation: nil, options: .init())
        XCTAssertNotEqual(update.reason, "ground_or_metric_conflict")
        XCTAssertEqual(update.goal?.id, first.goal?.id)
        let path = try XCTUnwrap(update.path)
        XCTAssertTrue(path.points.allSatisfy { abs(plane.height($0)) < 0.0001 })
    }

    func testActualLocalFloorJumpStillWithdrawsReference() {
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        _ = planner.update(result: frame(), observation: nil, options: .init())
        var r = frame(2, 1.1)
        r.plane = .init(normal: V3(0, 1, 0), offset: -0.3, floorPriorConfirmed: true)
        r.diagnostics?.groundConfirmed = true
        let update = planner.update(result: r, observation: nil, options: .init())
        XCTAssertNil(update.path)
        XCTAssertEqual(update.reason, "ground_or_metric_conflict")
    }

    func testBlockedCentralEntryCanUseObservedLateralEntry() throws {
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: { p in
            if abs(p.x) < 0.15 && -p.z > 0.6 && -p.z < 1.7 { return .obstacle }
            return -p.z > 1 ? .candidate : .unknown
        })
        let update = planner.update(result: r, observation: nil, options: .init())
        let path = try XCTUnwrap(update.path)
        XCTAssertNotNil(update.strategy?.maneuverID)
        XCTAssertGreaterThan(abs(path.points.first!.x), 0.3)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
        XCTAssertFalse(PathObstacleCheck.intersects(path, result: r, observation: nil))
    }

    func testCameraBlindZoneDoesNotPreventIntentionalTurnAfterThreeSeconds() throws {
        var planner = PathPredictor(obstacleConfirmationSeconds: 0)
        _ = planner.update(result: frame(), observation: nil, options: .init())
        var update = PathUpdate()
        for i in 1...34 {
            let p = pose(yaw: 65)
            let r = frame(
                UInt64(i + 1), 1 + Double(i) * 0.1, pose: p,
                cells: { world in
                    let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0)
                    let q = GroundBasis(plane: plane, pose: p)!.local(world)
                    return q.z > 1.5 ? .candidate : .unknown
                })
            update = planner.update(result: r, observation: nil, options: .init())
        }
        XCTAssertEqual(update.strategy?.reference?.forward.x ?? 0, -sin(65 * .pi / 180), accuracy: 0.001)
        XCTAssertNotNil(update.path)
    }
}
