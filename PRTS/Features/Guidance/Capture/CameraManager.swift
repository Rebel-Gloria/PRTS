import AVFoundation
import Combine
import SpatialCore
import SwiftUI

/// Maintains guidance camera intent and UI state, coordinating pause/resume for text reading.
/// ProbeEngine owns the AR session; TextCamera uses its own capture session for text reading.
@MainActor
final class CameraManager: ObservableObject {
    let model: ProbeViewModel
    private let permission: () async throws -> Bool
    private let isActive: () -> Bool
    private let authorizationStatus: () -> AVAuthorizationStatus
    private(set) var startTask: Task<Void, Never>?

    // Default arguments are evaluated outside the main actor, so the app uses this initializer.
    convenience init() {
        self.init(
            model: ProbeViewModel(),
            permission: { try await CameraAuthorization.request() },
            isActive: { UIApplication.shared.applicationState == .active },
            authorizationStatus: { AVCaptureDevice.authorizationStatus(for: .video) }
        )
    }

    init(
        model: ProbeViewModel,
        permission: @escaping () async throws -> Bool,
        isActive: @escaping () -> Bool,
        authorizationStatus: @escaping () -> AVAuthorizationStatus
    ) {
        self.model = model
        self.permission = permission
        self.isActive = isActive
        self.authorizationStatus = authorizationStatus
    }
    private var wantsCameraRunning = false
    private var pausedForTextReading = false
    private var sceneActive = true
    private var sessionRequested = false
    var suspendsFeedback: Bool { !wantsCameraRunning || pausedForTextReading || !sceneActive }
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var status = "离线空间感知待启动"
    @Published private(set) var latestSceneResult: SceneResult?
    func poll(suspendFeedback: Bool) {
        let runningIntent = sessionRequested && !suspendsFeedback && isActive()
        model.feedbackSuspended = suspendFeedback || !runningIntent
        model.poll()
        status = model.snapshot.status
        latestSceneResult =
            runningIntent
            ? SceneSnapshotAdapter.measuredResult(
                model.snapshot,
                now: ProcessInfo.processInfo.systemUptime
            ) : nil
        if !model.snapshot.running && startTask == nil { sessionRequested = false }
        let authorization = authorizationStatus()
        if model.snapshot.running && runningIntent {
            state = .running
        } else if model.requestingPermission {
            state = .requestingPermission
        } else if authorization == .denied || authorization == .restricted {
            state = .permissionDenied
        } else if !model.capabilities.world {
            state = .unavailable(.noRearCamera)
        } else {
            state = .idle
        }
    }
    func startCamera() {
        wantsCameraRunning = true
        resumeCameraIfNeeded()
    }
    private func resumeCameraIfNeeded() {
        guard wantsCameraRunning, !pausedForTextReading, sceneActive else { return }
        guard !sessionRequested else { return }
        sessionRequested = true
        model.requestingPermission = true
        model.engine.diagnostics.event(
            "camera_start_requested",
            details: "user_action",
            epoch: model.snapshot.epoch
        )
        startTask = Task {
            do {
                try Task.checkCancellation()
                let allowed = model.capabilities.world ? try await permission() : true
                try Task.checkCancellation()
                model.requestingPermission = false
                await model.start(allowed: allowed, isActive: sceneActive && isActive())
                try Task.checkCancellation()
                startTask = nil
                poll(suspendFeedback: true)
            } catch is CancellationError {
                // The cancelling operation owns the next camera state.
            } catch {
                ErrorLog.application.record(error, source: .camera)
                startTask = nil
                model.requestingPermission = false
                model.errorMessage = error.localizedDescription
                poll(suspendFeedback: true)
            }
        }
        poll(suspendFeedback: true)
    }
    func stopCamera(completion: @escaping @Sendable () -> Void = {}) {
        wantsCameraRunning = false
        pauseCamera(completion: completion)
    }
    /// OCR temporarily owns the camera without changing the user's guidance intent.
    func pauseForTextReading() {
        pausedForTextReading = true
        pauseCamera()
    }
    func finishTextReading(isActive: Bool) {
        pausedForTextReading = false
        if isActive { resumeCameraIfNeeded() }
    }
    private func cancelStart() {
        sessionRequested = false
        startTask?.cancel()
        startTask = nil
        model.requestingPermission = false
    }
    private func pauseCamera(completion: @escaping @Sendable () -> Void = {}) {
        cancelStart()
        model.feedbackSuspended = true
        model.engine.stop(completion: completion)
        model.poll()
        latestSceneResult = nil
        state = .idle
    }
    func lifecycle(_ phase: ScenePhase) {
        sceneActive = phase == .active
        if phase != .active { cancelStart() }
        model.lifecycle(phase)
        poll(suspendFeedback: phase != .active)
        if phase == .active { resumeCameraIfNeeded() }
    }
}
