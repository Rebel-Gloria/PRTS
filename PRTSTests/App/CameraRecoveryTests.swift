import ARKit
import AVFoundation
import Combine
import SpatialCore
import SwiftUI
import Testing

@testable import PRTS

nonisolated final class TestProbeSession: ProbeSession, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var operations: [String] { lock.withLock { events } }

    func configure(delegate: any ARSessionDelegate, queue: DispatchQueue) {}
    func run(_ configuration: ARWorldTrackingConfiguration) {
        lock.withLock { events.append("run") }
    }
    func pause() { lock.withLock { events.append("pause") } }
}

nonisolated final class TestRGBCamera: RGBCapturing, @unchecked Sendable {
    let session = AVCaptureSession()
    private let lock = NSLock()
    private var isRunning = false
    private var events: [String] = []
    private var visibility: [Bool] = []
    var operations: [String] { lock.withLock { events } }
    var running: Bool { lock.withLock { isRunning } }
    var sceneVisibility: [Bool] { lock.withLock { visibility } }

    func setSceneActive(_ active: Bool) { lock.withLock { visibility.append(active) } }
    func setOrientation(_ orientation: ImageOrientation) {}
    func snapshot(orientation: ImageOrientation) -> CameraImageSnapshot? { nil }
    func start(completion: @escaping @Sendable (Bool) -> Void) {
        lock.withLock {
            isRunning = true
            events.append("start")
        }
        completion(true)
    }
    func stop(completion: @escaping @Sendable () -> Void) {
        lock.withLock {
            if isRunning { events.append("stop") }
            isRunning = false
        }
        completion()
    }
}

@Suite(.serialized)
@MainActor
struct CameraRecoveryTests {
    private final class TestFeedback: SpatialFeedback {
        var status = "test"
        private(set) var suspended: Bool?
        func tick(_ snapshot: SharedSnapshot, diagnostics: DiagnosticRecorder, suspended: Bool) {
            self.suspended = suspended
        }
        func reset() {}
    }

    private func makeCamera(
        session: TestProbeSession = TestProbeSession(),
        queue: DispatchQueue = DispatchQueue(label: "test.camera.session"),
        feedback: TestFeedback? = nil,
        hasDepth: Bool = false,
        permission: @escaping () async throws -> Bool = { true },
        isActive: @escaping () -> Bool = { true },
        authorization: AVAuthorizationStatus = .authorized,
        rgbCamera: any RGBCapturing = TestRGBCamera()
    ) -> CameraManager {
        CameraManager(
            model: ProbeViewModel(
                engine: ProbeEngine(
                    session: session,
                    capabilities: DeviceCapabilities(
                        world: true,
                        depth: hasDepth,
                        meshClassification: false,
                        smooth: false,
                        planeClassification: false
                    ),
                    sessionQueue: queue
                ),
                feedback: feedback ?? TestFeedback()
            ),
            permission: permission,
            isActive: isActive,
            authorizationStatus: { authorization },
            rgbCamera: rgbCamera
        )
    }

    @Test func onlyAnUndeterminedPermissionIsShownAsAPrompt() async {
        let first = makeCamera(authorization: .notDetermined)
        first.startCamera()
        #expect(first.state == .requestingPermission)
        await stop(first)

        let later = makeCamera()
        later.startCamera()
        #expect(later.state == .starting)
        await stop(later)
    }

    private func stop(_ camera: CameraManager) async {
        await withCheckedContinuation { done in camera.stopCamera { done.resume() } }
        #expect(!camera.model.engine.store.read().running)
    }

    // The fake session produces no ARFrames. Install a measured strip at a known
    // time so retaining survey coverage can be tested independently of live tracking.
    private let surveyPose = RigidPose(position: V3(0, 1.4, 0))

