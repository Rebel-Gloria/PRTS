//
//  CameraManager.swift
//  PRTS
//

@preconcurrency import AVFoundation
import Combine
import CoreMedia
import SwiftUI

/// Implement this protocol in the future backend adapter to receive camera frames.
/// Frames arrive on a dedicated serial queue and must be processed off the main thread.
nonisolated protocol CameraFrameConsumer: AnyObject {
    nonisolated func consumeVideoFrame(_ sampleBuffer: CMSampleBuffer)
}

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

@MainActor
final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    nonisolated(unsafe) let session = AVCaptureSession()

    @Published private(set) var state: CameraState = .idle

    /// Assign a backend adapter here later. Keeping this nil has no runtime cost.
    nonisolated(unsafe) weak var frameConsumer: (any CameraFrameConsumer)?

    private let sessionQueue = DispatchQueue(label: "com.jingxuan.prts.camera.session")
    private let frameOutputQueue = DispatchQueue(label: "com.jingxuan.prts.camera.frames")
    nonisolated(unsafe) private var isConfigured = false

    func startCamera() {
        guard !state.isBusy, state != .running else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStartSession()

        case .notDetermined:
            updateState(.requestingPermission)
            AVCaptureDevice.requestAccess(for: .video) { [weak self] isGranted in
                guard let self else { return }

                if isGranted {
                    Task { @MainActor [weak self] in
                        self?.configureAndStartSession()
                    }
                } else {
                    self.updateState(.permissionDenied)
                }
            }

        case .denied, .restricted:
            updateState(.permissionDenied)

        @unknown default:
            updateState(.unavailable(.unknownPermission))
        }
    }

    func stopCamera() {
        sessionQueue.async { [weak self] in
            guard let self else { return }

            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.updateState(.idle)
        }
    }

    private func configureAndStartSession() {
        updateState(.starting)

        sessionQueue.async { [weak self] in
            guard let self else { return }

            do {
                if !self.isConfigured {
                    try self.configureSession()
                }

                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.updateState(.running)
            } catch let error as CameraSetupError {
                self.updateState(.unavailable(error.reason))
            } catch {
                self.updateState(.unavailable(.sessionStartFailed))
            }
        }
    }

    nonisolated private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high

        guard let camera = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw CameraSetupError.noRearCamera
        }

        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else {
            throw CameraSetupError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: frameOutputQueue)

        guard session.canAddOutput(output) else {
            throw CameraSetupError.cannotAddOutput
        }
        session.addOutput(output)

        isConfigured = true
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameConsumer?.consumeVideoFrame(sampleBuffer)
    }

    nonisolated private func updateState(_ newState: CameraState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}

private nonisolated enum CameraSetupError: Error {
    case noRearCamera
    case cannotAddInput
    case cannotAddOutput

    var reason: CameraUnavailableReason {
        switch self {
        case .noRearCamera:
            return .noRearCamera
        case .cannotAddInput:
            return .cannotAddInput
        case .cannotAddOutput:
            return .cannotAddOutput
        }
    }
}
