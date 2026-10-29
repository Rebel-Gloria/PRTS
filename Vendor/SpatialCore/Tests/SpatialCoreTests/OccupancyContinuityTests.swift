import XCTest
import simd

@testable import SpatialCore

// Build18 continuous-route comparison. Product three-state/waypoint scheduling is tested
// in ObstacleWaypointTests; these retain reusable search/publication/geometry regressions.

/// Deterministic synthetic inputs for the product obstacle-veto policy.
extension ForwardRouteTests {
  func testOccupancyUnknownSearchHasAtomicContextButNoVerifiedLength() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let raw = frame(cells: { _ in .unknown })
    let update = planner.update(result: raw, observation: nil, options: .init())
    let path = try XCTUnwrap(update.path)
    XCTAssertGreaterThan(path.length, 3)
    XCTAssertEqual(path.requiredWidth, 0.5, accuracy: 0.001)
    XCTAssertEqual(update.continuity?.remainingVerifiedLength, 0)
    XCTAssertNotEqual(path.verifiedEvidence, true)
    XCTAssertTrue(raw.grid!.cells.allSatisfy { $0.state == .unknown })
  }
  func testOccupancyRollingTailExtendsBeforeReachingHorizon() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let first = try XCTUnwrap(
      planner.update(result: frame(cells: { _ in .unknown }), observation: nil, options: .init())
        .path)
    var furthest = -first.points.last!.z
    for i in 1...25 {
      let r = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: .init(position: V3(0, 1.4, -Float(i) * 0.1)),
        cells: { _ in .unknown })
      let p = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
      XCTAssertEqual(p.id, first.id)
      XCTAssertGreaterThan(p.length, 2)
      furthest = max(furthest, -p.points.last!.z)
    }
    XCTAssertGreaterThan(furthest, -first.points.last!.z + 1.5)
  }
  func testDefaultVetoKeepsExtendingFastWalkAcrossManyOldEndpoints() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    var id: UInt64?
    for i in 0...150 {
      let raw = frame(
        UInt64(i + 1), 1 + Double(i) * 0.1, pose: .init(position: V3(0, 1.4, -Float(i) * 0.2)),
        cells: { _ in .unknown })
      let u = planner.update(result: raw, observation: nil, options: .init())
      let p = try XCTUnwrap(u.path)
      if id == nil { id = p.id }
      XCTAssertEqual(p.id, id)
      XCTAssertGreaterThan(-p.points.last!.z - Float(i) * 0.2, 6.5)
      XCTAssertEqual(u.continuity?.planningPolicy, "obstacle_veto_v1")
      XCTAssertEqual(u.continuity?.remainingVerifiedLength, 0)
    }
  }
  func testMissingGroundAndExpiredEvidenceDoNotGateVeto() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let first = try XCTUnwrap(
      planner.update(result: frame(), observation: nil, options: .init()).path)
    var missing = frame(2, 100, cells: { _ in .unknown })
    missing.plane = nil
    missing.grid = nil
    missing.diagnostics?.groundConfirmed = false
    missing.diagnostics?.groundReferenceInvalidation = "reference_expired_or_clock_reversed"
    let u = planner.update(result: missing, observation: nil, options: .init())
    XCTAssertEqual(u.path?.points, first.points)
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 999
    gate.frameTimestamp = 200
    XCTAssertNotNil(
      PathPresentation.make(
        path: first, gate: gate, pose: missing.sourcePose!, options: .init(), now: 200.1))
  }
  func testNoInitialPlaneOrGridStillPlansOnFixedDrawingReference() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    var r = frame()
    r.plane = nil
    r.grid = nil
    r.diagnostics?.groundReferenceMode = "unavailable"
    let first = planner.update(result: r, observation: nil, options: .init())
    XCTAssertGreaterThan(try XCTUnwrap(first.path).length, 7)
    XCTAssertEqual(first.occupancyFilter?.referenceSource, "camera_height_1.4m")
    r.frameID = 2
    r.timestamp = 1.1
    r.sourcePose?.position.y += 0.2
    let next = planner.update(result: r, observation: nil, options: .init())
    XCTAssertEqual(next.path?.points, first.path?.points)
  }
  func testVetoPublicationDoesNotRequireEvidenceOrResultTTL() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let a = planner.update(result: frame(), observation: nil, options: .init())
    let b = planner.update(result: frame(2, 1.1), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 99
    gate.frameTimestamp = 100
    let accepted = RoutePublicationPolicy.decide(
      current: a, candidate: b, gate: gate, hazardWatermark: 0, now: 100,
      expectedPolicy: .obstacleVeto)
    XCTAssertTrue(accepted.accepted)
    XCTAssertEqual(accepted.update.continuity?.remainingVerifiedLength, 0)
    let late = RoutePublicationPolicy.decide(
      current: b, candidate: a, gate: gate, hazardWatermark: 0, now: 100,
      expectedPolicy: .obstacleVeto)
    XCTAssertFalse(late.accepted)
    XCTAssertNotNil(late.update.path)
    XCTAssertEqual(late.reason, "out_of_order")
  }
  func testConfirmedVetoPreemptsBeforeSearchAndRejectsOlderCandidate() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let before = planner.update(result: frame(), observation: nil, options: .init())
    var watermark: UInt64 = 0
    var last = before
    for i in 1...4 {
      last = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box), observation: nil,
        options: .init(),
        committedPath: before.path, onOccupancyConflict: { watermark = $0 })
      if i < 4 { XCTAssertEqual(watermark, 0) }
    }
    XCTAssertEqual(watermark, 5)
    XCTAssertNotNil(last.strategy?.maneuverID)
    XCTAssertEqual(last.continuity?.hazardWatermark, watermark)
    XCTAssertTrue(try XCTUnwrap(last.path).points.contains { abs($0.x) > 0.25 })
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 5
    gate.frameTimestamp = 1.4
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: before, candidate: before, gate: gate, hazardWatermark: watermark, now: 1.4,
        expectedPolicy: .obstacleVeto
      ).update.path)
  }
  func testDisappearingVetoRestoresStraightRouteWithoutFreeCertification() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    var blocked = PathUpdate()
    for i in 0...3 {
      blocked = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box), observation: nil,
        options: .init())
    }
    XCTAssertNotNil(blocked.strategy?.maneuverID)
    let cleared = planner.update(
      result: frame(5, 1.4, cells: { _ in .unknown }), observation: nil, options: .init())
    XCTAssertEqual(cleared.strategy?.mode, .straight)
    XCTAssertTrue(try XCTUnwrap(cleared.path).points.allSatisfy { abs($0.x) < 0.0001 })
    XCTAssertEqual(cleared.occupancyFilter?.confirmedCells, 0)
  }
  func testVetoConfirmationSupports210msProcessingCadence() {
    var filter = TemporalOccupancyGrid()
    _ = filter.apply(frame(1, 1, cells: box))
    _ = filter.apply(frame(2, 1.21, cells: box))
    XCTAssertEqual(filter.diagnostics.confirmedCells, 0)
    _ = filter.apply(frame(3, 1.42, cells: box))
    XCTAssertGreaterThan(filter.diagnostics.confirmedCells, 0)
  }
  func testVetoStillHonorsEpochTrackingAndExplicitStop() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let u = planner.update(result: frame(), observation: nil, options: .init())
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = false
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: u, candidate: u, gate: gate, hazardWatermark: 0, now: 1
      ).update.path)
    gate.trackingNormal = true
    gate.epoch = 2
    gate.frameID = 1
    gate.frameTimestamp = 1
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: u, candidate: u, gate: gate, hazardWatermark: 0, now: 1
      ).update.path)
    var options = PathOptions()
    options.enabled = false
    XCTAssertNil(planner.update(result: frame(2, 1.1), observation: nil, options: options).path)
  }
  func testBodyEvidenceDoesNotOverrideConfiguredVetoWidth() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    var r = frame(cells: { abs($0.x) < 0.301 ? .unknown : .obstacle })
    r.parameters.bodyWidth = 1.2
    r.parameters.sideMargin = 0.5
    for i in 0...3 {
      r.frameID = UInt64(i + 1)
      r.timestamp = 1 + Double(i) * 0.1
      r.grid?.frameID = r.frameID
      r.grid?.timestamp = r.timestamp
      let p = try XCTUnwrap(planner.update(result: r, observation: nil, options: .init()).path)
      XCTAssertEqual(p.requiredWidth, 0.5)
    }
  }
  func testLegacyOccupancyRecordAndOptionsStillDecode() throws {
    let json =
      #"{"thresholdSeconds":0.3,"pendingCells":1,"confirmedCells":0,"maximumAge":0.1,"policy":"experimental_occupancy_only"}"#
    XCTAssertNoThrow(
      try JSONDecoder().decode(OccupancyFilterDiagnostics.self, from: Data(json.utf8)))
    XCTAssertEqual(
      try JSONDecoder().decode(PathOptions.self, from: Data("{}".utf8)).forwardBufferLength, 8)
  }

  func testUnfinishedReplacementKeepsCommittedVetoUntilHazardOrReset() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let current = planner.update(result: frame(), observation: nil, options: .init())
    var pending = planner.update(result: frame(2, 1.1), observation: nil, options: .init())
    pending.path = nil
    pending.reason = "candidate_pending"
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 2
    gate.frameTimestamp = 1.1
    let kept = RoutePublicationPolicy.decide(
      current: current, candidate: pending, gate: gate, hazardWatermark: 0, now: 1.1,
      expectedPolicy: .obstacleVeto)
    XCTAssertFalse(kept.accepted)
    XCTAssertEqual(kept.reason, "candidate_not_ready")
    XCTAssertEqual(kept.update.path?.points, current.path?.points)
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: current, candidate: pending, gate: gate, hazardWatermark: 2, now: 1.1,
        expectedPolicy: .obstacleVeto
      ).update.path)
    gate.epoch = 2
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: current, candidate: pending, gate: gate, hazardWatermark: 0, now: 1.1,
        expectedPolicy: .obstacleVeto
      ).update.path)
  }

  func testConfirmedFullBlockCannotPublishAPathThroughIt() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    let before = planner.update(result: frame(), observation: nil, options: .init())
    var after = before
    var watermark: UInt64 = 0
    for i in 1...4 {
      after = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: { _ in .obstacle }),
        observation: nil, options: .init(),
        committedPath: before.path, onOccupancyConflict: { watermark = $0 })
    }
    XCTAssertEqual(watermark, 5)
    XCTAssertNil(after.path)
    var gate = ResultPresentationGate()
    gate.enabled = true
    gate.trackingNormal = true
    gate.epoch = 1
    gate.frameID = 5
    gate.frameTimestamp = 1.4
    XCTAssertNil(
      RoutePublicationPolicy.decide(
        current: before, candidate: after, gate: gate, hazardWatermark: watermark, now: 1.4,
        expectedPolicy: .obstacleVeto
      ).update.path)
  }

  func testBlockedCommittedDetourCanChangeSideInsteadOfWaitingForever() throws {
    var planner = PathPredictor(legacyContinuousOccupancy: true)
    var update = PathUpdate()
    for i in 0...3 {
      update = planner.update(
        result: frame(UInt64(i + 1), 1 + Double(i) * 0.1, cells: box), observation: nil,
        options: .init())
    }
    let firstSide = try XCTUnwrap(update.strategy?.side)
    XCTAssertNotEqual(firstSide, 0)
    for i in 4...7 {
      update = planner.update(
        result: frame(
          UInt64(i + 1), 1 + Double(i) * 0.1,
          cells: { p in
            if self.box(p) == .obstacle { return .obstacle }
            return Float(firstSide) * p.x > 0.1 && -p.z > 0.6 && -p.z < 1.5 ? .obstacle : .unknown
          }), observation: nil, options: .init())
    }
    XCTAssertNotNil(update.path)
    XCTAssertEqual(update.strategy?.side, -firstSide)
  }

}
