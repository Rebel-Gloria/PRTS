import ARKit
import AVFoundation
import Combine
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

@Suite(.serialized)
@MainActor
struct CameraRecoveryTests {
    private final class TestFeedback: SpatialFeedback {
        var status = "test"
        func tick(_ snapshot: SharedSnapshot, diagnostics: DiagnosticRecorder, suspended: Bool) {}
        func reset() {}
    }

    private func makeCamera(
        session: TestProbeSession = TestProbeSession(),
        queue: DispatchQueue = DispatchQueue(label: "test.camera.session"),
        permission: @escaping () async throws -> Bool = { true },
        isActive: @escaping () -> Bool = { true }
    ) -> CameraManager {
        CameraManager(
            model: ProbeViewModel(
                engine: ProbeEngine(
                    session: session,
                    capabilities: DeviceCapabilities(
                        world: true,
                        depth: false,
                        meshClassification: false,
                        smooth: false,
                        planeClassification: false
                    ),
                    sessionQueue: queue
                ),
                feedback: TestFeedback()
            ),
            permission: permission,
            isActive: isActive,
            authorizationStatus: { .authorized }
        )
    }

    private func stop(_ camera: CameraManager) async {
        await withCheckedContinuation { done in camera.stopCamera { done.resume() } }
        #expect(!camera.model.engine.store.read().running)
    }

    @Test func textCameraMayStartOnlyAfterGuidancePauseCompletes() async {
        let session = TestProbeSession()
        let queue = DispatchQueue(label: "test.camera.handoff")
        let camera = makeCamera(session: session, queue: queue)
        camera.startCamera()
        await camera.startTask?.value
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
        camera.finishTextReading(isActive: true)
        await camera.startTask?.value
        #expect(session.operations == ["run", "pause", "run"])
        await stop(camera)
    }

    @Test func textReadingResumesStartedGuidanceInForeground() async {
        let camera = makeCamera()
        camera.startCamera()
        await camera.startTask?.value
        #expect(camera.state == .running)
        camera.pauseForTextReading()
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
        camera.pauseForTextReading()
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
        camera.pauseForTextReading()
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

    @Test func foregroundBeforeQueuedPauseCompletesStillRestarts() async {
        let queue = DispatchQueue(label: "test.camera.foreground")
        let session = TestProbeSession()
        let camera = makeCamera(session: session, queue: queue)
        camera.startCamera()
        await camera.startTask?.value
        queue.suspend()
        camera.lifecycle(.inactive)
        #expect(camera.suspendsFeedback)
        #expect(camera.state == .idle)
        camera.lifecycle(.active)
        let start = camera.startTask
        #expect(start != nil)
        queue.resume()
        await start?.value
        #expect(session.operations == ["run", "pause", "run"])
        #expect(camera.state == .running)
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

    #if PRTS_DEV_CAPTURE
    @Test func queuedRecordingStartCannotOutliveAudioInterruption() async throws {
        let queue = DispatchQueue(label: "test.recording.interruption")
        let camera = makeCamera(queue: queue)
        let store = RecordingStore.application
        let previous = Set(try store.list().map(\.id))
        camera.startCamera()
        await camera.startTask?.value
        queue.suspend()
        camera.model.recordingMode = true
        camera.model.recordingAudioInterrupted()
        queue.resume()
        await withCheckedContinuation { done in
            camera.model.engine.flushDiagnostics(lifecycle: "test") { done.resume() }
        }
        #expect(camera.model.engine.recording.status().phase == .saved)
        await stop(camera)
        for recording in try store.list() where !previous.contains(recording.id) {
            try store.delete(recording)
        }
    }

    @Test(arguments: ["user", "text", "inactive", "background", "audio", "session"])
    func recordingEndsAtEveryCameraHandoff(reason: String) async throws {
        let camera = makeCamera()
        let store = RecordingStore.application
        let previous = Set(try store.list().map(\.id))
        camera.model.recordingMode = true
        camera.startCamera()
        await camera.startTask?.value
        #expect(camera.model.engine.recording.status().phase == .recording)
        switch reason {
        case "user": camera.stopCamera()
        case "text": camera.pauseForTextReading()
        case "inactive": camera.lifecycle(.inactive)
        case "background": camera.lifecycle(.background)
        case "audio": camera.model.recordingAudioInterrupted()
        default: camera.model.engine.stop(reason: "会话中断")
        }
        await withCheckedContinuation { done in
            camera.model.engine.flushDiagnostics(lifecycle: "test") { done.resume() }
        }
        #expect(camera.model.engine.recording.status().phase == .saved)
        await stop(camera)
        for recording in try store.list() where !previous.contains(recording.id) {
            try store.delete(recording)
        }
    }
    #endif

    @Test func scanMeshPublishesOneCompleteConfiguration() {
        let model = makeCamera().model
        let saved = UserDefaults.standard.object(forKey: ProbeViewModel.scanMeshKey)
        defer { UserDefaults.standard.set(saved, forKey: ProbeViewModel.scanMeshKey) }
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
