import XCTest
import simd

@testable import SpatialCore

extension ForwardRouteTests {
  func testDefaultPolicyDoesNotAuthorizeGroundOnly() {
    var r = frame(cells: { _ in .unknown })
    for i in r.grid!.cells.indices {
      r.grid!.cells[i].groundSamples = 5
      r.grid!.cells[i].observedAt = r.timestamp
    }
    var planner = PathPredictor()
    XCTAssertNil(planner.update(result: r, observation: nil, options: .init()).path)
  }

  func testDefaultPolicyUsesBodyEnvelope() throws {
    var planner = PathPredictor()
    let r = frame()
    let p = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
    XCTAssertEqual(
      p.requiredWidth, r.parameters.bodyWidth + 2 * r.parameters.sideMargin, accuracy: 0.0001)
  }

  func testPresentationDoesNotHideMerelyNearLocalEnd() throws {
    var planner = PathPredictor()
    var path = try XCTUnwrap(
      planner.update(result: frame(), observation: nil, options: .init()).path)
    path.points = [V3(0, 0, -0.05), V3(0, 0, -0.25)]
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = path.epoch
    gate.parameterVersion = path.parameterVersion
    gate.frameID = 1
    gate.frameTimestamp = 1
    XCTAssertNotNil(
      PathPresentation.make(
        path: path, gate: gate, pose: .init(position: V3(0, 1.4, 0)),
        options: .init(), now: 1.01))
  }
}
