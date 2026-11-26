import ARKit
import SwiftUI
import XCTest
import simd

@testable import PRTS
@testable import SpatialCore

// ARKit supplies these objects only during capture. These test doubles expose just the
// Objective-C getters read by FrameSnapshot and poll, without starting an ARSession.
// Keep the cast dynamic: Release can otherwise fold a cast between concrete classes
// to nil without asking the stand-in's isKind(of:).
@inline(never)
private func resolveStub<T: NSObject>(_ object: AnyObject, as type: T.Type) throws -> T {
    try XCTUnwrap(object as? T)
}

private final class TrackedCameraStub: NSObject {
    @objc var transform: simd_float4x4 {
        var transform = matrix_identity_float4x4
        transform.columns.3.y = 1.4
        return transform
    }
    @objc let intrinsics = matrix_identity_float3x3
    @objc let imageResolution = CGSize(width: 2, height: 2)
    @objc var trackingState: __ARTrackingState { .normal }
    @objc var trackingStateReason: __ARTrackingStateReason { .none }

    override func isKind(of aClass: AnyClass) -> Bool {
        aClass === ARCamera.self || super.isKind(of: aClass)
    }
}

private final class TrackedFrameStub: NSObject {
    @objc let camera: ARCamera
    @objc let timestamp: TimeInterval

    init(camera: ARCamera, timestamp: TimeInterval) {
        self.camera = camera
        self.timestamp = timestamp
    }

    override func isKind(of aClass: AnyClass) -> Bool {
        aClass === ARFrame.self || super.isKind(of: aClass)
    }
}

@MainActor
private final class PollFeedbackSpy: SpatialFeedback {
    enum Event: Equatable {
        case tick(goal: UInt64?, suspended: Bool)
        case reset
    }
    let status = "test"
    private(set) var events: [Event] = []

    func tick(_ snapshot: SharedSnapshot, diagnostics: DiagnosticRecorder, suspended: Bool) {
        events.append(.tick(goal: snapshot.pathUpdate.goal?.id, suspended: suspended))
    }

    func reset() { events.append(.reset) }
}

@MainActor
private final class WaypointPollFixture {
    let model: ProbeViewModel
    let feedback = PollFeedbackSpy()
    private let camera: ARCamera
    private var liveFrameID: UInt64 = 0

    init(hasNativeDepth: Bool = true) throws {
        camera = try resolveStub(TrackedCameraStub(), as: ARCamera.self)
        let engine = ProbeEngine(
            session: TestProbeSession(),
            capabilities: DeviceCapabilities(
                world: true,
                depth: hasNativeDepth,
                meshClassification: false,
                smooth: false,
                planeClassification: false
            )
        )
        model = ProbeViewModel(engine: engine, feedback: feedback)
        model.poll()  // Handle the initial thermal/heartbeat update before timing any observation.
        model.engine.store.update {
            $0.running = true
            $0.geometryEnabled = true
            $0.epoch = 1
            $0.pathOptions.retentionSeconds = 5
        }
    }

    private func analysis(
        _ evidence: GroundFeedbackEvidence,
        frameID: UInt64,
        at time: TimeInterval,
        pose: RigidPose
    ) -> AnalysisResult {
        let snapshot = model.engine.store.read()
        var result = AnalysisResult(
            epoch: snapshot.epoch,
            frameID: frameID,
            timestamp: time,
            parameters: snapshot.parameters,
            parameterVersion: snapshot.parameterVersion,
            status: "synthetic"
        )
        result.sourcePose = pose
        result.sourceDirectionStable = true
        result.groundFeedbackEvidence = evidence
        return result
    }

