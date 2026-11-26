import AVFoundation
import Combine
import CoreImage
import UIKit

/// One text-reading pass: capture after focus settles, then read with the selected service.
@MainActor
final class TextReadingSession: ObservableObject {
    enum Phase: Equatable { case idle, aiming, reading, speaking, ending }
    @Published private(set) var phase: Phase = .idle
    /// Preview frames seen in this pass (five a second).
    @Published private(set) var framesSeen = 0
    /// After the first frame, focus and exposure get this long before the photo is taken.
    static let settle: TimeInterval = 1
    /// Bounds camera startup and preview settling after the previous camera owner yields.
    static let cameraTimeout: Duration = .seconds(10)

    /// A string by localization key, in the interface language.
    var localized: (String) -> String = { $0 }
    /// Runs once whenever a pass ends: finished, failed or cancelled.
    var finished: () -> Void = {}

    let camera: any TextCapturing
    /// One voice for the whole pass: statuses and text queue up instead of cutting each other off.
    private let voice: any AnswerAudio
    private let services: TextReadingServices
    private let selectedService: () -> TextReadingService
    private let cloudSetup: () -> (key: String, service: PhotoChatService)?
    private var voiceBusy = false
    private var modelDone = false
    private var answer = TextReadingAnswer(lead: "")
    private var firstFrameAt: TimeInterval?
    private(set) var work: Task<Void, Never>?
    private var service = TextReadingService.vlm
    private var cloud: (key: String, service: PhotoChatService)?
    private var generation = UUID()
    private(set) var interactionID = UUID()
    private var feedbackEnabled = true
    private var passMaySpeak = true
    private var recordingGeneration: UInt64 = 0

    func setFeedbackEnabled(_ enabled: Bool) {
        feedbackEnabled = enabled
        guard !enabled else { return }
        passMaySpeak = false
        voice.stop()
        voiceBusy = false
        if modelDone { end() }
    }

    // Default arguments are evaluated outside the main actor, so the app uses this initializer.
    convenience init() {
        self.init(
            camera: TextCamera(),
            voice: AnswerAudioOutput(),
            services: TextReadingServices(),
            selectedService: { TextReadingService.current() },
            cloudSetup: { TextReadingServices.cloudSetup() }
        )
    }

    init(
        camera: any TextCapturing,
        voice: any AnswerAudio,
        services: TextReadingServices,
        selectedService: @escaping () -> TextReadingService,
        cloudSetup: @escaping () -> (key: String, service: PhotoChatService)?
    ) {
        self.camera = camera
        self.voice = voice
        self.services = services
        self.selectedService = selectedService
        self.cloudSetup = cloudSetup
        voice.onFinished = { [weak self] in self?.voiceFinished() }
    }

    func start(
        intro: String,
        prepareCamera: @MainActor (@escaping @MainActor @Sendable () -> Void) -> Void = { $0() }
    ) {
        guard phase == .idle else { return }
        let id = UUID()
        generation = id
        interactionID = id
        passMaySpeak = feedbackEnabled
        recordingGeneration = DevInteractionRecording.currentGeneration
        DevInteractionRecording.event(
            "interaction_started",
            details: ["feature": "textReading", "interactionID": id.uuidString],
            generation: recordingGeneration
        )
        phase = .aiming
        framesSeen = 0
        firstFrameAt = nil
        modelDone = false
        answer = TextReadingAnswer(lead: "")
        service = selectedService()
        cloud = service == .vision ? nil : cloudSetup()
        do {
            try say(intro)
            prepareCamera { [weak self] in
                self?.startCamera(id)
            }
        } catch {
            services.errors.record(error)
            end()
        }
    }

    func cancel() {
        guard phase != .idle, phase != .ending else { return }
        invalidateWork()
        camera.stop()
        voice.stop()
        voiceBusy = false
        phase = .ending
        do {
            try say("ocr.cancelled")
            finishSpeaking()
        } catch {
            services.errors.record(error)
            end()
        }
    }

    func shutdown() async {
        let pending = work
        finished = {}
        end()
        await pending?.value
        await withCheckedContinuation { done in camera.stop { done.resume() } }
    }

    func terminate() {
        end()
    }

    private func startCamera(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        work = Task { [weak self, services] in
            do {
                try await services.sleep(Self.cameraTimeout)
                try Task.checkCancellation()
            } catch { return }
            self?.cameraFailed(id)
        }
        camera.start(
            frame: { [weak self] in self?.frame(id) },
            failed: { [weak self] in self?.cameraFailed(id) }
        )
    }

    private func cameraFailed(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        // Queued preview callbacks must not start a capture while the error is being spoken.
        phase = .ending
        cancelWork()
        camera.stop()
        services.errors.record(NSError(domain: "PRTS.TextCamera", code: 1))
        do {
            try say("ocr.error.camera")
            finishSpeaking()
        } catch {
            services.errors.record(error)
            end()
        }
    }

    private func frame(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        let now = services.now()
        framesSeen += 1
        if firstFrameAt == nil { firstFrameAt = now }
        if let firstFrameAt, now - firstFrameAt >= Self.settle { capture(id) }
    }

    private func capture(_ id: UUID) {
        phase = .reading
        if feedbackEnabled && passMaySpeak {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        cancelWork()
        do {
            try say("ocr.capturing")
            let captured: (CIImage?) -> Void = { [weak self] image in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.camera.stop()
                    DevInteractionRecording.withContext(
                        id: id,
                        generation: self.recordingGeneration
                    ) {
                        self.work = Task { await self.read(image, id) }
                    }
                }
            }
            DevInteractionRecording.withContext(id: id, generation: recordingGeneration) {
                camera.capture(captured)
            }
        } catch {
            services.errors.record(error)
            end()
        }
    }