    private func recordMeasurement(_ camera: CameraManager, frameID: UInt64) {
        let plane = GroundPlane(normal: V3(0, 1, 0), offset: 0)
        let basis = GroundBasis(plane: plane, pose: surveyPose)!
        camera.model.engine.store.update {
            var grid = LocalGrid(
                basis: basis,
                parameters: $0.parameters,
                timestamp: Double(frameID),
                frameID: frameID,
                epoch: $0.epoch
            )
            for i in grid.cells.indices where abs(grid.center(i).x) < 0.7 {
                grid.cells[i] = GridCell(state: .candidate)
            }
            $0.waypointSurvey.record(
                grid,
                pose: surveyPose,
                retention: $0.pathOptions.retentionSeconds
            )
            $0.result = AnalysisResult(
                epoch: $0.epoch,
                frameID: frameID,
                timestamp: grid.timestamp,
                parameters: $0.parameters,
                parameterVersion: $0.parameterVersion,
                status: "synthetic"
            )
            $0.result?.grid = grid
        }
    }

    private func coversMeasuredStep(_ camera: CameraManager, at time: Double) -> Bool {
        let snapshot = camera.model.engine.store.read()
        return snapshot.waypointSurvey.coversStep(
            from: surveyPose,
            target: nil,
            options: snapshot.pathOptions,
            now: time
        )
    }

