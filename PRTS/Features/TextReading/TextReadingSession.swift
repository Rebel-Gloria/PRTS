import AVFoundation
import Combine
import CoreImage
import UIKit

/// One text-reading pass: capture after focus settles, then read with the selected service.
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
    private var service = TextReadingService.vlm
    private var cloud: (key: String, service: PhotoChatService)?
    private var generation = UUID()

    init() {
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
        service = TextReadingService.current()
        cloud = service == .vlm ? Self.cloudSetup() : nil
        say(intro)
        camera.start(
            frame: { [weak self] in self?.frame(id) },
            failed: { [weak self] in self?.cameraFailed(id) }
        )
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
        let longestSide = PhotoImagePurpose.textReading.longestSide(
            highResolution: UserDefaults.standard.bool(forKey: PhotoImagePurpose.highResolutionKey)
        )
        guard let image,
            let jpeg = try? await Task.detached(operation: {
                try PhotoImageEncoder.jpeg(image: image, longestSide: longestSide)
            }).value
        else {
            return finishModel(id)
        }
        do {
            try await service.read(remoteAvailable: cloud != nil) { reader in
                guard generation == id else { throw CancellationError() }
                try await read(jpeg, image, with: reader, id)
            }
        } catch is CancellationError {
            if generation == id { end() }
            return
        } catch {
            // Preserve any text already read if every available reader fails.
        }
        finishModel(id)
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
            let surface = try await TextReadingBackend.surface(of: jpeg)
            try Task.checkCancellation()
            answer = TextReadingAnswer(lead: localized(surface.localizationKey))
            _ = try await TextReadingBackend.copy { [weak self] piece in
                // Main-queue order keeps the pieces in order, ahead of the flush below.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(piece, id) } }
            }
            await withCheckedContinuation { done in DispatchQueue.main.async { done.resume() } }
        case .remote:
            guard let cloud else { throw PhotoChatError.invalidService }
            let (surface, text) = try await TextReadingBackend.remote(
                jpeg: jpeg,
                key: cloud.key,
                service: cloud.service
            )
            try Task.checkCancellation()
            answer = TextReadingAnswer(lead: localized(surface.localizationKey))
            received(text, id)
        case .vision:
            // Vision does not know what the text is on.
            let text = try await Task.detached(operation: { try TextRecognizer.read(image) }).value
            try Task.checkCancellation()
            answer = TextReadingAnswer(
                lead: localized(TextReadingAnswer.Surface.object.localizationKey)
            )
            received(text, id)
        }
    }

    /// Missing setup stays offline without a prompt; photo upload still requires permission.
    private static func cloudSetup() -> (key: String, service: PhotoChatService)? {
        let provider = PhotoChatProvider.current()
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
        work?.cancel()
        work = nil
        camera.stop()
        voice.stop()
        voiceBusy = false
        modelDone = false
        guard phase != .idle else { return }
        phase = .idle
        finished()
    }
}
