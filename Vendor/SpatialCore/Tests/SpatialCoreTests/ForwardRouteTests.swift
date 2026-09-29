import XCTest
import simd

@testable import SpatialCore

/// All geometry in this suite is synthetic. It tests policy and coordinate invariants, not
/// LiDAR accuracy, glass detection, gait clearance or unprotected walking performance.
final class ForwardRouteTests: XCTestCase {
    func frame(
        _ id: UInt64 = 1, _ time: Double = 1, pose: RigidPose = .init(position: V3(0, 1.4, 0)),
        cells: (V3) -> CellState = { _ in .candidate }
    ) -> AnalysisResult {
        let p = ProbeParameters()
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0, floorPriorConfirmed: true)
        var grid = LocalGrid(
            basis: GroundBasis(plane: plane, pose: pose)!, parameters: p, timestamp: time, frameID: id, epoch: 1)
        var triangles: [SurfaceTriangle] = []
        for i in grid.cells.indices {
            let c = grid.center(i)
            let world = grid.basis.world(x: c.x, h: 0, z: c.y)
            let state: CellState = c.y < 0.2 ? .unknown : cells(world)
            grid.cells[i].state = state
            grid.cells[i].obstacleSamples = state == .obstacle ? 6 : 0
            if state == .candidate {
                let s = grid.cellSize / 2
                let a = grid.basis.world(x: c.x - s, h: 0, z: c.y - s)
                let b = grid.basis.world(x: c.x + s, h: 0, z: c.y - s)
                let d = grid.basis.world(x: c.x - s, h: 0, z: c.y + s)
                let e = grid.basis.world(x: c.x + s, h: 0, z: c.y + s)
                triangles += [.init(a: a, b: b, c: d, surface: .ground), .init(a: b, b: e, c: d, surface: .ground)]
            }
        }
        var r = AnalysisResult(
            epoch: 1, frameID: id, timestamp: time, parameters: p, status: "synthetic", source: "synthetic")
        r.grid = grid
        r.plane = plane
        r.sourcePose = pose
        r.sourceDirectionStable = true
        r.diagnostics = AnalysisDiagnostics()
        r.diagnostics?.groundReferenceMode = "current_confirmed"
        r.surfaceModel = .init(
            triangles: triangles,
            summary: .init(
                groundTriangles: triangles.count,
                protrusionTriangles: 0, minimumProtrusionHeight: 0.05, maximumObservedProtrusionHeight: nil,
                samplingStep: 2))
        return r
    }
    func box(_ p: V3) -> CellState { abs(p.x) < 0.1 && -p.z > 0.8 && -p.z < 1 ? .obstacle : .candidate }
    func pose(yaw: Float, position: V3 = V3(0, 1.4, 0)) -> RigidPose {
        let a = yaw * Float.pi / 180
        return .init(right: V3(cos(a), 0, -sin(a)), up: V3(0, 1, 0), back: V3(sin(a), 0, cos(a)), position: position)
    }
    func testNonfiniteTurnHeadingResetsDwell() {
        var dwell = ForwardTurnDwell()
        let options = PathOptions()
        _ = dwell.update(forward: V3(1, 0, 0), routeForward: V3(0, 0, -1),
                         clear: true, now: 1, options: options)
        XCTAssertFalse(dwell.update(forward: V3(.nan, 0, 0), routeForward: V3(0, 0, -1),
                                    clear: true, now: 4, options: options))
        XCTAssertNil(dwell.since)
        XCTAssertEqual(dwell.elapsed, 0)
    }
    func testClearAreaChoosesForwardNotFarthestSide() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame()
        let u = tracker.update(result: r, observation: nil, options: .init())
        let path = try XCTUnwrap(u.path)
        XCTAssertTrue(path.points.allSatisfy { abs($0.x) < 0.0001 })
        XCTAssertGreaterThan(path.length, 3)
        XCTAssertEqual(u.strategy?.mode, .straight)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
    }
    func testObservedLaneObstacleStartsPreviewDetourBeforeOneMetre() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: { abs($0.x) < 0.1 && -$0.z > 1.5 && -$0.z < 1.7 ? .obstacle : .candidate })
        let u = tracker.update(result: r, observation: nil, options: .init())
        XCTAssertNotNil(u.strategy?.maneuverID)
        XCTAssertGreaterThan(u.strategy?.triggerDistance ?? 0, 1)
        let path = try XCTUnwrap(u.path)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
        XCTAssertGreaterThan(path.points.map { abs($0.x) }.max() ?? 0, 0.3)
    }
    func testObstacleOutsideTriangleDoesNotTurnClearLine() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: { $0.x > 0.6 && $0.x < 0.9 && -$0.z < 1 ? .obstacle : .candidate })
        let u = tracker.update(result: r, observation: nil, options: .init())
        XCTAssertNil(u.strategy?.maneuverID)
        XCTAssertLessThan(abs(try XCTUnwrap(u.path?.points.last).x), 0.001)
    }
    func testSmallNearBoxDetoursAndReturnsToOriginalAxis() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: box)
        let u = tracker.update(result: r, observation: nil, options: .init())
        let path = try XCTUnwrap(u.path)
        XCTAssertEqual(u.strategy?.mode, .detour)
        XCTAssertEqual(u.strategy?.obstacleWidth ?? 9, 0.2, accuracy: 0.001)
        XCTAssertNotNil(u.strategy?.rejoinPoint)
        XCTAssertGreaterThan(path.points.map { abs($0.x) }.max()!, 0.3)
        XCTAssertLessThan(abs(path.points.last!.x), 0.001)
        XCTAssertLessThan(abs(u.strategy!.rejoinPoint!.x), 0.001)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
    }
    func testWideObstacleUsesSideRouteInsteadOfForcedReturn() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: { abs($0.x) < 0.4 && -$0.z > 0.8 && -$0.z < 1 ? .obstacle : .candidate })
        let u = tracker.update(result: r, observation: nil, options: .init())
        let path = try XCTUnwrap(u.path)
        XCTAssertEqual(u.strategy?.mode, .sideRoute)
        XCTAssertNil(u.strategy?.rejoinPoint)
        XCTAssertGreaterThan(abs(path.points.last!.x), 0.65)
        XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points))
    }
    func testTriggerMeasuresWholeComponentNotOnlyClippedPart() throws {
        let r = frame(cells: { $0.x > -0.1 && $0.x < 0.8 && -$0.z > 0.8 && -$0.z < 1 ? .obstacle : .candidate })
        let raster = RoutePlanningGrid(result: r)!
        let basis = raster.grid.basis
        let reference = ForwardRouteReference(origin: basis.origin, forward: basis.forward, plane: r.plane!)
        let hit = try XCTUnwrap(
            ForwardObstacleTrigger.trigger(raster: raster, device: basis, reference: reference, options: .init()))
        XCTAssertGreaterThan(hit.width, 0.8)
        XCTAssertTrue(hit.extentObserved)
    }
    func testUnknownObjectEdgeDoesNotClaimKnownSmallWidth() throws {
        let r = frame(cells: { p in
            if abs(p.x) < 0.1 && -p.z > 0.8 && -p.z < 1 { return .obstacle }
            return p.x > 0.1 && p.x < 0.3 && -p.z > 0.8 && -p.z < 1 ? .unknown : .candidate
        })
        let raster = RoutePlanningGrid(result: r)!
        let b = raster.grid.basis
        let hit = try XCTUnwrap(
            ForwardObstacleTrigger.trigger(
                raster: raster, device: b,
                reference: .init(origin: b.origin, forward: b.forward, plane: r.plane!), options: .init()))
        XCTAssertFalse(hit.extentObserved)
    }
    func testUnknownStripeCannotBeBypassedByJumpingToFarFanRoot() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame(cells: { p in -p.z > 1.1 && -p.z < 1.5 ? .unknown : self.box(p) })
        let u = tracker.update(result: r, observation: nil, options: .init())
        XCTAssertNil(u.path)
        XCTAssertNil(u.strategy?.maneuverID)
    }
    func testBoxSideAndGoalStayFixedWhenPhoneTurnsOrBoxMomentarilyDisappears() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let a = tracker.update(result: frame(cells: box), observation: nil, options: .init())
        _ = try XCTUnwrap(a.path)
        for i in 2...12 {
            let r = frame(UInt64(i), 1 + Double(i) * 0.1, pose: pose(yaw: -20), cells: { _ in .candidate })
            let b = tracker.update(result: r, observation: nil, options: .init())
            XCTAssertEqual(b.strategy?.side, a.strategy?.side)
            XCTAssertEqual(b.strategy?.maneuverID, a.strategy?.maneuverID)
            XCTAssertEqual(b.goal?.id, a.goal?.id)
            XCTAssertEqual(b.strategy?.reference?.forward, a.strategy?.reference?.forward)
        }
    }
    func testUserTurnNeedsThreeContinuousSecondsAndFreshClearLine() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let a = tracker.update(result: frame(), observation: nil, options: .init())
        var b = a
        for i in 1...29 {
            b = tracker.update(
                result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: 65)), observation: nil,
                options: .init())
            XCTAssertEqual(b.strategy?.reference?.forward, a.strategy?.reference?.forward)
        }
        for i in 30...33 {
            b = tracker.update(
                result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: 65)), observation: nil,
                options: .init())
        }
        XCTAssertNotEqual(b.goal?.id, a.goal?.id)
        XCTAssertEqual(b.strategy?.reference?.forward.x ?? 0, -sin(65 * Float.pi / 180), accuracy: 0.001)
        XCTAssertNotNil(b.path)
    }
    func testDwellResetsOnUnknownGapAndFollowingBendNeverCountsAsOverride() {
        var dwell = ForwardTurnDwell()
        var options = PathOptions()
        options.userTurnSeconds = 3
        let f = V3(-1, 0, 0)
        let route = V3(0, 0, -1)
        for i in 0...20 {
            XCTAssertFalse(
                dwell.update(forward: f, routeForward: route, clear: true, now: 1 + Double(i) * 0.1, options: options))
        }
        XCTAssertFalse(dwell.update(forward: f, routeForward: route, clear: false, now: 3.1, options: options))
        XCTAssertFalse(dwell.update(forward: f, routeForward: route, clear: true, now: 3.2, options: options))
        XCTAssertEqual(dwell.elapsed, 0)
        XCTAssertFalse(dwell.update(forward: f, routeForward: route, clear: true, now: 5, options: options))
        XCTAssertEqual(dwell.elapsed, 0)
        for i in 0...40 {
            XCTAssertFalse(
                dwell.update(forward: f, routeForward: f, clear: true, now: 6 + Double(i) * 0.1, options: options))
        }
    }
    func testTriangleRejectsBoundaryTangencyButIncludesPartialCellOverlap() {
        func cell(_ x: Float, _ z: Float) -> [SIMD2<Float>] {
            [SIMD2(x, z), SIMD2(x + 0.1, z), SIMD2(x + 0.1, z + 0.1), SIMD2(x, z + 0.1)]
        }
        XCTAssertFalse(ForwardObstacleTrigger.intersectsTrigger(cell(0.25, 0.9), distance: 1, width: 0.5))
        XCTAssertTrue(ForwardObstacleTrigger.intersectsTrigger(cell(0.2, 0.85), distance: 1, width: 0.5))
        XCTAssertFalse(ForwardObstacleTrigger.intersectsTrigger(cell(-0.05, 1.01), distance: 1, width: 0.5))
    }
    func testFollowingDetourRejoinsWithoutReinitializingAxis() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let a = tracker.update(result: frame(cells: box), observation: nil, options: .init())
        let path = try XCTUnwrap(a.path)
        let join = try XCTUnwrap(a.strategy?.rejoinPoint)
        let before = try XCTUnwrap(path.points.last(where: { abs($0.x) > 0.2 }))
        let onReturn = before + (join - before) * 0.4
        let b = tracker.update(
            result: frame(2, 1.1, pose: pose(yaw: 0, position: onReturn + V3(0, 1.4, 0)), cells: box), observation: nil,
            options: .init())
        XCTAssertEqual(b.strategy?.mode, .returning)
        XCTAssertEqual(b.strategy?.maneuverID, a.strategy?.maneuverID)
        let c = tracker.update(
            result: frame(3, 1.2, pose: pose(yaw: 0, position: join + V3(0, 1.4, -0.03)), cells: box), observation: nil,
            options: .init())
        XCTAssertEqual(c.strategy?.mode, .straight)
        XCTAssertNil(c.strategy?.maneuverID)
        XCTAssertEqual(c.strategy?.reference?.forward, a.strategy?.reference?.forward)
        XCTAssertTrue(try XCTUnwrap(c.path).points.allSatisfy { abs($0.x) < 0.001 })
    }
    func testBlockedNewDirectionCannotOverrideEvenAfterThreeSeconds() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let a = tracker.update(result: frame(), observation: nil, options: .init())
        let rotated = pose(yaw: 65)
        let basis = GroundBasis(plane: frame().plane!, pose: rotated)!
        var last = a
        for i in 1...40 {
            let r = frame(
                UInt64(i + 1), 1 + Double(i) * 0.1, pose: rotated,
                cells: { p in
                    let q = basis.local(p)
                    return abs(q.x) < 0.1 && q.z > 0.7 && q.z < 1 ? .obstacle : .candidate
                })
            last = tracker.update(result: r, observation: nil, options: .init())
        }
        XCTAssertEqual(last.strategy?.reference?.forward, a.strategy?.reference?.forward)
        XCTAssertNotEqual(last.goalChangeReason, "user_direction_adopted")
        XCTAssertEqual(last.strategy?.turnDwell, 0)
    }
    func testRawDepthVetoAlsoAppliesToNewlyPlannedLine() {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let r = frame()
        let k = CameraIntrinsics(fx: 200, fy: 200, cx: 1.5, cy: 1.5, width: 4, height: 4)
        let depth = DepthObservation(
            width: 4, height: 4, depth: Array(repeating: 1.5, count: 16),
            confidence: Array(repeating: 2, count: 16), intrinsics: k, pose: r.sourcePose!, timestamp: 1, frameID: 1,
            epoch: 1)
        let u = tracker.update(result: r, observation: depth, options: .init())
        XCTAssertNil(u.path)
        XCTAssertEqual(u.reason, "current_obstacle_invalidated")
        XCTAssertEqual(u.strategy?.invalidatesPreviousPath, true)
    }
    func testLookAheadStopsAtBendInsteadOfPointingThroughBox() throws {
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        var path = try XCTUnwrap(tracker.update(result: frame(), observation: nil, options: .init()).path)
        path.points = [V3(0, 0, -0.5), V3(-0.5, 0, -0.6), V3(-0.5, 0, -1.5), V3(0, 0, -1.6)]
        let heading = try XCTUnwrap(
            PathTracking.heading(path: path, pose: pose(yaw: 0, position: V3(0, 1.4, -0.5)), lookAhead: 1.5))
        XCTAssertEqual(heading.target, V3(-0.5, 0, -0.6))
    }
    func testOptionsMigrationAndBoundsAndDiagnosticsRoundTrip() throws {
        var options = try JSONDecoder().decode(PathOptions.self, from: Data("{}".utf8))
        XCTAssertEqual(options.obstacleTriggerDistance, 1)
        XCTAssertEqual(options.obstacleTriggerWidth, 0.5)
        XCTAssertEqual(options.smallObstacleWidth, 0.5)
        XCTAssertEqual(options.userTurnSeconds, 3)
        options.obstacleTriggerDistance = .nan
        options.obstacleTriggerWidth = -1
        options.userTurnSeconds = 0
        options.userTurnDegrees = .infinity
        let validated = options.validated()
        XCTAssertEqual(validated.obstacleTriggerDistance, 1)
        XCTAssertEqual(validated.obstacleTriggerWidth, 0.3)
        XCTAssertEqual(validated.userTurnSeconds, 3)
        XCTAssertEqual(validated.userTurnDegrees, 45)
        var tracker = PathPredictor(obstacleConfirmationSeconds: 0)
        let u = tracker.update(result: frame(cells: box), observation: nil, options: .init())
        let decoded = try JSONDecoder().decode(PathUpdate.self, from: JSONEncoder().encode(u))
        XCTAssertEqual(decoded.strategy?.mode, .detour)
        XCTAssertEqual(decoded.strategy?.rejoinPoint, u.strategy?.rejoinPoint)
    }

}