    func publish(goal id: UInt64, observation: UInt64, age: TimeInterval = 0) throws {
        let measuredAt = ProcessInfo.processInfo.systemUptime - age
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0)
        let target = V3(id == 1 ? -0.6 : 0.6, 0, -1.5)
        let path = PredictedPath(
            id: id,
            epoch: 1,
            parameterVersion: 0,
            sourceFrameID: observation,
            validatedFrameID: observation,
            observedAt: measuredAt,
            plane: plane,
            points: [.zero, target],
            source: "synthetic",
            requiredWidth: 0.5,
            planningPolicy: .obstacleVeto
        )
        var update = PathUpdate(path: path, reason: "synthetic")
        update.goal = FixedPathGoal(
            id: id,
            epoch: 1,
            point: target,
            plane: plane,
            selectedAt: measuredAt,
            maxDistance: 4
        )
        update.waypointGuidance = ObstacleWaypointGuidance(
            scenario: .nearObstacle,
            obstacleDistance: 1.2,
            referenceForward: V3(0, 0, -1)
        )
        update.continuity = RouteContext(
            planningPolicy: RoutePlanningPolicy.obstacleVeto.rawValue,
            epoch: 1,
            parameterVersion: 0,
            frameID: observation,
            timestamp: measuredAt,
            requestID: observation,
            sourceMapVersion: observation,
            hazardWatermark: 0,
            routeID: id,
            geometryVersion: id,
            status: .planned,
            remainingVerifiedLength: 0,
            renewalDistance: 1.2,
            requiredWidth: path.requiredWidth
        )

        // A prior camera position saw the ground under the current feet and both turns.
        // Date the survey with the route, not the live pose, so an aged route is still drawable.
        let priorPose = RigidPose(position: V3(0, 1.4, 0.5))
        var grid = LocalGrid(
            basis: try XCTUnwrap(GroundBasis(plane: plane, pose: priorPose)),
            parameters: model.parameters,
            timestamp: measuredAt,
            frameID: observation,
            epoch: 1
        )
        grid.cells = Array(repeating: GridCell(state: .candidate), count: grid.cells.count)
        var result = analysis(.mapped, frameID: observation, at: measuredAt, pose: priorPose)
        result.plane = plane
        result.grid = grid
        liveFrameID = max(liveFrameID, observation)
        model.engine.store.update {
            $0.waypointSurvey = WaypointSurvey()
            $0.waypointSurvey.record(
                grid,
                pose: priorPose,
                retention: $0.pathOptions.retentionSeconds
            )
            $0.result = result
            $0.pathUpdate = update
        }
    }

    // Analysis may publish a veto while the last measured route and survey are still retained.
    func observeWithoutNewRoute(_ evidence: GroundFeedbackEvidence) {
        liveFrameID += 1
        let result = analysis(
            evidence,
            frameID: liveFrameID,
            at: ProcessInfo.processInfo.systemUptime,
            pose: RigidPose(camera.transform)
        )
        model.engine.store.update { $0.result = result }
    }

    func markObstacleRetained() {
        model.engine.store.update {
            let measuredAt = $0.pathUpdate.continuity?.timestamp
            $0.pathUpdate.waypointGuidance?.retainedObstacleAt = measuredAt
        }
    }

    @discardableResult
    func expectTick(
        goal: UInt64,
        suspended: Bool,
        replayOf measurement: RouteContext? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        action: (() -> Void)? = nil
    ) throws -> GroundFeedbackEvidence? {
        // Only the tracking frame advances between polls, not the published observation.
        liveFrameID += 1
        let now = ProcessInfo.processInfo.systemUptime
        let stub = TrackedFrameStub(camera: camera, timestamp: now)
        let frame = FrameSnapshot(
            frame: try resolveStub(stub, as: ARFrame.self),
            epoch: 1,
            id: liveFrameID,
            receivedAt: now,
            directionStable: true,
            parameters: model.parameters,
            parameterVersion: 0,
            usesMonocular: model.engine.store.read().usesMonocular
        )
        model.engine.store.update { $0.frame = frame }
        let start = feedback.events.endIndex
        (action ?? model.poll)()
        if let measurement {
            let snapshot = model.snapshot
            let current = try XCTUnwrap(snapshot.pathUpdate.continuity, file: file, line: line)
            XCTAssertEqual(current.frameID, measurement.frameID, file: file, line: line)
            XCTAssertEqual(current.timestamp, measurement.timestamp, file: file, line: line)
            XCTAssertLessThan(
                ProcessInfo.processInfo.systemUptime - current.timestamp,
                snapshot.parameters.maxResultAge,
                "This replay must not pass just because the measurement expired.",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            Array(feedback.events[start...]),
            [.tick(goal: goal, suspended: suspended)],
            file: file,
            line: line
        )
        let evidence = model.snapshot.feedbackEvidence(now: now)
        let path = try XCTUnwrap(model.snapshot.pathUpdate.path, file: file, line: line)
        XCTAssertNotNil(
            PathTracking.heading(
                path: path,
                pose: frame.pose,
                lookAhead: model.snapshot.pathOptions.lookAhead
            ),
            "The underlying route still has a geometric heading.",
            file: file,
            line: line
        )
        if evidence == .unmapped || evidence == .fullFieldObstacle {
            XCTAssertNil(model.snapshot.pathHeading(now: now), file: file, line: line)
        } else {
            XCTAssertNotNil(model.snapshot.pathHeading(now: now), file: file, line: line)
        }
        return evidence
    }
}

