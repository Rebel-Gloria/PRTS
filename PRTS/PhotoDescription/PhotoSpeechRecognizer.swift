import AVFoundation
import Speech

/// A single push-to-talk utterance. Audio buffers go only to native recognition;
/// no audio file is created. The coordinator owns permission and gesture lifetime.
@MainActor
final class PhotoSpeechRecognizer {
    enum RecognitionError: LocalizedError {
        case unavailable, noSpeech, microphoneUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "语音识别暂不可用"
            case .noSpeech: "没有听清，请重新长按提问"
            case .microphoneUnavailable: "麦克风不可用"
            }
        }
    }
    private let engine = AVAudioEngine()
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

    static var authorized: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized &&
        AVAudioApplication.shared.recordPermission == .granted
    }

    static func requestPermissions() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech, !Task.isCancelled else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }

    func start() throws {
        cancel()
        let id = UUID(); generation = id
        guard Self.authorized, let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.isAvailable else { throw RecognitionError.unavailable }
        speechRecognizer = recognizer
        let audio = AVAudioSession.sharedInstance()
        try audio.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        try audio.setActive(true)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            cancel(); throw RecognitionError.microphoneUnavailable
        }
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
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
                if final {
                    self.complete(self.textResult())
                } else if failed {
                    self.complete(.failure(RecognitionError.unavailable))
                }
            }
        }
        do { engine.prepare(); try engine.start() }
        catch { cancel(); throw error }
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
        timeout?.cancel(); timeout = nil
        task?.cancel(); task = nil
        request = nil; speechRecognizer = nil; latest = ""; result = nil; endedAudio = false
        waiter?.resume(throwing: CancellationError()); waiter = nil
    }

    private func textResult() -> Result<String, Error> {
        let text = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .failure(RecognitionError.noSpeech) : .success(text)
    }

    private func complete(_ value: Result<String, Error>) {
        guard result == nil else { return }
        result = value
        stopMicrophone()
        timeout?.cancel(); timeout = nil
        waiter?.resume(with: value); waiter = nil
    }

    private func stopMicrophone() {
        engine.stop()
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }
}