    private func read(_ image: CIImage?, _ id: UUID) async {
        let recordingGeneration = self.recordingGeneration
        do {
            guard let image else { throw PhotoChatError.emptyInput }
            // Vision reads the camera image itself, even if encoding for a model failed.
            var cachedJPEG: Data?
            func modelImage() async throws -> Data {
                if let cachedJPEG { return cachedJPEG }
                let jpeg = try await services.encode(image)
                DevInteractionRecording.attachment(
                    data: jpeg,
                    kind: "model_input",
                    fileExtension: "jpg",
                    metadata: ["feature": "textReading", "interactionID": id.uuidString],
                    generation: recordingGeneration
                )
                try Task.checkCancellation()
                cachedJPEG = jpeg
                return jpeg
            }
            try await service.read(remoteAvailable: cloud != nil) { reader in
                guard generation == id else { throw CancellationError() }
                do {
                    try await read(modelImage, image, with: reader, id)
                } catch {
                    if generation == id {
                        voice.stop()
                        voiceBusy = false
                        answer = TextReadingAnswer(lead: "")
                    }
                    throw error
                }
            }
            try Task.checkCancellation()
            finishModel(id, failed: false)
        } catch is CancellationError {
            if generation == id { end() }
        } catch {
            DevInteractionRecording.failure(
                error,
                feature: "textReading",
                id: id.uuidString,
                generation: recordingGeneration
            )
            services.errors.record(error)
            finishModel(id, failed: true)
        }
    }

    private func read(
        _ modelImage: () async throws -> Data,
        _ image: CIImage,
        with reader: TextReadingService.Reader,
        _ id: UUID
    )
        async throws
    {
        switch reader {
        case .onDevice:
            let surface = try await services.surface(modelImage())
            try Task.checkCancellation()
            answer = TextReadingAnswer(
                lead: localized(surface.localizationKey),
                expectsModelEmptyMarker: true
            )
            let result: Result<String, Error>
            do {
                result = .success(
                    try await services.copy { [weak self] piece in
                        // Drain callbacks before the reader result is handled, including a fallback.
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated { self?.received(piece, id) }
                        }
                    }
                )
            } catch {
                result = .failure(error)
            }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
            _ = try result.get()
        case .remote:
            guard let cloud else { throw PhotoChatError.invalidService }
            let (surface, text) = try await services.remote(modelImage(), cloud.key, cloud.service)
            try Task.checkCancellation()
            answer = TextReadingAnswer(lead: localized(surface.localizationKey))
            received(text, id)
        case .vision:
            // Vision does not know what the text is on.
            let text = try await services.vision(image)
            try Task.checkCancellation()
            answer = TextReadingAnswer(
                lead: localized(TextReadingAnswer.Surface.object.localizationKey)
            )
            received(text, id)
        }
        DevInteractionRecording.event(
            "text_reading_backend_completed",
            details: ["interactionID": id.uuidString, "backend": String(describing: reader)],
            generation: recordingGeneration
        )
        try Task.checkCancellation()
    }

    private func received(_ piece: String, _ id: UUID) {
        guard generation == id else { return }
        DevInteractionRecording.event(
            "interaction_result_delta",
            details: [
                "feature": "textReading", "interactionID": id.uuidString, "text": piece,
            ],
            generation: recordingGeneration
        )
        do {
            for line in answer.append(piece) { try speak(line) }
        } catch {
            services.errors.record(error)
            end()
        }
    }

    private func finishModel(_ id: UUID, failed: Bool) {
        guard generation == id else { return }
        do {
            if failed {
                // Partial text from a failed pass is dropped, so the user hears only the failure.
                voice.stop()
                voiceBusy = false
                try say("ocr.failed")
            } else {
                for line in answer.finish() { try speak(line) }
                if !answer.spokeText { try say("ocr.empty") }
            }
            finishSpeaking()
        } catch {
            services.errors.record(error)
            end()
        }
    }

    /// Ends the pass once everything queued has been heard.
    private func finishSpeaking() {
        modelDone = true
        if !voiceBusy { end() }
    }

    private func say(_ key: String) throws { try speak(localized(key)) }

    private func speak(_ text: String) throws {
        guard feedbackEnabled, passMaySpeak else { return }
        try DevInteractionRecording.withContext(generation: recordingGeneration) {
            try voice.speak(text)
        }
        voiceBusy = true
        if phase == .reading { phase = .speaking }
    }

    private func voiceFinished() {
        voiceBusy = false
        if modelDone { end() }
    }

    private func invalidateWork() {
        generation = UUID()
        cancelWork()
    }

    private func cancelWork() {
        work?.cancel()
        work = nil
    }

    private func end() {
        guard phase != .idle else { return }
        DevInteractionRecording.event(
            "interaction_ended",
            details: ["feature": "textReading", "interactionID": interactionID.uuidString],
            generation: recordingGeneration
        )
        invalidateWork()
        voice.stop()
        voiceBusy = false
        modelDone = false
        phase = .ending
        let id = generation
        camera.stop { [weak self] in
            guard let self, self.generation == id else { return }
            self.phase = .idle
            self.finished()
        }
    }
}