final class ProbeHapticPollTests: XCTestCase {
    @MainActor func testMonocularRouteRemainsVisualOnlyAfterGeometryExpiresOrDisappears() throws {
        let fixture = try WaypointPollFixture(hasNativeDepth: false)
        try fixture.publish(goal: 1, observation: 1, age: 2)
        for missing in [false, true] {
            if missing { fixture.model.engine.store.update { $0.result = nil } }
            let evidence = try fixture.expectTick(goal: 1, suspended: true)
            let snapshot = fixture.model.snapshot
            let now = try XCTUnwrap(snapshot.frame).frame.timestamp
            XCTAssertNil(snapshot.activeGeometryResult(now: now))
            XCTAssertNotNil(snapshot.activePath(now: now))
            XCTAssertEqual(evidence, .unmapped)
            XCTAssertNil(snapshot.pathHeading(now: now))
        }
    }

    @MainActor func testHistoryOnlyContinuesAnOngoingSegment() throws {
        let fixture = try WaypointPollFixture()
        // Two seconds is well outside the 250 ms freshness window but inside the 5 s survey.
        try fixture.publish(goal: 1, observation: 1, age: 2)
        XCTAssertNil(try fixture.expectTick(goal: 1, suspended: true))
        try fixture.publish(goal: 1, observation: 2)
        XCTAssertEqual(try fixture.expectTick(goal: 1, suspended: false), .mapped)
        fixture.model.engine.store.update { $0.result = nil }
        XCTAssertNil(try fixture.expectTick(goal: 1, suspended: false))
        // Age the same observation relative to uptime rather than waiting for it to expire.
        try fixture.publish(goal: 1, observation: 2, age: 2)
        XCTAssertNil(try fixture.expectTick(goal: 1, suspended: false))
        try fixture.publish(goal: 2, observation: 3, age: 2)
        try fixture.expectTick(goal: 2, suspended: true)
        try fixture.expectTick(goal: 2, suspended: true)
        try fixture.publish(goal: 2, observation: 4)
        // Even a fresh route frame cannot start a different direction without a mapped result.
        fixture.model.engine.store.update { $0.result = nil }
        XCTAssertNil(try fixture.expectTick(goal: 2, suspended: true))
        try fixture.publish(goal: 2, observation: 5)
        XCTAssertEqual(try fixture.expectTick(goal: 2, suspended: false), .mapped)
    }

    @MainActor func testUnmappedGroundStopsOngoingDirectionFeedback() throws {
        try checkVetoAndRecovery(.unmapped)
    }

    @MainActor func testFullFieldObstacleStopsOngoingDirectionFeedback() throws {
        try checkVetoAndRecovery(.fullFieldObstacle)
    }

