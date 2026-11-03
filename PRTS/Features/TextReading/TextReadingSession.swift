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
    /// No preview frame by then means the camera never started.
    static let cameraTimeout: Duration = .seconds(10)
    /// Settings: whether a three-finger hold starts reading.
    static let threeFingerKey = "ocr.threeFinger"

    /// A string by localization key, in the interface language.
    var localized: (String) -> String = { $0 }
    /// Runs once whenever a pass ends: finished, failed or cancelled.
    var finished: () -> Void = {}

    let camera: any TextCapturing
    /// One voice for the whole pass: statuses and text queue up instead of cutting each other off.
    private let voice: any PhotoAnswerAudio
    private let services: TextReadingServices
    private let selectedService: () -> TextReadingService
    private let cloudSetup: () -> (key: String, service: PhotoChatService)?
    private var voiceBusy = false
    private var modelDone = false
    private var answer = TextReadingAnswer(lead: "")
    private var firstFrameAt: TimeInterval?
    private(set) var work: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var service = TextReadingService.vlm
    private var cloud: (key: String, service: PhotoChatService)?
    private var generation = UUID()

    // Default arguments are evaluated outside the main actor, so the app uses this initializer.
    convenience init() {
        self.init(
            camera: TextCamera(),
            voice: PhotoAudioOutput(),
            services: TextReadingServices(),
            selectedService: { TextReadingService.current() },
            cloudSetup: { TextReadingSession.cloudSetup() }
        )
    }

    init(
        camera: any TextCapturing,
        voice: any PhotoAnswerAudio,
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

    func start(intro: String) {
        guard phase == .idle else { return }
        let id = UUID()
        generation = id
        phase = .aiming
        framesSeen = 0
        firstFrameAt = nil
        modelDone = false
        answer = TextReadingAnswer(lead: "")
        service = selectedService()
        cloud = service == .vision ? nil : cloudSetup()
        do {
            try say(intro)
            camera.start(
                frame: { [weak self] in self?.frame(id) },
                failed: { [weak self] in self?.cameraFailed(id) }
            )
            timeout = Task { [weak self, services] in
                do { try await services.sleep(Self.cameraTimeout) } catch { return }
                if self?.framesSeen == 0 { self?.cameraFailed(id) }
            }
        } catch {
            end()
        }
    }

    func cancel() {
        guard phase != .idle, phase != .ending else { return }
        invalidateWork()
        voice.stop()
        voiceBusy = false
        phase = .ending
        do {
            try say("ocr.cancelled")
            finishSpeaking()
        } catch {
            end()
        }
    }

    func terminate() {
        end()
    }

    private func cameraFailed(_ id: UUID) {
        guard generation == id, phase == .aiming else { return }
        camera.stop()
        do {
            try say("ocr.error.camera")
            finishSpeaking()
        } catch {
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
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        timeout?.cancel()
        timeout = nil
        do {
            try say("ocr.capturing")
            camera.capture { [weak self] image in
                Task { @MainActor in
                    guard let self, self.generation == id else { return }
                    self.camera.stop()
                    self.work = Task { await self.read(image, id) }
                }
            }
        } catch {
            end()
        }
    }

    private func read(_ image: CIImage?, _ id: UUID) async {
        do {
            guard let image else { throw PhotoChatError.emptyInput }
            let jpeg = try await services.encode(image)
            try await service.read(remoteAvailable: cloud != nil) { reader in
                guard generation == id else { throw CancellationError() }
                try await read(jpeg, image, with: reader, id)
            }
            try Task.checkCancellation()
            finishModel(id, failed: false)
        } catch is CancellationError {
            if generation == id { end() }
        } catch {
            finishModel(id, failed: true)
        }
    }

    private func read(
        _ jpeg: Data,
        _ image: CIImage,
        with reader: TextReadingService.Reader,
        _ id: UUID
    )
        async throws
    {
        switch reader {
        case .onDevice:
            let surface = try await services.surface(jpeg)
            try Task.checkCancellation()
            answer = TextReadingAnswer(lead: localized(surface.localizationKey))
            let result: Result<String, Error>
            do {
                result = .success(
                    try await services.copy { [weak self] piece in
                        // Queued text must survive a reader failure before fallback or final failure.
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
            let (surface, text) = try await services.remote(jpeg, cloud.key, cloud.service)
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
        try Task.checkCancellation()
    }

    /// Missing setup stays offline without a prompt; photo upload still requires permission.
    private static func cloudSetup() -> (key: String, service: PhotoChatService)? {
        let provider = IntelligenceFeature.textReading.provider()!
        guard let service = provider.service() else { return nil }
        guard UserDefaults.standard.bool(forKey: "photoDescription.uploadAllowed") else {
            return nil
        }
        guard let key = try? PhotoCredentialStore.read(account: provider.keyAccount), !key.isEmpty
        else { return nil }
        return (key, service)
    }

    private func received(_ piece: String, _ id: UUID) {
        guard generation == id else { return }
        do {
            for line in answer.append(piece) { try speak(line) }
        } catch {
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
        try voice.speak(text)
        voiceBusy = true
        if phase == .reading { phase = .speaking }
    }

    private func voiceFinished() {
        voiceBusy = false
        if modelDone { end() }
    }

    private func invalidateWork() {
        generation = UUID()
        work?.cancel()
        work = nil
        timeout?.cancel()
        timeout = nil
        camera.stop()
    }

    private func end() {
        guard phase != .idle else { return }
        invalidateWork()
        voice.stop()
        voiceBusy = false
        modelDone = false
        phase = .idle
        finished()
    }
}
