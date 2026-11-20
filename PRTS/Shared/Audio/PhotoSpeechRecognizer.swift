import AVFoundation
import Speech

/// A single push-to-talk utterance. Dev additionally preserves the already authorized
/// microphone input for replay. The coordinator owns permission and gesture lifetime.
@MainActor
final class PhotoSpeechRecognizer: PhotoRecognizing {
    enum RecognitionError: LocalizedError {
        case unavailable, noSpeech, microphoneUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable:
                AppLocalization.interfaceString("photo.error.recognitionUnavailable")
            case .noSpeech: AppLocalization.interfaceString("photo.error.noSpeech")
            case .microphoneUnavailable:
                AppLocalization.interfaceString("photo.error.microphoneUnavailable")
            }
        }
    }
    private let engine = AVAudioEngine()
    private let audioSession: AudioSessionCoordinator
    private var audioLease: AudioSessionCoordinator.Lease?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?
    private var tapInstalled = false
    private var endedAudio = false
    private var generation = UUID()
    private var latest = ""
    private var result: Result<String, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    #if PRTS_DEV
    private var recording: DevAudioRecording?
    #endif

    convenience init() { self.init(audioSession: .shared) }

    init(audioSession: AudioSessionCoordinator) { self.audioSession = audioSession }

    static var authorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
            && AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization {
                continuation.resume(returning: $0 == .authorized)
            }
        }
        guard speech, !Task.isCancelled else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start(onDeviceOnly: Bool) async throws {
        #if PRTS_DEV
        let recordingGeneration =
            DevInteractionRecording.recordingGeneration ?? RecordingStore.shared.admissionGeneration
        #endif
        cancel()
        let id = UUID()
        generation = id
        guard Self.authorized,
            let recognizer = SFSpeechRecognizer(locale: SpeechPreferences.language().locale),
            recognizer.isAvailable
        else { throw RecognitionError.unavailable }
        guard !onDeviceOnly || recognizer.supportsOnDeviceRecognition else {
            throw RecognitionError.unavailable
        }
        speechRecognizer = recognizer
        let lease = try await audioSession.activateAsync(.recording)
        guard generation == id else {
            audioSession.release(lease)
            throw CancellationError()
        }
        audioLease = lease
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = onDeviceOnly
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel()
            throw RecognitionError.microphoneUnavailable
        }
        #if PRTS_DEV
        let recording = DevAudioRecording(id: id.uuidString)
        self.recording = recording
        #endif
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in
            request.append(buffer)
            #if PRTS_DEV
            recording.append(buffer, time: time)
            #endif
        }
        tapInstalled = true
        task = recognizer.recognitionTask(with: request) { [weak self] value, error in
            // Transfer only immutable text/flags out of the framework callback.
            let text = value?.bestTranscription.formattedString
            let final = value?.isFinal == true
            let failed = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == id else { return }
                if let text { self.latest = text }
                #if PRTS_DEV
                if let text {
                    RecordingStore.shared.event(
                        "speech_recognized",
                        details: [
                            "utteranceID": id.uuidString, "text": text, "final": String(final),
                        ],
                        generation: recordingGeneration
                    )
                }
                #endif
                if final {
                    self.complete(self.textResult())
                } else if failed {
                    self.complete(.failure(RecognitionError.unavailable))
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            cancel()
            throw error
        }
    }

    /// Stop capture immediately on release; allow the recognizer to finalize the last word.
    func endCapture() {
        guard !endedAudio else { return }
        endedAudio = true
        stopMicrophone()
        request?.endAudio()
    }

    func finish() async throws -> String {
        endCapture()
        if let result { return try result.get() }
        let id = generation
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter = continuation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self, self.generation == id else { return }
                    self.complete(self.textResult())
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.generation == id else { return }
                self?.cancel()
            }
        }
    }

    func cancel() {
        generation = UUID()
        stopMicrophone()
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        request = nil
        speechRecognizer = nil
        latest = ""
        result = nil
        endedAudio = false
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }

    private func textResult() -> Result<String, Error> {
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failure(RecognitionError.noSpeech) : .success(text)
    }

    private func complete(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        stopMicrophone()
        timeout?.cancel()
        timeout = nil
        waiter?.resume(with: value)
        waiter = nil
    }

    private func stopMicrophone() {
        engine.stop()
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        #if PRTS_DEV
        recording?.finish()
        recording = nil
        #endif
        audioSession.release(audioLease)
        audioLease = nil
    }
}