    @MainActor private func checkVetoAndRecovery(_ veto: GroundFeedbackEvidence) throws {
        let fixture = try WaypointPollFixture()
        try fixture.publish(goal: 1, observation: 10)
        XCTAssertEqual(try fixture.expectTick(goal: 1, suspended: false), .mapped)
        let route = fixture.model.snapshot.pathUpdate
        let original = try XCTUnwrap(route.continuity)

        fixture.observeWithoutNewRoute(veto)
        XCTAssertEqual(try fixture.expectTick(goal: 1, suspended: true, replayOf: original), veto)
        fixture.model.engine.store.update { $0.result = nil }
        XCTAssertNil(try fixture.expectTick(goal: 1, suspended: true, replayOf: original))

        // Deliver the new mapped analysis first; it cannot re-arm the route muted by the veto.
        try fixture.publish(goal: 1, observation: 20)
        let nextRoute = fixture.model.engine.store.read().pathUpdate
        fixture.model.engine.store.update { $0.pathUpdate = route }
        XCTAssertEqual(
            try fixture.expectTick(goal: 1, suspended: true, replayOf: original),
            .mapped
        )
        fixture.model.engine.store.update { $0.pathUpdate = nextRoute }
        XCTAssertEqual(try fixture.expectTick(goal: 1, suspended: false), .mapped)
    }

    @MainActor func testFocusLossAndFeedbackPauseBreakSameGoalContinuity() throws {
        let fixture = try WaypointPollFixture()
        try fixture.publish(goal: 1, observation: 1)
        try fixture.expectTick(goal: 1, suspended: false)
        fixture.markObstacleRetained()
        try fixture.expectTick(goal: 1, suspended: false)

        // No muted poll between scene phases: losing focus must itself forget the ongoing goal.
        fixture.model.lifecycle(.inactive)
        XCTAssertEqual(fixture.feedback.events.last, .reset)
        try fixture.expectTick(goal: 1, suspended: true) { fixture.model.lifecycle(.active) }
        try fixture.publish(goal: 1, observation: 2)
        try fixture.expectTick(goal: 1, suspended: false)

        // No scene change here: the suspended poll alone must end continuity.
        fixture.model.feedbackSuspended = true
        try fixture.expectTick(goal: 1, suspended: true)
        fixture.model.feedbackSuspended = false
        fixture.markObstacleRetained()
        try fixture.expectTick(goal: 1, suspended: true)
        try fixture.expectTick(goal: 1, suspended: true)
        try fixture.publish(goal: 1, observation: 3)
        try fixture.expectTick(goal: 1, suspended: false)
    }

    @MainActor func testReplayingAnUnexpiredMeasurementDoesNotRestartFeedback() throws {
        let fixture = try WaypointPollFixture()
        try fixture.publish(goal: 1, observation: 1)
        try fixture.expectTick(goal: 1, suspended: false)
        let original = fixture.model.snapshot.pathUpdate
        let beforeFocusLoss = try XCTUnwrap(original.continuity)
        fixture.model.lifecycle(.inactive)
        // A second non-active callback can see an empty route before the last result returns.
        fixture.model.engine.store.update { $0.pathUpdate.continuity = nil }
        fixture.model.lifecycle(.inactive)
        fixture.model.engine.store.update { $0.pathUpdate = original }
        // New pose, identical measurement ID and timestamp, still inside maxResultAge.
        try fixture.expectTick(goal: 1, suspended: true, replayOf: beforeFocusLoss) {
            fixture.model.lifecycle(.active)
        }
        try fixture.publish(goal: 1, observation: 2)
        try fixture.expectTick(goal: 1, suspended: false)

        let beforePause = try XCTUnwrap(fixture.model.snapshot.pathUpdate.continuity)
        fixture.model.feedbackSuspended = true
        try fixture.expectTick(goal: 1, suspended: true)
        fixture.model.feedbackSuspended = false
        try fixture.expectTick(goal: 1, suspended: true, replayOf: beforePause)
        try fixture.publish(goal: 1, observation: 3)
        try fixture.expectTick(goal: 1, suspended: false)
    }
}