    @Test func feedbackOnlyPauseKeepsMeasurementsButDoesNotAuthorizeStaleOutput() async {
        let session = TestProbeSession()
        let feedback = TestFeedback()
        let camera = makeCamera(session: session, feedback: feedback, hasDepth: true)
        camera.startCamera()
        await camera.startTask?.value
        let epoch = camera.model.snapshot.epoch
        recordMeasurement(camera, frameID: 1)

        // Photo and Settings mute both channels. Live captions leave the camera's
        // haptic channel open; their speech gate belongs to the home screen.
        camera.poll(suspendFeedback: true)
        #expect(feedback.suspended == true)
        #expect(coversMeasuredStep(camera, at: 1))
        #expect(camera.model.snapshot.result?.frameID == 1)
        #expect(throws: PhotoChatError.emptyInput) {
            _ = try camera.capturePhoto(longestSide: 1280)
        }
        recordMeasurement(camera, frameID: 2)
        camera.poll(suspendFeedback: false)
        #expect(feedback.suspended == false)
        #expect(coversMeasuredStep(camera, at: 4))
        #expect(!coversMeasuredStep(camera, at: 4.01))
        #expect(camera.model.snapshot.result?.frameID == 2)
        #expect(camera.model.snapshot.epoch == epoch)
        #expect(camera.latestSceneResult == nil)
        #expect(throws: PhotoChatError.emptyInput) { _ = try camera.captureCaptionFrame() }
        #expect(session.operations == ["run"])
        await stop(camera)
    }

    @Test func backgroundWithoutSessionInterruptionDoesNotRestartMapping() async {
        let session = TestProbeSession()
        let camera = makeCamera(session: session, hasDepth: true)
        camera.startCamera()
        await camera.startTask?.value
        let epoch = camera.model.snapshot.epoch
        recordMeasurement(camera, frameID: 3)
        camera.lifecycle(.inactive)
        camera.lifecycle(.background)
        camera.poll(suspendFeedback: false)
        #expect(camera.model.feedbackSuspended)
        #expect(camera.latestSceneResult == nil)
        camera.lifecycle(.active)
        #expect(!camera.model.feedbackSuspended)
        #expect(coversMeasuredStep(camera, at: 3.1))
        #expect(camera.model.snapshot.result?.frameID == 3)
        #expect(camera.model.snapshot.epoch == epoch)
        #expect(session.operations == ["run"])
        await stop(camera)
    }

    @Test func explicitRestartCannotReuseMeasurementsFromBeforeStop() async {
        let session = TestProbeSession()
        let camera = makeCamera(session: session, hasDepth: true)
        camera.startCamera()
        await camera.startTask?.value
        let epoch = camera.model.snapshot.epoch
        recordMeasurement(camera, frameID: 4)
        #expect(coversMeasuredStep(camera, at: 4))
        await stop(camera)
        #expect(!coversMeasuredStep(camera, at: 4.1))
        #expect(camera.model.engine.store.read().result == nil)
        camera.lifecycle(.active)
        #expect(!camera.requestedRunning)
        #expect(camera.startTask == nil)
        camera.startCamera()
        await camera.startTask?.value
        #expect(camera.model.snapshot.epoch > epoch)
        #expect(camera.model.snapshot.result == nil)
        #expect(!camera.model.snapshot.geometryEnabled)
        #expect(camera.latestSceneResult == nil)
        #expect(session.operations == ["run", "pause", "run"])
        await stop(camera)
    }

    @Test func textCameraMayStartOnlyAfterGuidancePauseCompletes() async {
        let session = TestProbeSession()
        let queue = DispatchQueue(label: "test.camera.handoff")
        let camera = makeCamera(session: session, queue: queue, hasDepth: true)
        camera.startCamera()
        await camera.startTask?.value
        let epoch = camera.model.snapshot.epoch
        recordMeasurement(camera, frameID: 1)
        #expect(coversMeasuredStep(camera, at: 1))
        queue.suspend()
        await withCheckedContinuation { done in
            camera.pauseForTextReading {
                #expect(session.operations == ["run", "pause"])
                done.resume()
            }
            #expect(session.operations == ["run"])
            #expect(camera.suspendsFeedback)
            queue.resume()
        }
        #expect(camera.requestedRunning)
        #expect(!coversMeasuredStep(camera, at: 1.1))
        #expect(camera.model.engine.store.read().result == nil)
        camera.finishTextReading(isActive: true)
        await camera.startTask?.value
        #expect(session.operations == ["run", "pause", "run"])
        #expect(camera.model.snapshot.epoch > epoch)
        #expect(!camera.model.snapshot.geometryEnabled)
        await stop(camera)
    }

    @Test func textReadingResumesStartedGuidanceInForeground() async {
        let camera = makeCamera()
        camera.startCamera()
        await camera.startTask?.value
        #expect(camera.state == .running)
        await withCheckedContinuation { done in
            camera.pauseForTextReading { done.resume() }
        }
        #expect(camera.state == .idle)
        camera.finishTextReading(isActive: true)
        await camera.startTask?.value
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func interruptedTextReadingDefersRecoveryUntilForeground() async {
        let camera = makeCamera()
        camera.startCamera()
        await camera.startTask?.value
        await withCheckedContinuation { done in
            camera.pauseForTextReading { done.resume() }
        }
        camera.finishTextReading(isActive: false)
        camera.lifecycle(.inactive)
        #expect(camera.state == .idle)
        camera.lifecycle(.active)
        await camera.startTask?.value
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func foregroundDoesNotTakeCameraFromTextReading() async {
        let camera = makeCamera()
        camera.startCamera()
        await camera.startTask?.value
        await withCheckedContinuation { done in
            camera.pauseForTextReading { done.resume() }
        }
        camera.lifecycle(.active)
        #expect(camera.startTask == nil)
        #expect(camera.state == .idle)
        camera.finishTextReading(isActive: true)
        await camera.startTask?.value
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func explicitStopPreventsTextReadingRecovery() async {
        let camera = makeCamera()
        camera.startCamera()
        await camera.startTask?.value
        camera.pauseForTextReading()
        await stop(camera)
        camera.finishTextReading(isActive: true)
        camera.lifecycle(.active)
        #expect(camera.startTask == nil)
        #expect(camera.state == .idle)
    }

    @Test func readingFromIdleDoesNotStartGuidance() async {
        let camera = makeCamera()
        camera.pauseForTextReading()
        camera.finishTextReading(isActive: false)
        camera.lifecycle(.active)
        #expect(camera.startTask == nil)
        #expect(camera.state == .idle)
        await stop(camera)
    }

    @Test(arguments: ["stop", "text", "background"])
    func latePermissionDoesNotRestartCamera(action: String) async {
        let requested = TestSignal()
        var reply: (@Sendable (Bool) -> Void)?
        let session = TestProbeSession()
        let camera = makeCamera(
            session: session,
            permission: {
                try await CameraAuthorization.wait { callback in
                    reply = callback
                    Task { await requested.signal() }
                }
            }
        )
        camera.startCamera()
        let start = camera.startTask
        await requested.wait()
        switch action {
        case "stop": camera.stopCamera()
        case "text": camera.pauseForTextReading()
        default: camera.lifecycle(.inactive)
        }
        // Cancellation completes even while the system permission sheet is still open.
        await start?.value
        reply!(true)
        #expect(session.operations.allSatisfy { $0 == "pause" })
        #expect(!camera.model.requestingPermission)
        #expect(camera.state == .idle)
        await stop(camera)
    }

    @Test func stopBeforeAuthorizationTaskRunsDoesNotRequestPermission() async {
        let camera = makeCamera(permission: {
            Issue.record("A stopped start must not request authorization")
            return true
        })
        camera.startCamera()
        let start = camera.startTask
        camera.stopCamera()
        await start?.value
        await stop(camera)
    }

    @Test func oldPermissionDoesNotClearNewStart() async {
        var callbacks: [@Sendable (Bool) -> Void] = []
        let first = TestSignal()
        let second = TestSignal()
        let camera = makeCamera(permission: {
            try await CameraAuthorization.wait { callback in
                callbacks.append(callback)
                let signal = callbacks.count == 1 ? first : second
                Task { await signal.signal() }
            }
        })
        camera.startCamera()
        let oldStart = camera.startTask
        await first.wait()
        camera.stopCamera()
        camera.startCamera()
        await second.wait()
        await oldStart?.value
        callbacks[0](true)
        #expect(camera.model.requestingPermission)
        callbacks[1](true)
        await camera.startTask?.value
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func permissionRecoveryAfterFocusReturnsDoesNotLeaveAStartPending() async {
        var callbacks: [@Sendable (Bool) -> Void] = []
        let first = TestSignal()
        let second = TestSignal()
        let session = TestProbeSession()
        let camera = makeCamera(
            session: session,
            permission: {
                try await CameraAuthorization.wait { callback in
                    callbacks.append(callback)
                    let signal = callbacks.count == 1 ? first : second
                    Task { await signal.signal() }
                }
            }
        )
        camera.startCamera()
        let oldStart = camera.startTask
        await first.wait()
        camera.lifecycle(.inactive)
        await oldStart?.value
        #expect(camera.startTask == nil)
        camera.lifecycle(.active)
        await second.wait()
        callbacks[0](true)
        #expect(camera.model.requestingPermission)
        callbacks[1](true)
        await camera.startTask?.value
        #expect(camera.state == .running)
        #expect(session.operations == ["run"])
        await stop(camera)
    }

    @Test func inactiveApplicationDoesNotStartUntilActiveEvent() async {
        var active = false
        let session = TestProbeSession()
        let camera = makeCamera(session: session, isActive: { active })
        camera.startCamera()
        await camera.startTask?.value
        #expect(session.operations.isEmpty)
        active = true
        camera.lifecycle(.active)
        await camera.startTask?.value
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func losingFocusAndReturningKeepsTheSameSession() async {
        let queue = DispatchQueue(label: "test.camera.foreground")
        let session = TestProbeSession()
        let rgb = TestRGBCamera()
        let camera = makeCamera(session: session, queue: queue, rgbCamera: rgb)
        camera.startCamera()
        await camera.startTask?.value
        queue.suspend()
        camera.lifecycle(.inactive)
        #expect(camera.suspendsFeedback)
        #expect(camera.model.feedbackSuspended)
        #expect(camera.state == .running)
        let epoch = camera.model.snapshot.epoch
        camera.lifecycle(.active)
        #expect(camera.startTask == nil)
        queue.resume()
        #expect(session.operations == ["run"])
        #expect(rgb.sceneVisibility == [true, false, true])
        #expect(camera.model.snapshot.epoch == epoch)
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func lowVisionReleasesSpatialCaptureAndKeepsOnlyRGB() async {
        let session = TestProbeSession()
        let rgb = TestRGBCamera()
        let camera = makeCamera(session: session, hasDepth: true, rgbCamera: rgb)
        camera.startCamera()
        await camera.startTask?.value
        let epoch = camera.model.snapshot.epoch
        recordMeasurement(camera, frameID: 1)
        #expect(coversMeasuredStep(camera, at: 1))
        await withCheckedContinuation { done in
            camera.setLowVisionMode(true) { done.resume() }
        }
        await camera.startTask?.value
        #expect(session.operations == ["run", "pause"])
        #expect(camera.requestedRunning)
        #expect(!coversMeasuredStep(camera, at: 1.1))
        #expect(camera.model.snapshot.result == nil)
        #expect(rgb.operations == ["start"])
        #expect(!camera.model.engine.store.read().running)
        #expect(camera.state == .running)
        camera.lifecycle(.inactive)
        camera.lifecycle(.active)
        #expect(rgb.operations == ["start"])
        #expect(session.operations == ["run", "pause"])
        await withCheckedContinuation { done in
            camera.setLowVisionMode(false) { done.resume() }
        }
        await camera.startTask?.value
        #expect(rgb.operations == ["start", "stop"])
        #expect(session.operations.last == "run")
        #expect(camera.model.engine.store.read().running)
        #expect(camera.model.snapshot.epoch > epoch)
        #expect(!camera.model.snapshot.geometryEnabled)
        await stop(camera)
    }

    @Test func startDuringLowVisionHandoffWaitsForTheCameraRelease() async {
        let queue = DispatchQueue(label: "test.camera.lowvision")
        let session = TestProbeSession()
        let rgb = TestRGBCamera()
        let camera = makeCamera(session: session, queue: queue, rgbCamera: rgb)
        queue.suspend()
        let ready = TestSignal()
        camera.setLowVisionMode(true) { Task { await ready.signal() } }
        camera.startCamera()
        #expect(camera.startTask == nil)
        #expect(rgb.operations.isEmpty)
        queue.resume()
        await ready.wait()
        await camera.startTask?.value
        #expect(rgb.operations == ["start"])
        #expect(session.operations == ["pause"])
        await stop(camera)
    }

    @Test func cancellingTextReadingDuringRGBReleaseResumesAfterTheRelease() async {
        let queue = DispatchQueue(label: "test.camera.rgb.cancel")
        let rgb = TestRGBCamera()
        let camera = makeCamera(queue: queue, rgbCamera: rgb)
        await withCheckedContinuation { done in
            camera.setLowVisionMode(true) { done.resume() }
        }
        camera.startCamera()
        await camera.startTask?.value
        queue.suspend()
        let released = TestSignal()
        camera.pauseForTextReading { Task { await released.signal() } }
        camera.finishTextReading(isActive: true)
        #expect(camera.startTask == nil)
        #expect(rgb.operations == ["start"])
        queue.resume()
        await released.wait()
        await camera.startTask?.value
        #expect(rgb.operations == ["start", "stop", "start"])
        #expect(camera.state == .running)
        await stop(camera)
    }

    @Test func systemInterruptionRetainsSessionAndWaitsForFreshEvidence() async {
        let queue = DispatchQueue(label: "test.camera.interruption")
        let session = TestProbeSession()
        let camera = makeCamera(session: session, queue: queue, hasDepth: true)
        camera.startCamera()
        await camera.startTask?.value
        let engine = camera.model.engine
        let epoch = engine.store.read().epoch
        recordMeasurement(camera, frameID: 1)
        #expect(coversMeasuredStep(camera, at: 1))
        await withCheckedContinuation { done in
            queue.async {
                engine.sessionWasInterrupted(ARSession())
                done.resume()
            }
        }
        let interrupted = engine.store.read()
        #expect(interrupted.running)
        #expect(!coversMeasuredStep(camera, at: 1.1))
        #expect(interrupted.interrupted)
        #expect(interrupted.epoch > epoch)
        #expect(!interrupted.geometryEnabled)
        #expect(interrupted.frame == nil)
        #expect(interrupted.result == nil)
        #expect(session.operations == ["run"])
        await withCheckedContinuation { done in
            queue.async {
                engine.sessionInterruptionEnded(ARSession())
                done.resume()
            }
        }
        let resumed = engine.store.read()
        #expect(!resumed.interrupted)
        #expect(resumed.epoch == interrupted.epoch)
        #expect(resumed.result == nil)
        #expect(!resumed.geometryEnabled)
        #expect(resumed.frame == nil)
        #expect(session.operations == ["run"])
        await stop(camera)
    }

    @Test func explicitStopSuspendsFeedbackBeforeQueueCompletes() async {
        let queue = DispatchQueue(label: "test.camera.stop")
        let camera = makeCamera(queue: queue)
        camera.startCamera()
        await camera.startTask?.value
        queue.suspend()
        camera.stopCamera()
        camera.poll(suspendFeedback: false)
        #expect(camera.model.engine.store.read().running)
        #expect(camera.suspendsFeedback)
        #expect(camera.model.feedbackSuspended)
        #expect(camera.latestSceneResult == nil)
        #expect(camera.state == .idle)
        queue.resume()
        await stop(camera)
    }

    @Test func queuedStartThenStopCommitsInSessionOrder() async {
        let queue = DispatchQueue(label: "test.probe.session")
        let session = TestProbeSession()
        let engine = ProbeEngine(
            session: session,
            capabilities: DeviceCapabilities(
                world: true,
                depth: false,
                meshClassification: false,
                smooth: false,
                planeClassification: false
            ),
            sessionQueue: queue
        )
        queue.suspend()
        engine.start(device: [:])
        await withCheckedContinuation { done in
            engine.stop { done.resume() }
            #expect(session.operations.isEmpty)
            queue.resume()
        }
        #expect(session.operations == ["run", "pause"])
        #expect(!engine.store.read().running)
        await withCheckedContinuation { done in engine.start(device: [:]) { done.resume() } }
        #expect(engine.store.read().running)
        #expect(session.operations == ["run", "pause", "run"])
        await withCheckedContinuation { done in engine.stop { done.resume() } }
    }

    @Test func unchangedPollsDoNotRedrawTheHomeScreen() {
        let camera = makeCamera()
        camera.poll(suspendFeedback: true)
        var changes = 0
        let observation = camera.objectWillChange.sink { _ in changes += 1 }
        camera.poll(suspendFeedback: true)
        camera.poll(suspendFeedback: true)
        #expect(changes == 0)
        // The home screen reads the operation message from the model without observing it.
        camera.model.permissionMessage = "camera.permission.denied"
        camera.poll(suspendFeedback: true)
        #expect(changes == 1)
        withExtendedLifetime(observation) {}
    }

    @Test func scanMeshPublishesOneCompleteConfiguration() {
        let model = makeCamera().model
        let saved = UserDefaults.standard.object(forKey: ProbeViewModel.scanMeshKey)
        defer {
            UserDefaults.standard.set(saved, forKey: ProbeViewModel.scanMeshKey)
        }
        var updates: [(Bool, Bool)] = []
        let observation = model.$options.dropFirst().sink {
            updates.append(($0.showMesh, $0.showPath))
        }
        let enabled = !model.scanMesh
        model.scanMesh = enabled
        #expect(updates.count == 1)
        #expect(updates[0].0 == enabled)
        #expect(!updates[0].1)
        withExtendedLifetime(observation) {}
    }
}

@MainActor
struct CameraHardwareTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRTS_CAMERA_HARDWARE_TESTS"] == "1"))
    func authorizedForegroundSessionCompletesStartAndStop() async throws {
        try #require(
            AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
            "Start stage: camera authorization"
        )
        try #require(
            UIApplication.shared.applicationState == .active,
            "Start stage: host application foreground"
        )
        let camera = CameraManager()
        camera.startCamera()
        await camera.startTask?.value
        let started = camera.model.engine.store.read()
        await withCheckedContinuation { done in camera.stopCamera { done.resume() } }
        #expect(started.running, "Start stage: session completion; status: \(started.status)")
        #expect(!camera.model.engine.store.read().running)
    }
}
