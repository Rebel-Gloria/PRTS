import AVFoundation
import Combine
import SpatialCore
import SwiftUI

/// UI adapter only. The sole camera owner is ProbeEngine's ARSession.
@MainActor
final class CameraManager: ObservableObject {
    let model = ProbeViewModel()
    private var wantsCameraRunning = false
    private var pausedForTextReading = false
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var status = "离线空间感知待启动"
    @Published private(set) var latestSceneResult: SceneResult?
    func poll(suspendFeedback: Bool) {
        model.feedbackSuspended = suspendFeedback
        model.poll()
        status = model.snapshot.status
        latestSceneResult = SceneSnapshotAdapter.measuredResult(
            model.snapshot,
            now: ProcessInfo.processInfo.systemUptime
        )
        if model.snapshot.running {
            state = .running
        } else if model.requestingPermission {
            state = .requestingPermission
        } else if AVCaptureDevice.authorizationStatus(for: .video) == .denied
            || AVCaptureDevice.authorizationStatus(for: .video) == .restricted
        {
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
        guard wantsCameraRunning, !pausedForTextReading else { return }
        guard !model.snapshot.running else { return }
        model.startOrStop()
        poll(suspendFeedback: true)
    }
    func stopCamera() {
        wantsCameraRunning = false
        pauseCamera()
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
    private func pauseCamera() {
        model.engine.stop()
        model.poll()
        latestSceneResult = nil
        state = .idle
    }
    func lifecycle(_ phase: ScenePhase) {
        model.lifecycle(phase)
        poll(suspendFeedback: phase != .active)
        if phase == .active { resumeCameraIfNeeded() }
    }
}
