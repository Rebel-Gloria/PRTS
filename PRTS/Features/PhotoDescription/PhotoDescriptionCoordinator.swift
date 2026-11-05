import ARKit
import Combine
import Foundation

/// Owns one interaction from press through answer playback. Generation checks keep
/// cancellation, delayed permission callbacks and stale network results from speaking.
@MainActor
final class PhotoDescriptionCoordinator: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var isAnnouncing = false
    @Published private(set) var message = ""
    private var press = PhotoPressState()
    private var timer: Task<Void, Never>?
    private(set) var work: Task<Void, Never>?
    private var imageTask: Task<Data, Error>?
    private var generation = UUID()
    private var captureOperation: ((CGFloat) throws -> Task<Data, Error>)?
    private var key = ""
    private let recognizer: any PhotoRecognizing
    private let audio: any AnswerAudio
    private let services: PhotoDescriptionServices

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
        audio.onFinished = { [weak self] in self?.cancel(clearMessage: true) }
    }

    func down(snapshot: @escaping () -> FrameSnapshot?, silence: () -> Void) {
        down(capture: captureOperation(snapshot: snapshot), silence: silence)
    }

    func perform(
        _ action: PhotoPressState.Action,
        snapshot: @escaping () -> FrameSnapshot?,
        silence: () -> Void
    ) -> Bool {
        perform(action, capture: captureOperation(snapshot: snapshot), silence: silence)
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

    private func captureOperation(
        snapshot: @escaping () -> FrameSnapshot?
    ) -> (CGFloat) throws -> Task<Data, Error> {
        let now = services.now
        return { longestSide in
            guard let frame = snapshot(), now() - frame.receivedAt < 1 else {
                throw PhotoChatError.emptyInput
            }
            return Task.detached(priority: .userInitiated) {
                try PhotoImageEncoder.jpeg(
                    pixelBuffer: frame.frame.capturedImage,
                    orientation: frame.orientation,
                    longestSide: longestSide
                )
            }
        }
    }

    func down(capture: @escaping (CGFloat) throws -> Task<Data, Error>, silence: () -> Void) {
        guard prepare(capture: capture, silence: silence) else { return }
        press.begin(at: services.now())
        let id = generation
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
            guard let self, self.generation == id else { return }
            self.advancePress()
        }
    }

    private func prepare(
        capture: @escaping (CGFloat) throws -> Task<Data, Error>,
        silence: () -> Void
    ) -> Bool {
        guard !busy else { return false }
        silence()
        generation = UUID()
        captureOperation = capture
        busy = true
        message = "松手描述，长按提问"
        return true
    }

    private func prepareService(for feature: IntelligenceFeature) -> Bool {
        if !services.onDevice(feature) {
            guard services.uploadAllowed() else {
                cancel()
                message = "先在设置里允许发送照片"
                return false
            }
            do {
                guard let credential = try services.credential(feature), !credential.isEmpty else {
                    throw PhotoChatError.missingKey
                }
                key = credential
            } catch {
                services.errors.record(error)
                cancel()
                message = error.localizedDescription
                return false
            }
        }
        return true
    }

    /// Timer and deterministic tests use the same transition; the clock is authoritative.
    func advancePress() {
        if press.advance(to: services.now()) == .startRecording { startRecording() }
    }

    func up() {
        timer?.cancel()
        timer = nil
        for action in press.release(at: services.now()) { perform(action) }
    }

    private func perform(_ action: PhotoPressState.Action) {
        switch action {
        case .shortCapture:
            if !prepareService(for: .description) { return }
            do {
                try capture(purpose: .description)
                try audio.cue(.submit)
                submit(question: nil)
            } catch { fail(error) }
        case .startRecording: startRecording()
        case .stopRecording:
            guard imageTask != nil else { return }
            recognizer.endCapture()
            do { try audio.cue(.submit) } catch {
                fail(error)
                return
            }
            message = "正在识别"
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

    func cancel(clearMessage: Bool = true) {
        generation = UUID()
        press.cancel()
        timer?.cancel()
        timer = nil
        work?.cancel()
        work = nil
        imageTask?.cancel()
        imageTask = nil
        recognizer.cancel()
        audio.stop()
        captureOperation = nil
        key = ""
        busy = false
        isAnnouncing = false
        if clearMessage { message = "" }
    }

    private func capture(purpose: PhotoImagePurpose) throws {
        guard let captureOperation else { throw PhotoChatError.emptyInput }
        self.captureOperation = nil
        imageTask = try captureOperation(
            purpose.longestSide(highResolution: services.highResolution())
        )
    }

    private func startRecording() {
        if !prepareService(for: .question) { return }
        guard services.speechAuthorized() else {
            cancel()
            message = "需要麦克风权限，允许后再长按"
            let id = generation
            work = Task { [weak self] in
                let granted = await self?.services.requestSpeechPermission() ?? false
                guard let self, self.generation == id else { return }
                self.message = granted ? "已授权，再长按提问" : "请在设置里允许麦克风"
            }
            return
        }
        do {
            try capture(purpose: .question)
            try audio.cue(.record)
            try recognizer.start()
            message = "请说话，松手发送"
        } catch { fail(error) }
    }

    private func submit(question: String?) {
        guard let imageTask else { return }
        let id = generation
        let credential = key
        let describe = services.describe
        key = ""
        message = "正在描述"
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
        guard !(error is CancellationError) else { return }
        services.errors.record(error)
        if let failure = error as? PhotoChatError, case .incompleteStream = failure {
            isAnnouncing = true
        }
        message = error.localizedDescription
        if isAnnouncing {
            busy = true
            do {
                try audio.speak(message)
            } catch {
                services.errors.record(error)
                audio.stop()
                busy = false
                isAnnouncing = false
            }
        }
    }
}
