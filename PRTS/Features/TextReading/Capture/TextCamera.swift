import AVFoundation
import Combine
import CoreImage
import UIKit

/// The back main (wide) camera, outside ARKit: sharper on small print than the ultra-wide.
/// Preview frames are reported five times a second; stills are full resolution.
nonisolated final class TextCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    TextCapturing, @unchecked Sendable
{
    let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "PRTS.TextCamera")
    private var configured = false
    private var lastFrame: TimeInterval = 0
    private var onFrame: (@MainActor () -> Void)?
    private var requests: [Int64: TextPhotoRequest] = [:]

    /// Adding the camera input waits, sometimes for seconds, until ARKit lets go of the camera.
    /// Doing it at launch, before guidance ever runs, makes starting a pass take ~0.3 s.
    override init() {
        super.init()
        queue.async { _ = self.configure() }
    }

    func start(frame: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        queue.async {
            self.onFrame = frame
            guard self.configured || self.configure() else {
                Task { @MainActor in failed() }
                return
            }
            self.session.startRunning()
        }
    }

    func capture(_ done: @escaping (CIImage?) -> Void) {
        queue.async {
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            let request = TextPhotoRequest { image in
                self.queue.async {
                    self.requests.removeValue(forKey: settings.uniqueID)
                    done(image)
                }
            }
            self.requests[settings.uniqueID] = request
            self.photo.capturePhoto(with: settings, delegate: request)
        }
    }

    func stop(completion: @escaping @MainActor @Sendable () -> Void) {
        queue.async {
            self.onFrame = nil
            if self.session.isRunning { self.session.stopRunning() }
            Task { @MainActor in completion() }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard
            let device = AVCaptureDevice.default(
                .builtInWideAngleCamera,
                for: .video,
                position: .back
            ),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photo)
        else { return false }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(video)
        session.addOutput(photo)
        photo.maxPhotoQualityPrioritization = .balanced
        // Portrait-upright frames and stills, the way the user holds the phone.
        for connection in [video.connection(with: .video), photo.connection(with: .video)] {
            if connection?.isVideoRotationAngleSupported(90) == true {
                connection?.videoRotationAngle = 90
            }
        }
        configured = true
        return true
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let onFrame, now - lastFrame >= 0.2 else { return }
        lastFrame = now
        Task { @MainActor in onFrame() }
    }
}

nonisolated protocol TextCapturing: AnyObject {
    var session: AVCaptureSession { get }
    func start(frame: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void)
    func capture(_ done: @escaping (CIImage?) -> Void)
    func stop(completion: @escaping @MainActor @Sendable () -> Void)
}

extension TextCapturing {
    func stop() { stop(completion: {}) }
}

/// Each delegate keeps the completion of the capture that created it.
nonisolated final class TextPhotoRequest: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (CIImage?) -> Void
    private var image: CIImage?

    init(completion: @escaping (CIImage?) -> Void) {
        self.completion = completion
    }

    func complete(_ image: CIImage?) {
        completion(image)
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        image = photo.fileDataRepresentation().flatMap {
            CIImage(data: $0, options: [.applyOrientationProperty: true])
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        complete(error == nil ? image : nil)
    }
}
