import Combine
import Foundation

/// Owns one interaction from press through answer playback. Generation checks keep
/// cancellation, delayed permission callbacks and stale network results from speaking.
@MainActor
final class PhotoDescriptionCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var isAnnouncing = false
    @Published private(set) var message = ""
    /// Follows the speech language chosen in the app, which can differ from the system's.
    var localized: (String) -> String = { String(localized: String.LocalizationValue($0)) }
    private(set) var work: Task<Void, Never>?
    private var imageTask: Task<Data, Error>?
    private var generation = UUID()
    private var captureOperation: ((CGFloat) throws -> Task<Data, Error>)?
    private var request: PhotoDescriptionRequest?
    private let recognizer: any PhotoRecognizing
    private let audio: any AnswerAudio
    private let services: PhotoDescriptionServices
    private var feedbackEnabled = true
    private var interactionMaySpeak = true
    private var awaitingPlayback = false
    private var capturingQuestion = false

    #if PRTS_DEV
    private var recordingGeneration: UInt64 = 0
    #endif

    /// Losing UI focus mutes the current interaction permanently, while inference continues.
    /// Enabling feedback again applies to the next interaction, never a delayed old answer.
    func setFeedbackEnabled(_ enabled: Bool) {
        feedbackEnabled = enabled
        guard !enabled, busy else { return }
        interactionMaySpeak = false
        if awaitingPlayback {
            cancel()
        } else {
            audio.stop()
        }
    }

    convenience init() {
        self.init(
            recognizer: PhotoSpeechRecognizer(),
            audio: AnswerAudioOutput(),
            services: .init()
        )
    }

    init(
        recognizer: any PhotoRecognizing,
        audio: any AnswerAudio,
        services: PhotoDescriptionServices
    ) {
        self.recognizer = recognizer
        self.audio = audio
        self.services = services
        audio.onFinished = { [weak self] in self?.cancel() }
    }

    func perform(
        _ action: PhotoPressState.Action,
        capture: @escaping (CGFloat) throws -> Task<Data, Error>,
        silence: () -> Void
    ) -> Bool {
        if action == .shortCapture || action == .startRecording {
            guard prepare(capture: capture, silence: silence) else { return false }
        }
        perform(action)
        return busy
    }

    private func prepare(
        capture: @escaping (CGFloat) throws -> Task<Data, Error>,
        silence: () -> Void
    ) -> Bool {
        guard !busy else { return false }
        silence()
        generation = UUID()
        interactionMaySpeak = feedbackEnabled
        awaitingPlayback = false
        #if PRTS_DEV
        recordingGeneration = RecordingStore.shared.admissionGeneration
        RecordingStore.shared.event(
            "interaction_started",
            details: ["feature": "photoDescription", "interactionID": generation.uuidString],
            generation: recordingGeneration
        )
        #endif
        captureOperation = capture
        busy = true
        message = localized("photo.message.pressHint")
        return true
    }

    private func prepareService(for feature: IntelligenceFeature) -> Bool {
        do {
            let configuration = try services.configuration(feature)
            var key = ""
            if configuration.provider != .onDevice {
                guard configuration.uploadAllowed else {
                    cancel()
                    message = localized("photo.message.allowUpload")
                    return false
                }
                guard let credential = try services.credential(configuration.provider),
                    !credential.isEmpty
                else {
                    throw PhotoChatError.missingKey
                }
                key = credential
            }
            request = PhotoDescriptionRequest(configuration: configuration, key: key)
        } catch {
            services.errors.record(error)
            cancel()
            message = error.localizedDescription
            return false
        }
        return true
    }

    private func perform(_ action: PhotoPressState.Action) {
        switch action {
        case .shortCapture:
            if !prepareService(for: .description) { return }
            do {
                try capture(purpose: .description)
            } catch {
                fail(error)
                return
            }
            let id = generation
            work = Task { [weak self] in
                guard let self, self.generation == id else { return }
                do {
                    try await self.cue(.submit)
                    guard self.generation == id else { return }
                    self.submit(question: nil)
                } catch {
                    if self.generation == id { self.fail(error) }
                }
            }
        case .startRecording: startRecording()
        case .stopRecording:
            guard capturingQuestion else { return }
            guard recognizer.endCapture() else {
                cancel()
                return
            }
            capturingQuestion = false
            let id = generation
            work = Task { [weak self] in
                guard let self, self.generation == id else { return }
                do {
                    try await self.cue(.submit)
                    guard self.generation == id else { return }
                    self.message = self.localized("photo.message.recognizing")
                    let text = try await self.recognizer.finish()
                    try Task.checkCancellation()
                    guard self.generation == id else { return }
                    self.submit(question: text)
                } catch {
                    if self.generation == id { self.fail(error) }
                }
            }
        case .none: break
        }
    }

    /// A disappearing input control might never deliver the release event. Do not submit it.
    func cancelUnreleasedQuestion() {
        if capturingQuestion { cancel() }
    }

    func shutdown() async {
        let pendingWork = work
        let pendingImage = imageTask
        cancel()
        await pendingWork?.value
        _ = await pendingImage?.result
    }

    func cancel() {
        #if PRTS_DEV
        if busy {
            DevInteractionRecording.noteSuppressedAfterClear(
                feature: "photoDescription",
                id: generation.uuidString,
                generation: recordingGeneration
            )
            RecordingStore.shared.event(
                "interaction_ended",
                details: ["feature": "photoDescription", "interactionID": generation.uuidString],
                generation: recordingGeneration
            )
        }
        #endif
        generation = UUID()
        work?.cancel()
        work = nil
        imageTask?.cancel()
        imageTask = nil
        recognizer.cancel()
        audio.stop()
        captureOperation = nil
        request = nil
        busy = false
        isAnnouncing = false
        awaitingPlayback = false
        capturingQuestion = false
        message = ""
    }

    private func capture(purpose: PhotoImagePurpose) throws {
        guard let captureOperation, let request else { throw PhotoChatError.emptyInput }
        self.captureOperation = nil
        #if PRTS_DEV
        imageTask = try DevInteractionRecording.$interactionID.withValue(generation.uuidString) {
            try DevInteractionRecording.$recordingGeneration.withValue(recordingGeneration) {
                try captureOperation(
                    purpose.longestSide(highResolution: request.configuration.highResolution)
                )
            }
        }
        #else
        imageTask = try captureOperation(
            purpose.longestSide(highResolution: request.configuration.highResolution)
        )
        #endif
    }

    private func startRecording() {
        guard prepareService(for: .question), let request else { return }
        let onDeviceOnly = request.configuration.provider == .onDevice
        guard services.speechAuthorized() else {
            cancel()
            message = localized("photo.message.microphoneNeeded")
            let id = generation
            work = Task { [weak self] in
                let granted = await self?.services.requestSpeechPermission() ?? false
                guard let self, self.generation == id else { return }
                self.message = self.localized(
                    granted ? "photo.message.microphoneGranted" : "photo.message.microphoneDenied"
                )
            }
            return
        }
        do {
            try capture(purpose: .question)
        } catch {
            fail(error)
            return
        }
        capturingQuestion = true
        let id = generation
        #if PRTS_DEV
        let recordingGeneration = self.recordingGeneration
        #endif
        work = Task { [weak self] in
            guard let self, self.generation == id else { return }
            do {
                try await self.cue(.record)
                guard self.generation == id else { return }
                #if PRTS_DEV
                try await DevInteractionRecording.$interactionID.withValue(id.uuidString) {
                    try await DevInteractionRecording.$recordingGeneration.withValue(
                        recordingGeneration
                    ) {
                        try await self.recognizer.start(onDeviceOnly: onDeviceOnly)
                    }
                }
                #else
                try await self.recognizer.start(onDeviceOnly: onDeviceOnly)
                #endif
                guard self.generation == id else { return }
                self.message = self.localized("photo.message.speakNow")
            } catch {
                if self.generation == id { self.fail(error) }
            }
        }
    }

    private func submit(question: String?) {
        guard let imageTask, let request else { return }
        let id = generation
        #if PRTS_DEV
        let recordingGeneration = self.recordingGeneration
        #endif
        let describe = services.describe
        self.request = nil
        message = localized("photo.message.describing")
        work = Task { [weak self] in
            do {
                let jpeg = try await imageTask.value
                try Task.checkCancellation()
                #if PRTS_DEV
                let answer = try await DevInteractionRecording.$interactionID.withValue(
                    id.uuidString
                ) {
                    try await DevInteractionRecording.$recordingGeneration.withValue(
                        recordingGeneration
                    ) {
                        try await describe(jpeg, question, request)
                    }
                }
                #else
                let answer = try await describe(jpeg, question, request)
                #endif
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                self.imageTask = nil
                self.recognizer.cancel()
                #if PRTS_DEV
                RecordingStore.shared.event(
                    "interaction_result",
                    details: [
                        "feature": "photoDescription", "interactionID": id.uuidString,
                        "question": question ?? "", "answer": answer,
                        "provider": request.configuration.provider.rawValue,
                    ],
                    generation: recordingGeneration
                )
                #endif
                guard self.interactionMaySpeak, self.feedbackEnabled else {
                    self.cancel()
                    return
                }
                self.message = self.localized("photo.message.speaking")
                self.awaitingPlayback = true
                try self.speak(answer)
            } catch {
                guard let self, self.generation == id else { return }
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        #if PRTS_DEV
        DevInteractionRecording.failure(
            error,
            feature: "photoDescription",
            id: generation.uuidString,
            generation: recordingGeneration
        )
        #endif
        let maySpeak = interactionMaySpeak && feedbackEnabled
        cancel()
        guard !(error is CancellationError) else { return }
        services.errors.record(error)
        switch error as? PhotoChatError {
        case .incompleteStream?, .answerTooLong?: isAnnouncing = true
        default: break
        }
        message = error.localizedDescription
        if isAnnouncing && maySpeak {
            busy = true
            awaitingPlayback = true
            do {
                try speak(message)
            } catch {
                services.errors.record(error)
                audio.stop()
                busy = false
                isAnnouncing = false
            }
        } else {
            isAnnouncing = false
        }
    }

    private func cue(_ cue: AnswerCue) async throws {
        guard interactionMaySpeak, feedbackEnabled else { return }
        do {
            #if PRTS_DEV
            try await DevInteractionRecording.$recordingGeneration.withValue(recordingGeneration) {
                try await audio.cue(cue)
            }
            #else
            try await audio.cue(cue)
            #endif
        } catch {
            // Muting an in-flight tone must not cancel the request that follows it.
            if interactionMaySpeak && feedbackEnabled { throw error }
        }
    }

    private func speak(_ text: String) throws {
        #if PRTS_DEV
        try DevInteractionRecording.$recordingGeneration.withValue(recordingGeneration) {
            try audio.speak(text)
        }
        #else
        try audio.speak(text)
        #endif
    }
}
