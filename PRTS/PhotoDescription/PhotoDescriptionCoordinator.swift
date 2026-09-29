import Foundation
import Combine

/// Owns one interaction from press through answer playback. Generation checks keep
/// cancellation, delayed permission callbacks and stale network results from speaking.
@MainActor
final class PhotoDescriptionCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message = ""
    private var press = PhotoPressState()
    private var timer: Task<Void, Never>?
    private(set) var work: Task<Void, Never>?
    private var imageTask: Task<Data, Error>?
    private var generation = UUID()
    private var captureOperation: (() throws -> Task<Data, Error>)?
    private var key = ""
    private let recognizer: any PhotoRecognizing
    private let audio: any PhotoAnswerAudio
    private let services: PhotoDescriptionServices

    convenience init() {
        self.init(recognizer: PhotoSpeechRecognizer(), audio: PhotoAudioOutput(), services: .init())
    }

    init(recognizer: any PhotoRecognizing,
         audio: any PhotoAnswerAudio,
         services: PhotoDescriptionServices) {
        self.recognizer = recognizer
        self.audio = audio
        self.services = services
        audio.onFinished = { [weak self] in self?.cancel(clearMessage: true) }
    }

    func down(snapshot: @escaping () -> FrameSnapshot?, silence: () -> Void) {
        let now = services.now
        down(capture: {
            guard let frame = snapshot(), now() - frame.receivedAt < 1 else {
                throw PhotoChatError.emptyInput
            }
            return Task.detached(priority: .userInitiated) {
                try Task.checkCancellation()
                let data = try PhotoImageEncoder.jpeg(frame: frame)
                try Task.checkCancellation()
                return data
            }
        }, silence: silence)
    }

    func down(capture: @escaping () throws -> Task<Data, Error>, silence: () -> Void) {
        guard !busy else { return }
        guard services.uploadAllowed() else {
            message = "请在设置 → 拍照描述中允许发送图片"; return
        }
        do {
            guard let credential = try services.credential(), !credential.isEmpty else {
                throw PhotoChatError.missingKey
            }
            key = credential
        } catch { message = error.localizedDescription; return }
        silence()
        generation = UUID()
        captureOperation = capture
        busy = true; message = "松手描述，长按提问"
        press.begin(at: services.now())
        let id = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.generation == id else { return }
            self.advancePress()
        }
    }

    /// Timer and deterministic tests use the same transition; the clock is authoritative.
    func advancePress() {
        if press.advance(to: services.now()) == .startRecording { startRecording() }
    }

    func up() {
        timer?.cancel(); timer = nil
        let actions = press.release(at: services.now())
        for action in actions {
            switch action {
            case .shortCapture:
                do {
                    try capture()
                    try audio.cue(.submit)
                    submit(question: PhotoChatProtocol.prompt)
                } catch { fail(error) }
            case .startRecording: startRecording()
            case .stopRecording:
                guard imageTask != nil else { return }
                recognizer.endCapture()
                do { try audio.cue(.submit) } catch { fail(error); return }
                message = "正在识别提问"
                let id = generation
                work = Task { [weak self] in
                    guard let self else { return }
                    do {
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
    }

    func cancel(clearMessage: Bool = true) {
        generation = UUID()
        press.cancel(); timer?.cancel(); timer = nil
        work?.cancel(); work = nil
        imageTask?.cancel(); imageTask = nil
        recognizer.cancel(); audio.stop()
        captureOperation = nil; key = ""; busy = false
        if clearMessage { message = "" }
    }

    private func capture() throws {
        guard let captureOperation else { throw PhotoChatError.emptyInput }
        self.captureOperation = nil
        imageTask = try captureOperation()
    }

    private func startRecording() {
        guard services.speechAuthorized() else {
            cancel()
            message = "请允许麦克风和语音识别，然后重新长按"
            let id = generation
            work = Task { [weak self] in
                let granted = await self?.services.requestSpeechPermission() ?? false
                guard let self, self.generation == id else { return }
                self.message = granted ? "已授权，请重新长按提问" : "请在系统设置中允许麦克风和语音识别"
            }
            return
        }
        do {
            try capture()
            try audio.cue(.record)
            try recognizer.start()
            message = "请说话，松手发送"
        } catch { fail(error) }
    }

    private func submit(question: String) {
        guard let imageTask else { return }
        let id = generation, credential = key, describe = services.describe
        key = ""; message = "正在描述"
        work = Task { [weak self] in
            do {
                let jpeg = try await imageTask.value
                try Task.checkCancellation()
                let answer = try await describe(jpeg, question, credential)
                try Task.checkCancellation()
                guard let self, self.generation == id else { return }
                self.imageTask = nil
                self.recognizer.cancel()
                self.message = "正在朗读"
                try self.audio.speak(answer)
            } catch {
                guard let self, self.generation == id else { return }
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        cancel()
        if !(error is CancellationError) { message = error.localizedDescription }
    }
}
