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
            model: ProbeViewModel(engine: ProbeEngine(), feedback: PathHaptics()),
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
    /// The home screen reads this right after `poll` and no view shows it, so it is not
    /// published: a new result arrives ten times a second.
    private(set) var latestSceneResult: SceneResult?
    /// What views read from `model` without observing it: the operation message and the shape
    /// of the camera image.
    private struct ModelPresentation: Equatable {
        var errorMessage: String?
        var permissionMessage: String?
        var imageWidth = 0
        var imageHeight = 0
    }
    private var modelPresentation = ModelPresentation()
    /// Runs every 0.1 s. Assigning a published property redraws the home screen even when the
    /// value is the same, so only changes are published.
    func poll(suspendFeedback: Bool) {
        let runningIntent = sessionRequested && !suspendsFeedback && isActive()
        model.feedbackSuspended = suspendFeedback || !runningIntent
        model.poll()
        if status != model.snapshot.status { status = model.snapshot.status }
        latestSceneResult =
            runningIntent
            ? SceneSnapshotAdapter.measuredResult(
                model.snapshot,
                now: ProcessInfo.processInfo.systemUptime
            ) : nil
        if !model.snapshot.running && startTask == nil { sessionRequested = false }
        let authorization = authorizationStatus()
        let current: CameraState
        if model.snapshot.running && runningIntent {
            current = .running
        } else if model.requestingPermission {
            // The system prompt appears only while authorisation is undetermined; on every
            // later start "allow camera access" would be a false instruction.
            current = authorization == .notDetermined ? .requestingPermission : .starting
        } else if authorization == .denied || authorization == .restricted {
            current = .permissionDenied
        } else if !model.capabilities.world {
            current = .unavailable(.noRearCamera)
        } else {
            current = .idle
        }
        if state != current { state = current }
        let presentation = ModelPresentation(
            errorMessage: model.errorMessage,
            permissionMessage: model.permissionMessage,
            imageWidth: model.snapshot.frame?.intrinsics.width ?? 0,
            imageHeight: model.snapshot.frame?.intrinsics.height ?? 0
        )
        if modelPresentation != presentation {
            objectWillChange.send()
            modelPresentation = presentation
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
    func pauseForTextReading(completion: @escaping @MainActor @Sendable () -> Void = {}) {
        pausedForTextReading = true
        pauseCamera { Task { @MainActor in completion() } }
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
