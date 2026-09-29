import XCTest
import simd

@testable import SpatialCore

// Synthetic evidence only; no device accuracy claims.
extension ForwardRouteTests {
  func testProjectionExtendsBeyondObservedGridWithoutChangingUnknown() throws {
    let r = frame(cells: { _ in .unknown })
    var planner = PathPredictor(obstacleConfirmationSeconds: 0)
    let update = planner.update(result: r, observation: nil, options: .init())
    let projection = try XCTUnwrap(update.projection)
    XCTAssertNil(update.path)
    XCTAssertNil(update.goal)
    XCTAssertEqual(simd_distance(projection.points[0], projection.points[1]), 20, accuracy: 0.001)
    XCTAssertTrue(r.grid!.cells.allSatisfy { $0.state == .unknown })
    XCTAssertFalse(projection.clippedByObstacle)
    let mesh = PathDrawing.projectionMesh(projection, observed: nil)
    XCTAssertEqual(mesh.role, .prediction)
    XCTAssertGreaterThan(mesh.vertices.count, 0)
    XCTAssertLessThan(mesh.vertices.count, 1000)
  }

  func testProjectionClipsAtWallAndDoesNotCrossIt() throws {
    let r = frame(cells: { -$0.z > 2 && -$0.z < 2.2 ? .obstacle : .candidate })
    let reference = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    let p = try XCTUnwrap(RouteProjection.make(result: r, reference: reference, options: .init()))
    XCTAssertTrue(p.clippedByObstacle)
    XCTAssertLessThan(-p.points[1].z, 2)
    XCTAssertGreaterThan(-p.points[1].z, 1.5)
    let a = r.grid!.basis.local(p.points[0])
    let b = r.grid!.basis.local(p.points[1])
    XCTAssertTrue(
      PathClearance.segment(
        grid: r.grid!, from: SIMD2(a.x, a.z), to: SIMD2(b.x, b.z),
        radius: 0.25, allowUnknown: true))
  }

  func testProjectionKeepsHalfMetreCorridorOpen() throws {
    var r = frame()
    r.grid!.halfWidth += 0.05
    // Put centres at +/- 0.30; their 0.10m cells leave exactly 0.50m.
    for i in r.grid!.cells.indices {
      let c = r.grid!.center(i)
      r.grid!.cells[i].state = abs(c.x) >= 0.299 ? .obstacle : .unknown
    }
    let ref = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    let p = try XCTUnwrap(RouteProjection.make(result: r, reference: ref, options: .init()))
    XCTAssertFalse(p.clippedByObstacle)
    XCTAssertEqual(-p.points[1].z, 20, accuracy: 0.001)
  }

  func testProjectionMovesWindowAndKeepsWorldHeading() throws {
    var planner = PathPredictor(obstacleConfirmationSeconds: 0)
    _ = planner.update(result: frame(), observation: nil, options: .init())
    let r = frame(2, 1.1, pose: pose(yaw: 25, position: V3(0, 1.4, -1)))
    let p = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).projection)
    XCTAssertEqual(p.points[0].z, -1, accuracy: 0.001)
    XCTAssertEqual(p.points[1].z, -21, accuracy: 0.001)
    XCTAssertEqual(p.points[1].x, 0, accuracy: 0.001)
  }

  func testProjectionGatesTrackingAgeEpochAndFutureTimestamp() throws {
    let r = frame()
    let ref = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    let p = try XCTUnwrap(RouteProjection.make(result: r, reference: ref, options: .init()))
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = r.epoch
    gate.parameterVersion = r.parameterVersion
    gate.frameID = r.frameID
    gate.frameTimestamp = r.timestamp
    XCTAssertTrue(p.visible(gate: gate, now: 1.1))
    XCTAssertFalse(p.visible(gate: gate, now: 2))
    gate.trackingNormal = false
    XCTAssertFalse(p.visible(gate: gate, now: 1.1))
    gate.trackingNormal = true
    gate.epoch += 1
    XCTAssertFalse(p.visible(gate: gate, now: 1.1))
    gate.epoch = r.epoch
    gate.frameTimestamp = 0.99
    XCTAssertFalse(p.visible(gate: gate, now: 1.1))
  }

  func testProjectionRejectsStaleGridAndMissingReference() {
    var r = frame()
    let ref = ForwardRouteReference(origin: .zero, forward: V3(0, 0, -1), plane: r.plane!)
    r.grid?.frameID = 0
    XCTAssertNil(RouteProjection.make(result: r, reference: ref, options: .init()))
    r = frame()
    r.diagnostics?.groundReferenceMode = "unavailable"
    XCTAssertNotNil(RouteProjection.make(result: r, reference: ref, options: .init()))
  }

  func testProjectionAbsentDuringDetourAndCodableRoundtrip() throws {
    var planner = PathPredictor(obstacleConfirmationSeconds: 0)
    let u = planner.update(result: frame(cells: box), observation: nil, options: .init())
    XCTAssertNotNil(u.strategy?.maneuverID)
    XCTAssertNil(u.projection)
    planner.reset()
    let projected = planner.update(result: frame(), observation: nil, options: .init())
    let data = try JSONEncoder().encode(projected)
    let decoded = try JSONDecoder().decode(PathUpdate.self, from: data)
    XCTAssertEqual(decoded.projection?.points, projected.projection?.points)
  }
}
