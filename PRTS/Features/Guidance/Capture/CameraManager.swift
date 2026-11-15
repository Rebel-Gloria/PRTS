import ARKit
import AVFoundation
import Combine
import SpatialCore
import SwiftUI

/// Maintains guidance camera intent and UI state, coordinating pause/resume for text reading.
/// ProbeEngine owns spatial capture; low vision uses RGB only, and text reading owns a still camera.
@MainActor
final class CameraManager: ObservableObject {
    let model: ProbeViewModel
    private let permission: () async throws -> Bool
    private let isActive: () -> Bool
    private let authorizationStatus: () -> AVAuthorizationStatus
    private let rgbCamera: any RGBCapturing
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
        authorizationStatus: @escaping () -> AVAuthorizationStatus,
        rgbCamera: any RGBCapturing = RGBCamera()
    ) {
        self.model = model
        self.permission = permission
        self.isActive = isActive
        self.authorizationStatus = authorizationStatus
        self.rgbCamera = rgbCamera
        rgbCamera.setSceneActive(isActive())
    }
    private var wantsCameraRunning = false
    private var pausedForTextReading = false
    private var sceneActive = true
    private var sessionRequested = false
    private var startGeneration = UUID()
    private var modeTransition: UUID?
    private var pendingCameraReleases = 0
    private(set) var lowVisionMode = false
    var rgbSession: AVCaptureSession { rgbCamera.session }
    var suspendsFeedback: Bool {
        !wantsCameraRunning || pausedForTextReading || !sceneActive || !isActive()
    }
    @Published private(set) var state: CameraState = .idle
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
        let runningIntent = sessionRequested && wantsCameraRunning && !pausedForTextReading
        model.feedbackSuspended =
            suspendFeedback || !runningIntent || suspendsFeedback || !isActive()
        model.poll()
        if lowVisionMode { rgbCamera.setOrientation(model.snapshot.orientation) }
        latestSceneResult =
            runningIntent && !lowVisionMode && !suspendsFeedback
            ? SceneSnapshotAdapter.measuredResult(
                model.snapshot,
                now: ProcessInfo.processInfo.systemUptime
            ) : nil
        let running = lowVisionMode ? rgbCamera.running : model.snapshot.running
        if !running && startTask == nil { sessionRequested = false }
        let authorization = authorizationStatus()
        let current: CameraState
        if running && runningIntent {
            current = .running
        } else if model.requestingPermission {
            // The system prompt appears only while authorisation is undetermined; on every
            // later start "allow camera access" would be a false instruction.
            current = authorization == .notDetermined ? .requestingPermission : .starting
        } else if authorization == .denied || authorization == .restricted {
            current = .permissionDenied
        } else if !lowVisionMode && !model.capabilities.world {
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
    /// Switching modes releases the current camera before its replacement opens the device.
    func setLowVisionMode(
        _ enabled: Bool,
        completion: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        guard lowVisionMode != enabled else {
            completion()
            return
        }
        lowVisionMode = enabled
        model.engine.diagnostics.event(
            "low_vision_changed",
            details: String(enabled),
            epoch: model.snapshot.epoch
        )
        let id = UUID()
        modeTransition = id
        pauseCamera { [weak self] in
            Task { @MainActor [weak self] in
                if self?.modeTransition == id {
                    self?.modeTransition = nil
                    self?.resumeCameraIfNeeded()
                }
                completion()
            }
        }
    }

    func imageSnapshot() -> CameraImageSnapshot? {
        if lowVisionMode { return rgbCamera.snapshot(orientation: model.snapshot.orientation) }
        guard let frame = model.snapshot.frame else { return nil }
        return CameraImageSnapshot(
            pixelBuffer: frame.frame.capturedImage,
            orientation: frame.orientation,
            timestamp: frame.frame.timestamp,
            receivedAt: frame.receivedAt,
            frameID: frame.id
        )
    }

    func capturePhoto(longestSide: CGFloat) throws -> Task<Data, Error> {
        guard let image = imageSnapshot(),
            ProcessInfo.processInfo.systemUptime - image.receivedAt < 1
        else { throw PhotoChatError.emptyInput }
        #if PRTS_DEV
        DevInteractionRecording.original(
            pixelBuffer: image.pixelBuffer,
            orientation: image.orientation,
            feature: "photoDescription",
            metadata: [
                "timestamp": String(image.timestamp),
                "sourceFrameID": image.frameID.map(String.init) ?? "unavailable",
                "source": lowVisionMode ? "rgb" : "arkit",
            ]
        )
        #endif
        return Task.detached(priority: .userInitiated) {
            try PhotoImageEncoder.jpeg(
                pixelBuffer: image.pixelBuffer,
                orientation: image.orientation,
                longestSide: longestSide
            )
        }
    }

    func captureCaptionFrame() throws -> Task<LiveCaptionFrame, Error> {
        guard let image = imageSnapshot(),
            ProcessInfo.processInfo.systemUptime - image.receivedAt < 1
        else { throw PhotoChatError.emptyInput }
        let sampledAt = ProcessInfo.processInfo.systemUptime
        return Task.detached(priority: .userInitiated) {
            var captured = try LiveCaptionFrame.capture(
                image: PhotoImageEncoder.image(
                    pixelBuffer: image.pixelBuffer,
                    orientation: image.orientation
                ),
                sampledAt: sampledAt
            )
            captured.sourceFrameID = image.frameID
            captured.sourceTimestamp = image.timestamp
            return captured
        }
    }
    private func resumeCameraIfNeeded() {
        guard wantsCameraRunning, !pausedForTextReading, sceneActive, modeTransition == nil,
            pendingCameraReleases == 0
        else {
            return
        }
        guard !sessionRequested else { return }
        sessionRequested = true
        let id = UUID()
        startGeneration = id
        model.requestingPermission = true
        model.engine.diagnostics.event(
            "camera_start_requested",
            details: "user_action",
            epoch: model.snapshot.epoch
        )
        startTask = Task {
            do {
                try Task.checkCancellation()
                let allowed =
                    lowVisionMode || model.capabilities.world
                    ? try await permission() : true
                try Task.checkCancellation()
                model.requestingPermission = false
                if lowVisionMode && allowed && sceneActive && isActive() {
                    let started = await withCheckedContinuation { done in
                        rgbCamera.start { done.resume(returning: $0) }
                    }
                    guard startGeneration == id else { return }
                    if !started {
                        model.errorMessage = String(localized: "camera.error.noRearCamera")
                    }
                } else if !lowVisionMode || !allowed {
                    await model.start(allowed: allowed, isActive: sceneActive && isActive())
                }
                try Task.checkCancellation()
                guard startGeneration == id else { return }
                startTask = nil
                poll(suspendFeedback: true)
            } catch is CancellationError {
                // The cancelling operation owns the next camera state.
            } catch {
                guard startGeneration == id else { return }
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
        startGeneration = UUID()
        sessionRequested = false
        startTask?.cancel()
        startTask = nil
        model.requestingPermission = false
    }
    private func pauseCamera(completion: @escaping @Sendable () -> Void = {}) {
        cancelStart()
        model.feedbackSuspended = true
        pendingCameraReleases += 1
        let camera = rgbCamera
        model.engine.stop {
            camera.stop { [weak self] in
                Task { @MainActor [weak self] in
                    self?.pendingCameraReleases -= 1
                    completion()
                    self?.resumeCameraIfNeeded()
                }
            }
        }
        model.poll()
        latestSceneResult = nil
        state = .idle
    }
    func lifecycle(_ phase: ScenePhase) {
        sceneActive = phase == .active
        rgbCamera.setSceneActive(sceneActive && isActive())
        // A permission/start operation cannot take the camera while the app is inactive.
        // Once running, retain the session; ARKit/AVFoundation handle OS interruptions.
        if phase != .active, startTask != nil, !model.snapshot.running, !rgbCamera.running {
            cancelStart()
        }
        model.lifecycle(phase)
        poll(suspendFeedback: phase != .active)
        if phase == .active { resumeCameraIfNeeded() }
    }
}
