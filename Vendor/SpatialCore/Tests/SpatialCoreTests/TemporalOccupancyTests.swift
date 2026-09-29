import XCTest
import simd

@testable import SpatialCore

// Synthetic tests of the Dev-only occupancy policy, not sensor accuracy.
extension ForwardRouteTests {
  func testExperimentalGhostDoesNotStopRouteOrTriggerDetour() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    let first = planner.update(result: frame(cells: box), observation: nil, options: .init())
    XCTAssertNotNil(first.path)
    XCTAssertNil(first.strategy?.maneuverID)
    XCTAssertGreaterThan(first.occupancyFilter?.pendingCells ?? 0, 0)
    XCTAssertEqual(first.occupancyFilter?.confirmedCells, 0)
    XCTAssertGreaterThan(first.path?.length ?? 0, 3)
    let gone = planner.update(result: frame(2, 1.1), observation: nil, options: .init())
    XCTAssertEqual(gone.occupancyFilter?.confirmedCells, 0)
    XCTAssertEqual(gone.occupancyFilter?.pendingCells, 0)
    XCTAssertNil(gone.strategy?.maneuverID)
  }

  func testExperimentalPersistentObstacleActivatesAt300ms() throws {
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    for index in 0..<4 {
      let r = frame(UInt64(index + 1), 1 + Double(index) * 0.1, cells: box)
      let u = planner.update(result: r, observation: nil, options: .init())
      if index < 3 {
        XCTAssertEqual(u.occupancyFilter?.confirmedCells, 0)
        XCTAssertNil(u.strategy?.maneuverID)
      } else {
        XCTAssertGreaterThan(u.occupancyFilter?.confirmedCells ?? 0, 0)
        XCTAssertNotNil(u.strategy?.maneuverID)
        XCTAssertNotNil(u.path)
        XCTAssertTrue(u.path!.points.contains { abs($0.x) > 0.25 })
      }
    }
  }

  func testExperimentalDisappearResetsTimerAndEpochIsolatesEvidence() {
    var filter = TemporalOccupancyGrid()
    for i in 0..<3 { _ = filter.apply(frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box)) }
    _ = filter.apply(frame(4, 1.25))
    _ = filter.apply(frame(5, 1.3, cells: box))
    XCTAssertEqual(filter.diagnostics.confirmedCells, 0)
    XCTAssertEqual(filter.diagnostics.maximumAge, 0, accuracy: 0.0001)
    var planner = PathPredictor(experimentalOccupancyPlanning: true)
    for i in 0..<4 {
      _ = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box), observation: nil,
        options: .init())
    }
    var next = frame(1, 2, cells: box)
    next.epoch = 2
    next.grid?.epoch = 2
    let update = planner.update(result: next, observation: nil, options: .init())
    XCTAssertEqual(update.occupancyFilter?.confirmedCells, 0)
    XCTAssertNil(update.strategy?.maneuverID)
  }

  func testExperimentalGapDoesNotCountAsContinuousDetection() {
    var filter = TemporalOccupancyGrid()
    _ = filter.apply(frame(1, 1, cells: box))
    _ = filter.apply(frame(2, 1.31, cells: box))
    XCTAssertEqual(filter.diagnostics.confirmedCells, 0)
    XCTAssertEqual(filter.diagnostics.maximumAge, 0, accuracy: 0.0001)
  }

  func testExperimentalGridDoesNotRewriteRawObservation() throws {
    var filter = TemporalOccupancyGrid()
    let input = frame(cells: { abs($0.x) < 0.1 ? .obstacle : .unknown })
    let before = try JSONEncoder().encode(input)
    let planned = try XCTUnwrap(filter.apply(input))
    XCTAssertTrue(planned.grid!.cells.allSatisfy { $0.state == .candidate })
    XCTAssertEqual(try JSONEncoder().encode(input).count, before.count)
    XCTAssertTrue(input.grid!.cells.contains { $0.state == .obstacle })
    XCTAssertTrue(input.grid!.cells.contains { $0.state == .unknown })
    XCTAssertTrue(planned.source.contains("experimental_occupancy_300ms"))
  }

  func testGreedyBypassReturnsToReferenceWithoutCrossingObstacle() throws {
    let r = frame(cells: { abs($0.x) < 0.15 && -$0.z > 1.4 && -$0.z < 1.7 ? .obstacle : .candidate }
    )
    let raster = try XCTUnwrap(RoutePlanningGrid(result: r))
    let ref = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    let obstacle = try XCTUnwrap(
      ForwardObstacleTrigger.trigger(
        raster: raster, device: r.grid!.basis, reference: ref, options: .init()))
    let entry = ForwardPathSearch.straight(raster: raster, reference: ref, foot: .zero).entry
    let (plan, join) = try XCTUnwrap(
      GreedyDetourSearch.plan(
        raster: raster, reference: ref, obstacle: obstacle, entry: entry, side: 1))
    XCTAssertTrue(raster.supports(plan.points))
    XCTAssertEqual(join.x, 0, accuracy: 0.0001)
    XCTAssertTrue(plan.points.contains { $0.x > 0.3 })
    XCTAssertLessThan(plan.points.last!.z, obstacle.far * -1)
  }

  func testStableCellMatchingUsesWorldCoordinatesDuringCameraMotion() {
    var filter = TemporalOccupancyGrid()
    for i in 0..<4 {
      _ = filter.apply(
        frame(
          UInt64(i + 1), 1 + Double(i) * 0.1,
          pose: .init(position: V3(0, 1.4, -Float(i) * 0.1)), cells: box))
    }
    XCTAssertGreaterThan(filter.diagnostics.confirmedCells, 0)
  }

  func testNormalPlannerStillRejectsFirstFrameObstacle() {
    var planner = PathPredictor()
    let r = frame(cells: box)
    let u = planner.update(result: r, observation: nil, options: .init())
    XCTAssertNil(u.occupancyFilter)
    XCTAssertNil(u.strategy?.maneuverID)
    if let path = u.path { XCTAssertTrue(RoutePlanningGrid(result: r)!.supports(path.points)) }
  }
}
