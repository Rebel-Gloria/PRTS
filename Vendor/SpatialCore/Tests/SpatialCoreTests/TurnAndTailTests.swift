import XCTest
import simd

@testable import SpatialCore

/// Synthetic clocks and poses: checks turn intent and rolling geometry, not device measurements.
extension ForwardRouteTests {
  func testVetoCanAdoptSideAndReverseHeadingsAfterThreeSeconds() throws {
    for yaw: Float in [-180, -135, -90, 90, 135, 180] {
      var planner = PathPredictor()
      let first = planner.update(
        result: frame(cells: { _ in .unknown }), observation: nil, options: .init())
      var next = first
      for i in 1...36 {
        next = planner.update(
          result: frame(
            UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: yaw), cells: { _ in .unknown }),
          observation: nil, options: .init())
        if i < 30 { XCTAssertEqual(next.goal?.id, first.goal?.id) }
      }
      let expected = -pose(yaw: yaw).back
      XCTAssertGreaterThan(
        simd_dot(try XCTUnwrap(next.strategy?.reference?.forward), expected), 0.99, "yaw \(yaw)")
      XCTAssertGreaterThan(try XCTUnwrap(next.path).length, 6)
    }
  }
  func testTurnDwellUsesHeadingRatherThanGlobalPitchStability() throws {
    var planner = PathPredictor()
    _ = planner.update(result: frame(), observation: nil, options: .init())
    var next = PathUpdate()
    for i in 1...35 {
      var r = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: 70), cells: { _ in .unknown })
      r.sourceDirectionStable = false  // AR tracking is valid; unrelated pitch motion must not reset yaw dwell.
      next = planner.update(result: r, observation: nil, options: .init(), directionStable: false)
    }
    XCTAssertGreaterThan(
      simd_dot(try XCTUnwrap(next.strategy?.reference?.forward), -pose(yaw: 70).back), 0.99)
  }
  func testTurnDwellWorksAtTwoHz() throws {
    var planner = PathPredictor()
    _ = planner.update(result: frame(), observation: nil, options: .init())
    var next = PathUpdate()
    for i in 1...8 {
      next = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.5, pose: pose(yaw: 65)), observation: nil,
        options: .init())
    }
    XCTAssertGreaterThan(
      simd_dot(try XCTUnwrap(next.strategy?.reference?.forward), -pose(yaw: 65).back), 0.99)
  }
  func testStraightRollingTailDoesNotAccumulateGreedyWaypoints() throws {
    var planner = PathPredictor()
    for i in 0...150 {
      let r = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: .init(position: V3(0, 1.4, -Float(i) * 0.2)),
        cells: { _ in .unknown })
      let p = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
      XCTAssertLessThanOrEqual(p.points.count, 2)
      XCTAssertGreaterThan(-p.points.last!.z - Float(i) * 0.2, 6.5)
      XCTAssertLessThan(-p.points.last!.z - Float(i) * 0.2, 8.1)
    }
  }
  func testSideRouteTailExtendsBeforeItsLocalGoalWithoutChangingIdentity() throws {
    var planner = PathPredictor()
    let obstacle: (V3) -> CellState = {
      abs($0.x) < 0.4 && -$0.z > 0.8 ? .obstacle : .unknown
    }
    var first = PathUpdate()
    for i in 0...3 {
      first = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: obstacle), observation: nil,
        options: .init())
    }
    let path = try XCTUnwrap(first.path)
    XCTAssertEqual(first.strategy?.mode, .sideRoute)
    let goal = try XCTUnwrap(path.points.last)
    let near = goal + V3(0, 1.4, 0.5)
    // Keep the known forward obstacle model present during this synthetic large movement.
    var moved = frame(5, 1.4, pose: .init(position: near), cells: obstacle)
    // The immediate result can finish a maneuver; either way it must extend, not end here.
    let next = planner.update(result: moved, observation: nil, options: .init())
    XCTAssertNotNil(next.path)
    XCTAssertGreaterThan(try XCTUnwrap(next.path?.length), 3)
    XCTAssertEqual(next.path?.id, path.id)
    moved.frameID = 6
    moved.timestamp = 1.5
    moved.grid?.frameID = 6
    moved.grid?.timestamp = 1.5
    XCTAssertNotNil(planner.update(result: moved, observation: nil, options: .init()).path)
  }
  func testNewHeadingChecksObstaclesOutsideOriginalRouteWindow() throws {
    var planner = PathPredictor()
    _ = planner.update(result: frame(), observation: nil, options: .init())
    var update = PathUpdate()
    for i in 1...40 {
      let r = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: 90),
        cells: { p in
          p.x < -0.3 && p.x > -0.6 && abs(p.z) < 1 ? .obstacle : .unknown
        })
      update = planner.update(result: r, observation: nil, options: .init())
    }
    XCTAssertGreaterThan(
      simd_dot(try XCTUnwrap(update.strategy?.reference?.forward), V3(0, 0, -1)), 0.99)
    XCTAssertEqual(update.strategy?.turnReason, "new_heading_blocked")
  }
  func testStationaryVetoDoesNotAppendEightMetresEveryFrame() throws {
    var planner = PathPredictor()
    for i in 0...60 {
      let p = try XCTUnwrap(
        planner.update(
          result: frame(UInt64(i + 1), 1 + Double(i) * 0.1), observation: nil, options: .init()
        ).path)
      XCTAssertEqual(p.points.count, 2)
      XCTAssertEqual(p.length, 8, accuracy: 0.03)
    }
  }
  func testCollinearCompressionPreservesCornersAndReverseMotion() {
    let a = V3(0, 0, 0)
    let b = V3(0, 0, -1)
    let c = V3(0, 0, -2)
    let d = V3(1, 0, -2)
    let e = V3(2, 0, -2)
    XCTAssertEqual(RouteArc.coalescingCollinear([a, b, c, d, e]), [a, c, e])
    XCTAssertEqual(RouteArc.coalescingCollinear([a, b, c, b]), [a, c, b])
  }
  func testDirectGreedyPrefixStopsAtFirstOccupiedEnvelope() throws {
    let r = frame(cells: { -$0.z > 2 && -$0.z < 2.2 ? .obstacle : .unknown })
    let raster = try XCTUnwrap(RoutePlanningGrid(result: r, obstacleVeto: true))
    let reference = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    let trace = ForwardPathSearch.straight(raster: raster, reference: reference, foot: .zero)
    let end = -(try XCTUnwrap(trace.points.last)).z
    XCTAssertGreaterThanOrEqual(end, 1.725)
    XCTAssertLessThanOrEqual(end, 1.75001)
    XCTAssertTrue(raster.supports(trace.points))
  }
  func testTurnHeadingJitterAndLongClockGapRestartDwell() {
    var dwell = ForwardTurnDwell()
    let forward = V3(0, 0, -1)
    let left = V3(-1, 0, 0)
    let right = V3(1, 0, 0)
    for i in 0...5 {
      XCTAssertFalse(
        dwell.update(
          forward: left, routeForward: forward, clear: true, now: 1 + Double(i) * 0.5,
          options: .init()))
    }
    XCTAssertFalse(
      dwell.update(forward: right, routeForward: forward, clear: true, now: 4, options: .init()))
    XCTAssertEqual(dwell.elapsed, 0)
    XCTAssertFalse(
      dwell.update(forward: right, routeForward: forward, clear: true, now: 6, options: .init()))
    XCTAssertEqual(dwell.elapsed, 0)
  }

  func testVetoMaskOpensQueryBoundaryButStillVetoesOccupiedCells() throws {
    let r = frame(cells: { _ in .unknown })
    var grid = try XCTUnwrap(r.grid)
    let index = try XCTUnwrap(grid.index(x: 0.05, z: 0.05))
    XCTAssertFalse(PathClearance.mask(grid: grid, radius: 0.25)[index])
    XCTAssertTrue(PathClearance.mask(grid: grid, radius: 0.25, allowUnknown: true)[index])
    grid.cells[index].state = .obstacle
    XCTAssertFalse(PathClearance.mask(grid: grid, radius: 0.25, allowUnknown: true)[index])
  }

}
