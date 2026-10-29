import XCTest
import simd

@testable import SpatialCore

// Synthetic tests of the experimental scene memory (exp/scene-memory), not sensor accuracy.
extension ForwardRouteTests {
  /// Candidate cells carry ground samples, as measured ones do; `hidden` cells are unobserved.
  func memoryFrame(_ id: UInt64, _ time: Double, pose: RigidPose = .init(position: V3(0, 1.4, 0)),
                   hidden: Bool = false, obstacle: Bool = true) -> AnalysisResult {
    var r = frame(id, time, pose: pose, cells: { p in
      guard self.box(p) == .obstacle else { return .candidate }
      return hidden ? .unknown : obstacle ? .obstacle : .candidate
    })
    for i in r.grid!.cells.indices where r.grid!.cells[i].state == .candidate { r.grid!.cells[i].groundSamples = 4 }
    return r
  }

  func confirmedBox(_ filter: inout TemporalOccupancyGrid) {
    for i in 0..<4 { _ = filter.apply(memoryFrame(UInt64(i + 1), 1 + Double(i) * 0.1)) }
    XCTAssertGreaterThan(filter.diagnostics.confirmedCells, 0)
  }

  func testSceneMemoryKeepsObstacleThatLeftTheView() throws {
    var off = TemporalOccupancyGrid()
    confirmedBox(&off)
    XCTAssertEqual(try XCTUnwrap(off.apply(memoryFrame(5, 1.4, hidden: true))).planningObstacles?.count, 0)

    var on = TemporalOccupancyGrid()
    on.memoryOptions.enabled = true
    confirmedBox(&on)
    let hidden = try XCTUnwrap(on.apply(memoryFrame(5, 1.4, hidden: true)))
    XCTAssertEqual(on.diagnostics.confirmedCells, 0)
    XCTAssertGreaterThan(on.diagnostics.rememberedCells ?? 0, 0)
    XCTAssertGreaterThan(hidden.planningObstacles?.count ?? 0, 0)
    XCTAssertTrue(hidden.grid!.cells.contains { $0.state == .obstacle })
    // Measured-only view of the same frame, used for warnings.
    let measured = try XCTUnwrap(on.projected(hidden, forwardLength: 8, forward: V3(0, 0, -1), includeMemory: false))
    XCTAssertEqual(measured.planningObstacles?.count, 0)
  }

  func testSceneMemoryForgetsCellSeenEmpty() throws {
    var filter = TemporalOccupancyGrid()
    filter.memoryOptions.enabled = true
    confirmedBox(&filter)
    let empty = try XCTUnwrap(filter.apply(memoryFrame(5, 1.4, obstacle: false)))
    XCTAssertEqual(filter.diagnostics.rememberedCells, 0)
    XCTAssertEqual(empty.planningObstacles?.count, 0)
  }

  func testSceneMemoryKeepsCellWhenNoDepthArrived() throws {
    var filter = TemporalOccupancyGrid()
    filter.memoryOptions.enabled = true
    confirmedBox(&filter)
    var failed = memoryFrame(5, 1.4, obstacle: false)
    failed.grid = nil  // Ground fit failed: nothing was observed, so nothing is cleared.
    _ = filter.apply(failed)
    XCTAssertGreaterThan(filter.diagnostics.rememberedCells ?? 0, 0)
  }

  func testSceneMemoryExpiresByTimeAndDistance() throws {
    var aged = TemporalOccupancyGrid()
    aged.memoryOptions.enabled = true
    confirmedBox(&aged)
    _ = aged.apply(memoryFrame(5, 1.3 + 15.1, hidden: true))
    XCTAssertEqual(aged.diagnostics.rememberedCells, 0)

    var far = TemporalOccupancyGrid()
    far.memoryOptions.enabled = true
    confirmedBox(&far)
    _ = far.apply(memoryFrame(5, 1.4, pose: .init(position: V3(0, 1.4, 6)), hidden: true))
    XCTAssertEqual(far.diagnostics.rememberedCells, 0)
  }

  func testSceneMemoryDrivesWarningsOnlyWhenAllowed() {
    func scenario(_ memory: SceneMemoryOptions) -> ObstacleRouteScenario? {
      var predictor = PathPredictor(sceneMemory: memory)
      for i in 0..<4 {
        _ = predictor.update(result: memoryFrame(UInt64(i + 1), 1 + Double(i) * 0.1), observation: nil, options: .init())
      }
      var last: PathUpdate?
      for i in 0..<10 {
        last = predictor.update(result: memoryFrame(UInt64(i + 5), 1.4 + Double(i) * 0.1, hidden: true),
                                observation: nil, options: .init())
      }
      return last?.waypointGuidance?.scenario
    }
    XCTAssertEqual(scenario(.init()), .clear)
    XCTAssertEqual(scenario(.init(enabled: true)), .clear)
    let driven = scenario(.init(enabled: true, drivesScenario: true))
    XCTAssertNotNil(driven)
    XCTAssertNotEqual(driven, .clear)
  }
}
