import XCTest
import simd

@testable import SpatialCore

extension ForwardRouteTests {
  func testEvidenceSurvivesYawWithoutRefreshingObservationAge() throws {
    var map = RouteEvidenceMap()
    let r = frame()
    XCTAssertTrue(map.ingest(r))
    let p = V3(0, 0, -1.2)
    let original = try XCTUnwrap(map.support(from: p, to: p, width: 0.9, at: 1))
    var rotated = frame(2, 1.2, pose: pose(yaw: 90), cells: { _ in .unknown })
    rotated.diagnostics?.groundReferenceMode = "current_confirmed"
    XCTAssertTrue(map.ingest(rotated))
    let kept = try XCTUnwrap(map.support(from: p, to: p, width: 0.9, at: 1.2))
    XCTAssertEqual(kept.observedAt, original.observedAt)
    XCTAssertNil(map.support(from: p, to: p, width: 0.9, at: 1.51))
  }
  func testObstacleMemoryRequiresPositiveFreeEvidenceToClear() throws {
    var map = RouteEvidenceMap()
    let p = V3(0, 0, -1.2)
    _ = map.ingest(frame(cells: { _ in .obstacle }))
    _ = map.ingest(frame(2, 1.21, cells: { _ in .unknown }))
    XCTAssertNil(map.support(from: p, to: p, width: 0.9, at: 1.21))
    _ = map.ingest(frame(3, 1.42))
    XCTAssertNil(map.support(from: p, to: p, width: 0.9, at: 1.42))
    _ = map.ingest(frame(4, 1.63))
    XCTAssertNotNil(map.support(from: p, to: p, width: 0.9, at: 1.63))
  }
  func testWorldWindowEvictsOldRegionAndEpochResets() {
    var map = RouteEvidenceMap()
    _ = map.ingest(frame())
    _ = map.ingest(frame(2, 1.1, pose: .init(position: V3(20, 1.4, 0)), cells: { _ in .unknown }))
    XCTAssertNil(map.support(from: V3(0, 0, -1), to: V3(0, 0, -2), width: 0.9, at: 1.1))
    XCTAssertLessThan(map.count, 10)
    var next = frame(1, 1.2, cells: { _ in .unknown })
    next.epoch = 2
    next.grid?.epoch = 2
    _ = map.ingest(next)
    XCTAssertEqual(map.epoch, 2)
    XCTAssertEqual(map.count, 0)
  }
  func testRollingVerifiedTailReadyBeforeLocalEnd() throws {
    var planner = PathPredictor(policy:.verified)
    let first = planner.update(result: frame(), observation: nil, options: .init())
    let id = try XCTUnwrap(first.path).id
    var extensions = 0
    for i in 1...35 {
      let r = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: .init(position: V3(0, 1.4, -Float(i) * 0.1)))
      let u = planner.update(result: r, observation: nil, options: .init())
      let p = try XCTUnwrap(u.path)
      XCTAssertEqual(p.id, id)
      XCTAssertGreaterThan(p.length, 1)
      if u.reason == "verified_tail_extended" { extensions += 1 }
    }
    XCTAssertGreaterThan(extensions, 0)
  }
  func testPublicationLateAndOutOfOrderKeepValidPrefix() throws {
    var planner = PathPredictor(policy:.verified)
    let a = planner.update(result: frame(), observation: nil, options: .init())
    let b = planner.update(result: frame(2, 1.1), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.parameterVersion = 0
    gate.frameID = 2
    gate.frameTimestamp = 1.31
    let late = RoutePublicationPolicy.decide(
      current: b, candidate: a, gate: gate, hazardWatermark: 0, now: 1.31)
    XCTAssertFalse(late.accepted)
    XCTAssertEqual(late.reason, "out_of_order")
    XCTAssertNotNil(late.update.path)
    var candidate = b
    candidate.continuity?.timestamp = 0.5
    let expired = RoutePublicationPolicy.decide(
      current: b, candidate: candidate, gate: gate, hazardWatermark: 0, now: 1.31)
    XCTAssertEqual(expired.reason, "candidate_expired_or_future")
    XCTAssertNotNil(expired.update.path)
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: b, candidate: candidate, gate: gate, hazardWatermark: 0, now: 2
      ).update.path)
  }
  func testHazardWatermarkRejectsPreHazardCandidate() throws {
    var planner = PathPredictor(policy:.verified)
    let a = planner.update(result: frame(), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 2
    gate.frameTimestamp = 1.1
    let u = RoutePublicationPolicy.decide(
      current: a, candidate: a, gate: gate, hazardWatermark: 2, now: 1.1)
    XCTAssertEqual(u.reason, "hazard_watermark")
    XCTAssertNil(u.update.path)
  }
  func testUnrelatedMapVersionDoesNotStarvePublication() {
    var planner = PathPredictor(policy:.verified)
    let a = planner.update(result: frame(), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 1
    gate.frameTimestamp = 1
    var old = a
    old.continuity?.sourceMapVersion = 999
    let u = RoutePublicationPolicy.decide(
      current: old, candidate: a, gate: gate, hazardWatermark: 0, now: 1.05)
    XCTAssertTrue(u.accepted)
  }
  func testNoEvidenceExpiresRatherThanBecomingFree() {
    var planner = PathPredictor(policy:.verified)
    _ = planner.update(result: frame(), observation: nil, options: .init())
    let u = planner.update(
      result: frame(2, 1.6, cells: { _ in .unknown }), observation: nil, options: .init())
    XCTAssertNil(u.path)
    XCTAssertEqual(u.continuity?.status, .needsObservation)
  }
  func testProgressWindowCannotJumpToHairpinReturnLeg() {
    let points = [V3(0, 0, 0), V3(0, 0, -3), V3(0.1, 0, -3), V3(0.1, 0, 0)]
    let remaining = RouteProgressWindow.remaining(
      points, plane: GroundPlane(normal: V3(0, 1, 0), offset: 0),
      pose: .init(position: V3(0.09, 1.4, -0.1)), maximumAdvance: 0.5)
    XCTAssertEqual(remaining.count, 4)
    XCTAssertEqual(remaining[0].x, 0)
  }
  func testSlowConfirmationHandles210msAndMissedFrame() {
    var persistence = ObstaclePersistence()
    let o = ForwardObstacle(
      width: 0.4, distance: 1, extentObserved: true, near: 1, far: 1.4, minLateral: -0.2,
      maxLateral: 0.2)
    for gap in [0.1, 0.2, 0.21, 0.3] {
      persistence.reset()
      XCTAssertFalse(persistence.update(o, at: 1, maximumGap: 0.75))
      var time = 1 + gap
      while time < 1.3 {
        _ = persistence.update(o, at: time, maximumGap: 0.75)
        time += gap
      }
      XCTAssertTrue(persistence.update(o, at: time, maximumGap: 0.75))
    }
    XCTAssertFalse(persistence.update(o, at: 4, maximumGap: 0.75))
  }
  func testCurrentClusterPreemptsBeforeSlowConfirmation() throws {
    var planner = PathPredictor(policy:.verified)
    let old = try XCTUnwrap(
      planner.update(result: frame(), observation: nil, options: .init()).path)
    let hit = frame(
      2, 1.1, cells: { abs($0.x) < 0.15 && abs($0.z + 1.5) < 0.15 ? .obstacle : .candidate })
    XCTAssertTrue(RouteSafety.conflicts(old, result: hit, observation: nil))
    let next = planner.update(result: hit, observation: nil, options: .init(), hazardWatermark: 2)
    XCTAssertFalse(next.strategy?.obstacleConfirmed ?? true)
    if let prefix = next.path {
      XCTAssertFalse(RouteSafety.conflicts(prefix, result: hit, observation: nil))
    }
  }
  func testRawDepthClusterVetoAndIsolatedPixelTolerance() throws {
    var planner = PathPredictor(policy:.verified)
    let r = frame()
    let old = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
    let k = CameraIntrinsics(fx: 200, fy: 200, cx: 1.5, cy: 1.5, width: 4, height: 4)
    var values = Array(repeating: Float.nan, count: 16)
    values[5] = 1.5
    func observation(_ d: [Float]) -> DepthObservation {
      .init(
        width: 4, height: 4, depth: d, confidence: Array(repeating: 2, count: 16), intrinsics: k,
        pose: r.sourcePose!, timestamp: 1.1, frameID: 2, epoch: 1)
    }
    XCTAssertFalse(RouteSafety.conflicts(old, result: r, observation: observation(values)))
    XCTAssertTrue(
      RouteSafety.conflicts(
        old, result: r, observation: observation(Array(repeating: 1.5, count: 16))))
  }
  func testExpiredSuffixDoesNotEraseSupportedPrefixOrRefreshEvidence() throws {
    var planner = PathPredictor(policy:.verified)
    var p = try XCTUnwrap(planner.update(result: frame(), observation: nil, options: .init()).path)
    p.points = [V3(0, 0, -1), V3(0, 0, -3)]
    p.evidenceIntervals = [
      .init(endS: 1, observedAt: 1.2, validUntil: 1.7, mapVersion: 2),
      .init(endS: 2, observedAt: 1, validUntil: 1.5, mapVersion: 1),
    ]
    let visible = try XCTUnwrap(RouteEvidencePresentation.validPrefix(p, now: 1.6))
    XCTAssertEqual(visible.length, 1, accuracy: 0.0001)
    XCTAssertEqual(visible.evidenceIntervals?.last?.observedAt, 1.2)
    XCTAssertNil(RouteEvidencePresentation.validPrefix(visible, now: 1.71))
  }
  func testEpochAndBodyChangeRejectOldCandidate() throws {
    var planner = PathPredictor(policy:.verified)
    let old = planner.update(result: frame(), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 2
    gate.frameID = 1
    gate.frameTimestamp = 1
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: old, candidate: old, gate: gate, hazardWatermark: 0, now: 1.1
      ).update.path)
    gate.epoch = 1
    gate.parameterVersion = 2
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: old, candidate: old, gate: gate, hazardWatermark: 0, now: 1.1
      ).update.path)
    gate.parameterVersion = 0
    gate.minimumGeometryFrameID = 2
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: old, candidate: old, gate: gate, hazardWatermark: 0, now: 1.1
      ).update.path)
  }
  func testWorldRouteRetainedWhenPhoneYawChanges() throws {
    var planner = PathPredictor(policy:.verified)
    let first = try XCTUnwrap(
      planner.update(result: frame(), observation: nil, options: .init()).path)
    let u = planner.update(
      result: frame(2, 1.1, pose: pose(yaw: 60), cells: { _ in .unknown }), observation: nil,
      options: .init())
    XCTAssertEqual(u.path?.points, first.points)
    XCTAssertEqual(u.path?.id, first.id)
    XCTAssertEqual(u.path?.evidenceIntervals?.first?.observedAt, 1)
  }
  func testGhostMemoryCannotBecomeMultipleSensorHits() {
    var planner = PathPredictor(policy:.verified)
    _ = planner.update(result: frame(cells: box), observation: nil, options: .init())
    let missing = planner.update(
      result: frame(2, 1.4, cells: { _ in .unknown }), observation: nil, options: .init())
    XCTAssertFalse(missing.strategy?.obstacleConfirmed ?? true)
    XCTAssertNil(missing.strategy?.maneuverID)
  }
  func testMissedFrameDoesNotEraseSlowTrackButCannotAdvanceIt() {
    var p = ObstaclePersistence()
    let hit = ForwardObstacle(
      width: 0.4, distance: 1, extentObserved: true, near: 1, far: 1.4, minLateral: -0.2,
      maxLateral: 0.2)
    XCTAssertFalse(p.update(hit, at: 1, maximumGap: 0.75, retainOnMissing: true))
    XCTAssertFalse(p.update(nil, at: 1.21, maximumGap: 0.75, retainOnMissing: true))
    XCTAssertTrue(p.update(hit, at: 1.42, maximumGap: 0.75, retainOnMissing: true))
    XCTAssertTrue(p.update(nil, at: 1.63, maximumGap: 0.75, retainOnMissing: true))
    XCTAssertFalse(p.update(hit, at: 3, maximumGap: 0.75, retainOnMissing: true))
  }
  func testVerifiedCorridorUsesSameEnvelopeAfterSimplification() throws {
    var planner = PathPredictor(policy:.verified)
    let narrow = frame(cells: { abs($0.x) < 0.35 ? .candidate : .obstacle })
    XCTAssertNil(planner.update(result: narrow, observation: nil, options: .init()).path)
    planner.reset()
    let wide = frame(cells: { abs($0.x) < 0.65 ? .candidate : .obstacle })
    let p = try XCTUnwrap(planner.update(result: wide, observation: nil, options: .init()).path)
    var map = RouteEvidenceMap()
    _ = map.ingest(wide)
    XCTAssertEqual(
      map.prefix(p.points, width: p.requiredWidth, at: 1).length, p.length, accuracy: 0.001)
  }

  func testReferenceConflictPreemptsEvenWhenReplacementWouldBeLate() throws {
    var planner = PathPredictor(policy:.verified)
    let a = planner.update(result: frame(), observation: nil, options: .init())
    let path = try XCTUnwrap(a.path)
    var conflict = frame(2, 1.1)
    conflict.plane = GroundPlane(normal: V3(0, 1, 0), offset: 0.2)
    XCTAssertEqual(
      RouteSafety.invalidationReason(path, result: conflict, observation: nil),
      "ground_reference_conflict")
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 3
    gate.frameTimestamp = 1.4
    let rejected = RoutePublicationPolicy.decide(
      current: a, candidate: a, gate: gate, hazardWatermark: 2, now: 1.4)
    XCTAssertNil(rejected.update.path)
  }

}
