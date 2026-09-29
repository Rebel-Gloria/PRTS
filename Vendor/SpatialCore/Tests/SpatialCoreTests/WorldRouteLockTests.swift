import XCTest
import simd

@testable import SpatialCore

extension ForwardRouteTests {
  func testExperimentalRouteSurvivesRotatingLocalGridWithoutReselection() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let initial = planner.update(result: frame(), observation: nil, options: .init())
    let original = try XCTUnwrap(initial.path)
    for i in 1...12 {
      var r = frame(UInt64(i + 1), 1 + Double(i) * 0.1, pose: pose(yaw: Float(i) * 4))
      r.sourceDirectionStable = false
      let u = planner.update(result: r, observation: nil, options: .init())
      let path = try XCTUnwrap(u.path)
      XCTAssertEqual(path.points.last, original.points.last)
      XCTAssertEqual(u.goal?.point, initial.goal?.point)
      XCTAssertEqual(path.id, original.id)
      XCTAssertEqual(path.validatedFrameID, r.frameID)
      XCTAssertEqual(u.reason, "world_route_preserved")
      XCTAssertEqual(path.worldLocked, true)
    }
  }

  func testExperimentalRoutePlaneDoesNotFollowFitNoise() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let first = planner.update(result: frame(), observation: nil, options: .init())
    for i in 1...10 {
      var r = frame(UInt64(i + 1), 1 + Double(i) * 0.1)
      r.plane?.offset = i % 2 == 0 ? 0.025 : -0.025
      r.diagnostics?.groundConfirmed = true
      let u = planner.update(result: r, observation: nil, options: .init())
      XCTAssertEqual(u.path?.points, first.path?.points)
      XCTAssertEqual(u.path?.plane.offset, first.path?.plane.offset)
      XCTAssertEqual(u.goal?.point, first.goal?.point)
    }
  }

  func testLockedApproachAndRetainedRouteAreSolidMeshes() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let path = try XCTUnwrap(
      planner.update(result: frame(), observation: nil, options: .init()).path)
    let presentation = PathPresentation(
      path: path, age: 0.3, historical: true,
      approach: [V3.zero, path.points[0]])
    let meshes = PathDrawing.meshes(presentation)
    XCTAssertFalse(meshes.contains { $0.role == .unknownApproach || $0.role == .history })
    let approach = try XCTUnwrap(meshes.first)
    XCTAssertEqual(approach.role, .planned)
    XCTAssertEqual(approach.vertices.count, 6)  // one solid quad, not repeated dash quads
  }

  func testLockedRouteStillWithdrawsForConfirmedNewObstacle() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let initial = planner.update(result: frame(), observation: nil, options: .init())
    for i in 1...4 {
      let u = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box),
        observation: nil, options: .init())
      if i < 4 {
        XCTAssertEqual(u.path?.points.last, initial.path?.points.last)
      } else {
        XCTAssertGreaterThan(u.occupancyFilter?.confirmedCells ?? 0, 0)
        XCTAssertNotEqual(u.path?.points, initial.path?.points)
      }
    }
  }

  func testVetoRouteKeepsWorldPlaneDespiteGroundFitChange() {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let first = planner.update(result: frame(), observation: nil, options: .init())
    var r = frame(2, 1.1)
    r.plane?.offset = 0.25
    r.diagnostics?.groundConfirmed = true
    let u = planner.update(result: r, observation: nil, options: .init())
    XCTAssertEqual(u.path?.points,first.path?.points)
    XCTAssertEqual(u.path?.plane.offset,first.path?.plane.offset)
  }
  func testLockedSideRouteSurvivesCameraGridBoundary() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let obstacle: (V3) -> CellState = {
      abs($0.x) < 0.5 && -$0.z > 0.8 && -$0.z < 1.1 ? .obstacle : .candidate
    }
    var last = PathUpdate()
    for i in 0..<4 {
      last = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: obstacle),
        observation: nil, options: .init())
    }
    let original = try XCTUnwrap(last.path)
    XCTAssertEqual(last.strategy?.mode, .sideRoute)
    // No current occupancy intersects the selected side route; only the viewport moves.
    for i in 1...6 {
      var r = frame(UInt64(i + 4), 1.3 + Double(i) * 0.1, pose: pose(yaw: -Float(i) * 5), cells:obstacle)
      r.sourceDirectionStable = false
      let next = planner.update(result: r, observation: nil, options: .init())
      XCTAssertEqual(next.path?.points.last, original.points.last)
      XCTAssertEqual(next.strategy?.side, last.strategy?.side)
      XCTAssertEqual(next.reason, "world_route_preserved")
    }
  }

}
