import SwiftUI
import AVFoundation
import Combine
import SpatialCore

nonisolated enum CameraUnavailableReason: Equatable {
    case noRearCamera
    case cannotAddInput
    case cannotAddOutput
    case unknownPermission
    case sessionStartFailed

    var localizationKey: String {
        switch self {
        case .noRearCamera:
            return "camera.error.noRearCamera"
        case .cannotAddInput:
            return "camera.error.cannotAddInput"
        case .cannotAddOutput:
            return "camera.error.cannotAddOutput"
        case .unknownPermission:
            return "camera.error.unknownPermission"
        case .sessionStartFailed:
            return "camera.error.sessionStartFailed"
        }
    }
}

nonisolated enum CameraState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case permissionDenied
    case unavailable(CameraUnavailableReason)

    var statusLocalizationKey: String {
        switch self {
        case .idle:
            return "camera.status.idle"
        case .requestingPermission:
            return "camera.status.requestingPermission"
        case .starting:
            return "camera.status.starting"
        case .running:
            return "camera.status.running"
        case .permissionDenied:
            return "camera.status.permissionDenied"
        case .unavailable:
            return "camera.status.unavailable"
        }
    }

    var speechLocalizationKey: String {
        switch self {
        case .idle:
            return "speech.camera.idle"
        case .requestingPermission:
            return "speech.camera.requestingPermission"
        case .starting:
            return "speech.camera.starting"
        case .running:
            return "speech.camera.running"
        case .permissionDenied:
            return "speech.camera.permissionDenied"
        case .unavailable:
            return "speech.camera.unavailable"
        }
    }

    var accessibilityLocalizationKey: String {
        switch self {
        case .idle:
            return "accessibility.camera.ready"
        case .requestingPermission:
            return "accessibility.camera.requestingPermission"
        case .starting:
            return "accessibility.camera.starting"
        case .running:
            return "accessibility.camera.running"
        case .permissionDenied:
            return "accessibility.camera.permissionDenied"
        case .unavailable:
            return "accessibility.camera.unavailable"
        }
    }

    var iconName: String {
        switch self {
        case .running:
            return "dot.radiowaves.left.and.right"
        case .permissionDenied, .unavailable:
            return "exclamationmark.triangle.fill"
        case .requestingPermission, .starting:
            return "ellipsis"
        case .idle:
            return "checkmark.circle.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .permissionDenied, .unavailable:
            return .orange
        case .requestingPermission, .starting:
            return .yellow
        case .idle, .running:
            return Color(red: 0.25, green: 0.95, blue: 0.77)
        }
    }

    var isBusy: Bool {
        self == .requestingPermission || self == .starting
    }
}


/// UI adapter only. The sole camera owner is ProbeEngine's ARSession.
@MainActor
final class CameraManager: ObservableObject {
    let model = ProbeViewModel()
    @Published private(set) var state: CameraState = .idle
    @Published private(set) var status = "离线空间感知待启动"
    @Published private(set) var latestSceneResult: SceneResult?
    @Published private(set) var frameCount: UInt64 = 0
    func poll(suspendFeedback: Bool) {
        model.feedbackSuspended = suspendFeedback
        model.poll()
        frameCount = model.snapshot.frame?.id ?? 0
        status = model.snapshot.status
        latestSceneResult = SceneSnapshotAdapter.measuredResult(model.snapshot,now:ProcessInfo.processInfo.systemUptime)
        if model.snapshot.running { state = .running }
        else if model.requestingPermission { state = .requestingPermission }
        else if AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted { state = .permissionDenied }
        else if !model.capabilities.world { state = .unavailable(.noRearCamera) }
        else { state = .idle }
    }
    func startCamera() { guard !model.snapshot.running else { return }; model.startOrStop(); poll(suspendFeedback: true) }
    func stopCamera() { model.engine.stop(); model.poll(); latestSceneResult = nil; state = .idle }
    func lifecycle(_ phase: ScenePhase) { model.lifecycle(phase); poll(suspendFeedback: phase != .active) }
}
