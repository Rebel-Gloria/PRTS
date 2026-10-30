import AVFoundation
import Combine
import CoreImage
import UIKit

/// One quick text-reading pass: the main camera, a photo once focus has settled, then the bundled
/// MiniCPM-V says what the text is on and copies it, read aloud line by line as it comes.
@MainActor
final class TextReadingSession: ObservableObject {
    enum Phase: Equatable { case idle, aiming, reading, speaking }
    @Published private(set) var phase: Phase = .idle
    /// Preview frames seen in this pass (five a second).
    @Published private(set) var framesSeen = 0
    /// After the first frame, focus and exposure get this long before the photo is taken.
    static let settle: TimeInterval = 1
    /// No preview frame by then means the camera never started.
    static let cameraTimeout: Duration = .seconds(10)
    /// Settings: whether a three-finger hold starts reading.
    static let threeFingerKey = "ocr.threeFinger"

    /// A string by localization key, in the interface language.
    var localized: (String) -> String = { $0 }
    /// Runs once whenever a pass ends: finished, failed or cancelled.
    var finished: () -> Void = {}

    let camera = TextCamera()
    /// One voice for the whole pass: statuses and text queue up instead of cutting each other off.
    private let voice = PhotoAudioOutput()
    private var voiceBusy = false
    private var modelDone = false
    private var answer = TextReadingAnswer(lead: "")
    private var firstFrameAt: TimeInterval?
    private var work: Task<Void, Never>?
    private var generation = UUID()

    init() {
        voice.onFinished = { [weak self] in self?.voiceFinished() }
    }

    func start(intro: String) {
        guard phase == .idle else { return }
        let id = UUID()
        generation = id; phase = .aiming; framesSeen = 0; firstFrameAt = nil
        modelDone = false
        say(intro)
        camera.start(frame: { [weak self] in self?.frame(id) },
                     failed: { [weak self] in self?.cameraFailed(id) })
        Task { [weak self] in
            try? await Task.sleep(for: Self.cameraTimeout)
            if self?.framesSeen == 0 { self?.cameraFailed(id) }
        }
    }

    func cancel() {
        guard phase != .idle else { return }
        end()
        say("ocr.cancelled")
    }

    private func cameraFailed(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        camera.stop()
        say("ocr.error.camera")
        finishSpeaking()
    }

    private func frame(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        let now = ProcessInfo.processInfo.systemUptime
        framesSeen += 1
        if firstFrameAt == nil { firstFrameAt = now }
        if let firstFrameAt, now - firstFrameAt >= Self.settle { capture(id) }
    }

    private func capture(_ id: UUID) {
        phase = .reading
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        say("ocr.capturing")
        camera.capture { [weak self] image in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.camera.stop()
                self.work = Task { await self.read(image, id) }
            }
        }
    }

    private func read(_ image: CIImage?, _ id: UUID) async {
        guard let image, let jpeg = try? await Task.detached(operation: { try PhotoImageEncoder.jpeg(image: image) }).value else {
            return finishModel(id)
        }
        do {
            let surface = try await TextReadingPrompt.surface(of: jpeg)
            guard generation == id else { return }
            answer = TextReadingAnswer(lead: localized(surface.localizationKey))
            _ = try await TextReadingPrompt.copy { [weak self] piece in
                // Main-queue order keeps the pieces in order, ahead of the flush below.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(piece, id) } }
            }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        } catch is CancellationError {
            return
        } catch {
            // The model failed: Apple's Vision still reads the photo, without knowing what the text is on.
            let text = (try? await Task.detached(operation: { try TextRecognizer.read(image) }).value) ?? ""
            guard generation == id else { return }
            answer = TextReadingAnswer(lead: localized(TextReadingPrompt.Surface.object.localizationKey))
            received(text, id)
        }
        finishModel(id)
    }

    private func received(_ piece: String, _ id: UUID) {
        guard generation == id else { return }
        for line in answer.append(piece) { speak(line) }
    }

    private func finishModel(_ id: UUID) {
        guard generation == id else { return }
        for line in answer.finish() { speak(line) }
        if !answer.spokeText { say("ocr.empty") }
        finishSpeaking()
    }

    /// Ends the pass once everything queued has been heard.
    private func finishSpeaking() {
        modelDone = true
        if !voiceBusy { end() }
    }

    private func say(_ key: String) { speak(localized(key)) }

    private func speak(_ text: String) {
        do {
            try voice.speak(text)
            voiceBusy = true
            if phase == .reading { phase = .speaking }
        } catch {
            end()
        }
    }

    private func voiceFinished() {
        voiceBusy = false
        if modelDone { end() }
    }

    private func end() {
        generation = UUID()
        work?.cancel(); work = nil
        camera.stop(); voice.stop()
        voiceBusy = false; modelDone = false
        guard phase != .idle else { return }
        phase = .idle
        finished()
    }
}

/// The back main (wide) camera, outside ARKit: sharper on small print than the ultra-wide.
/// Preview frames are reported five times a second; stills are full resolution.
nonisolated final class TextCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                    AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let video = AVCaptureVideoDataOutput()
    private let photo = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "PRTS.TextCamera")
    private var configured = false
    private var lastFrame: TimeInterval = 0
    private var onFrame: (@MainActor () -> Void)?
    private var onPhoto: ((CIImage?) -> Void)?

    /// Adding the camera input waits, sometimes for seconds, until ARKit lets go of the camera.
    /// Doing it at launch, before guidance ever runs, makes starting a pass take ~0.3 s.
    override init() {
        super.init()
        queue.async { _ = self.configure() }
    }

    func start(frame: @escaping @MainActor () -> Void, failed: @escaping @MainActor () -> Void) {
        queue.async {
            self.onFrame = frame
            guard self.configured || self.configure() else { Task { @MainActor in failed() }; return }
            self.session.startRunning()
        }
    }

    func capture(_ done: @escaping (CIImage?) -> Void) {
        queue.async {
            self.onPhoto = done
            let settings = AVCapturePhotoSettings()
            settings.photoQualityPrioritization = .balanced
            self.photo.capturePhoto(with: settings, delegate: self)
        }
    }

    func stop() {
        queue.async {
            self.onFrame = nil
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input), session.canAddOutput(video), session.canAddOutput(photo) else { return false }
        session.addInput(input)
        video.alwaysDiscardsLateVideoFrames = true
        video.setSampleBufferDelegate(self, queue: queue)
        session.addOutput(video)
        session.addOutput(photo)
        photo.maxPhotoQualityPrioritization = .balanced
        // Portrait-upright frames and stills, the way the user holds the phone.
        for connection in [video.connection(with: .video), photo.connection(with: .video)] {
            if connection?.isVideoRotationAngleSupported(90) == true { connection?.videoRotationAngle = 90 }
        }
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard let onFrame, now - lastFrame >= 0.2 else { return }
        lastFrame = now
        Task { @MainActor in onFrame() }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let image = photo.fileDataRepresentation().flatMap { CIImage(data: $0, options: [.applyOrientationProperty: true]) }
        onPhoto?(image); onPhoto = nil
    }
}
