import Combine
import Foundation

@MainActor
final class LiveCaptionSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isAnnouncing = false
    @Published private(set) var message = ""
    var suspendsFeedback: Bool { isRunning || isAnnouncing }

    private var press = LiveCaptionPressState()
    private let audio: any PhotoAnswerAudio
    private let services: PhotoDescriptionServices
    private let describeChange: @Sendable (Data, String, String?, String) async throws -> String
    private let sleep: (TimeInterval) async throws -> Void
    private(set) var work: Task<Void, Never>?
    private var imageTask: Task<Data, Error>?
    private var speech: (startedAt: TimeInterval, characters: Int)?
    private var speechWaiter: CheckedContinuation<Void, Never>?
    private var charactersPerSecond = LiveCaptionPolicy.initialCharactersPerSecond

    convenience init() {
        self.init(audio: PhotoAudioOutput(), services: .init())
    }

    init(
        audio: any PhotoAnswerAudio,
        services: PhotoDescriptionServices,
        describeChange: @escaping @Sendable (Data, String, String?, String) async throws -> String =
            {
                try await PhotoDescriptionBackend.caption(
                    jpeg: $0,
                    opening: $1,
                    previous: $2,
                    key: $3
                )
            },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.audio = audio
        self.services = services
        self.describeChange = describeChange
        self.sleep = sleep
        audio.onFinished = { [weak self] in self?.speechFinished() }
    }

    func down() -> LiveCaptionPressState.Action {
        press.down(at: services.now())
    }

    func cancelPress() {
        press.cancelPress()
    }

    func announce(_ text: String) {
        audio.stop()
        isAnnouncing = true
        do { try audio.speak(text) } catch { fail(error) }
    }

    func interruptAnnouncement() {
        if isAnnouncing {
            audio.stop()
            isAnnouncing = false
        }
        message = ""
    }

    func start(snapshot: @escaping () -> FrameSnapshot?) {
        let now = services.now
        start(capture: {
            guard let frame = snapshot(), now() - frame.receivedAt < 1 else {
                throw PhotoChatError.emptyInput
            }
            return Task.detached(priority: .userInitiated) {
                try PhotoImageEncoder.jpeg(frame: frame)
            }
        })
    }

    func start(capture: @escaping () throws -> Task<Data, Error>) {
        interruptAnnouncement()
        var key = ""
        if !services.onDevice() {
            guard services.uploadAllowed() else {
                stop()
                message = "先在设置里允许发送照片"
                return
            }
            do {
                guard let credential = try services.credential(), !credential.isEmpty else {
                    throw PhotoChatError.missingKey
                }
                key = credential
            } catch {
                fail(error)
                return
            }
        }
        isRunning = true
        charactersPerSecond = LiveCaptionPolicy.initialCharactersPerSecond
        work = Task {
            do {
                try await run(capture: capture, key: key)
            } catch {
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    func stop() {
        work?.cancel()
        work = nil
        imageTask?.cancel()
        imageTask = nil
        audio.stop()
        speech = nil
        speechWaiter?.resume()
        speechWaiter = nil
        isRunning = false
        isAnnouncing = false
        press = LiveCaptionPressState()
        message = ""
    }

    private func run(capture: () throws -> Task<Data, Error>, key: String) async throws {
        let comparison = LiveCaptionImageComparison()
        let jpeg = try await image(capture)
        _ = try await comparison.accept(jpeg)
        var lastRequest = services.now()
        let opening = try await services.describe(jpeg, nil, key)
        try Task.checkCancellation()
        var modelDuration = services.now() - lastRequest
        try say(opening)
        var previous: String?

        while true {
            let speechEnd = speech.map {
                $0.startedAt + Double($0.characters) / charactersPerSecond
            }
            let requestTime = LiveCaptionPolicy.requestTime(
                now: services.now(),
                lastRequest: lastRequest,
                speechEnd: speechEnd,
                modelDuration: modelDuration
            )
            try await wait(until: requestTime)
            var windowStart = services.now()
            var jpeg = try await image(capture)
            while try await !comparison.accept(jpeg) {
                let now = services.now()
                if now >= windowStart + LiveCaptionPolicy.changeWindow { windowStart = now }
                try await wait(
                    until: LiveCaptionPolicy.nextCheck(now: now, windowStart: windowStart)
                )
                jpeg = try await image(capture)
            }
            lastRequest = services.now()
            let response = try await describeChange(jpeg, opening, previous, key)
            try Task.checkCancellation()
            modelDuration = services.now() - lastRequest
            if let answer = LiveCaptionPolicy.answer(response, previous: previous) {
                if speech != nil {
                    await withCheckedContinuation { speechWaiter = $0 }
                }
                try Task.checkCancellation()
                try say(answer)
                previous = answer
            }
        }
    }

    private func image(_ capture: () throws -> Task<Data, Error>) async throws -> Data {
        let task = try capture()
        imageTask = task
        defer { imageTask = nil }
        return try await task.value
    }

    private func wait(until time: TimeInterval) async throws {
        let delay = time - services.now()
        if delay > 0 { try await sleep(delay) }
        // The injected sleep need not throw on cancellation, so a stop during the wait ends here.
        try Task.checkCancellation()
    }

    private func say(_ text: String) throws {
        try audio.speak(text)
        speech = (services.now(), text.count)
    }

    private func speechFinished() {
        if let speech {
            charactersPerSecond = LiveCaptionPolicy.updatedSpeechRate(
                charactersPerSecond,
                characters: speech.characters,
                duration: services.now() - speech.startedAt
            )
            self.speech = nil
            speechWaiter?.resume()
            speechWaiter = nil
        } else {
            isAnnouncing = false
            audio.stop()
        }
    }

    private func fail(_ error: Error) {
        stop()
        message = error.localizedDescription
    }
}
