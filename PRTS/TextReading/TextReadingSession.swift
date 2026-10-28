import AVFoundation
import Combine
import CoreImage
import UIKit

/// One text-reading pass: the ultra-wide camera, spoken framing hints, an automatic still
/// once the page is steady, then the recognized text read aloud.
@MainActor
final class TextReadingSession: ObservableObject {
    enum Phase: Equatable { case idle, framing, reading, speaking }
    @Published private(set) var phase: Phase = .idle
    /// Without a steady page by then, the whole view is read instead (signs, labels, screens).
    static let pageTimeout: TimeInterval = 8
    /// Hints wait until the opening announcement has been heard.
    static let introDuration: TimeInterval = 3

    /// Speaks a status by its localization key.
    var say: (String) -> Void = { _ in }
    /// Runs once whenever a pass ends: finished, failed or cancelled.
    var finished: () -> Void = {}

    private let camera = TextCamera()
    private let audio = PhotoAudioOutput()
    private var framing = DocumentFraming()
    private var lastCorners: [CGPoint]?
    private var startedAt: TimeInterval = 0
    private var generation = UUID()

    init() {
        audio.onFinished = { [weak self] in self?.end() }
    }

    func start() {
        guard phase == .idle else { return }
        let id = UUID()
        generation = id; framing = DocumentFraming(); lastCorners = nil
        startedAt = ProcessInfo.processInfo.systemUptime
        phase = .framing
        camera.start(corners: { [weak self] corners in self?.frame(corners, id) },
                     failed: { [weak self] in
                         guard let self, self.generation == id else { return }
                         self.say("ocr.error.camera"); self.end()
                     })
    }

    func cancel() {
        guard phase != .idle else { return }
        say("ocr.cancelled")
        end()
    }

    private func frame(_ corners: [CGPoint]?, _ id: UUID) {
        guard generation == id, phase == .framing else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if corners != nil { lastCorners = corners }
        let decision = framing.update(corners: corners, at: now)
        if decision == .capture { capture(page: true, id); return }
        if now - startedAt >= Self.pageTimeout { capture(page: false, id); return }
        if case .hint(let hint) = decision, now - startedAt >= Self.introDuration { say(hint.localizationKey) }
    }

    private func capture(page: Bool, _ id: UUID) {
        phase = .reading
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say(page ? "ocr.capturing" : "ocr.noPage")
        let previewCorners = page ? lastCorners : nil
        camera.capture { [weak self] image in
            Task.detached(priority: .userInitiated) {
                var text = ""
                if let image {
                    // The still is sharper than the preview, so find the page on it again.
                    let corners = page ? ((try? TextRecognizer.documentCorners(in: image)) ?? previewCorners) : nil
                    text = (try? TextRecognizer.read(image, corners: corners)) ?? ""
                }
                await self?.speak(text, id)
            }
        }
    }

    private func speak(_ text: String, _ id: UUID) {
        guard generation == id, phase == .reading else { return }
        camera.stop()
        guard !text.isEmpty else { say("ocr.empty"); end(); return }
        do {
            try audio.speak(text)
            phase = .speaking
        } catch { say("ocr.error.speech"); end() }
    }

    private func end() {
        generation = UUID()
        camera.stop(); audio.stop()
        guard phase != .idle else { return }
        phase = .idle
        finished()
    }
}

/// The back ultra-wide camera (wide on phones without one), outside ARKit. Preview frames are
/// checked for a page five times a second on the capture queue; stills are full resolution.
nonisolated final class TextCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                    AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "PRTS.TextCamera")
    private var configured = false
    private var lastAnalysis: TimeInterval = 0
    private var onCorners: (@MainActor ([CGPoint]?) -> Void)?
    private var onPhoto: ((CIImage?) -> Void)?

    func start(corners: @escaping @MainActor ([CGPoint]?) -> Void, failed: @escaping @MainActor () -> Void) {
        queue.async {
            self.onCorners = corners
            guard self.configured || self.configure() else { Task { @MainActor in failed() }; return }
            self.session.startRunning()
        }
    }

    func capture(_ done: @escaping (CIImage?) -> Void) {
        queue.async {
            self.onPhoto = done
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .quality
            self.photo.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        queue.async {
            self.onCorners = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photo) else { return false }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(video)
        session.addOutput(photo)
        photo.maxPhotoQualityPrioritization = .quality
        // Portrait-upright preview frames, so page corners match the phone the user is holding.
        for connection in [video.connection(with: .video), photo.connection(with: .video)] {
            if connection?.isVideoRotationAngleSupported(90) == true { connection?.videoRotationAngle = 90 }
        }
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let onCorners, now - lastAnalysis >= 0.2, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastAnalysis = now
        let corners = try? TextRecognizer.documentCorners(in: CIImage(cvPixelBuffer: buffer))
        Task { @MainActor in onCorners(corners) }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        onPhoto?(image); onPhoto = nil
    }
}
