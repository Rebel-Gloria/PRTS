import Combine
import Foundation

@MainActor
final class LiveCaptionSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isAnnouncing = false
    @Published private(set) var message = ""
    var suspendsFeedback: Bool { isRunning || isAnnouncing }

    var localized: (String) -> String = { String(localized: String.LocalizationValue($0)) }

    private var press = LiveCaptionPressState()
    private var pressTimer: Task<Void, Never>?
    private let audio: any PhotoAnswerAudio
    private let services: PhotoDescriptionServices
    private let provider: () -> PhotoChatProvider
    private let describeOpening: @Sendable (Data, String) async throws -> String
    private let describeChange: @Sendable ([Data], String?, String) async throws -> String
    private let sleep: (TimeInterval) async throws -> Void
    private(set) var work: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    private var speech: (startedAt: TimeInterval, characters: Int)?
    private var speechWaiter: CheckedContinuation<Void, Never>?
    private var charactersPerSecond = LiveCaptionPolicy.initialCharactersPerSecond

    convenience init() {
        self.init(audio: PhotoAudioOutput(), services: .init())
    }

    init(
        audio: any PhotoAnswerAudio,
        services: PhotoDescriptionServices,
        provider: @escaping () -> PhotoChatProvider = { PhotoChatProvider.current() },
        describeOpening: @escaping @Sendable (Data, String) async throws -> String = {
            try await PhotoDescriptionBackend.captionOpening(jpeg: $0, key: $1)
        },
        describeChange: @escaping @Sendable ([Data], String?, String) async throws -> String = {
            try await PhotoDescriptionBackend.caption(video: $0, previous: $1, key: $2)
        },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.audio = audio
        self.services = services
        self.provider = provider
        self.describeOpening = describeOpening
        self.describeChange = describeChange
        self.sleep = sleep
        audio.onFinished = { [weak self] in self?.speechFinished() }
    }

    func down(perform: @escaping (LiveCaptionPressState.Action) -> Void) {
        for action in press.down(at: services.now(), running: isRunning) { perform(action) }
        schedulePress(perform: perform)
    }

    func up(perform: @escaping (LiveCaptionPressState.Action) -> Void) {
        for action in press.up(at: services.now()) { perform(action) }
        schedulePress(perform: perform)
    }

    func cancelPress() {
        pressTimer?.cancel()
        pressTimer = nil
        press.cancel()
    }

    private func schedulePress(perform: @escaping (LiveCaptionPressState.Action) -> Void) {
        pressTimer?.cancel()
        guard let deadline = press.deadline else { return }
        pressTimer = Task {
            do {
                try await Task.sleep(for: .seconds(deadline - services.now()))
            } catch { return }
            for action in press.advance(to: services.now()) { perform(action) }
            schedulePress(perform: perform)
        }
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
        guard provider() == .qwen else {
            announce(localized("liveCaption.requiresQwen"))
            return
        }
        guard services.uploadAllowed() else {
            stop()
            message = "先在设置里允许发送照片"
            return
        }
        let key: String
        do {
            guard let credential = try services.credential(), !credential.isEmpty else {
                throw PhotoChatError.missingKey
            }
            key = credential
        } catch {
            fail(error)
            return
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
        sampling?.cancel()
        sampling = nil
        audio.stop()
        speech = nil
        speechWaiter?.resume()
        speechWaiter = nil
        isRunning = false
        isAnnouncing = false
        cancelPress()
        message = ""
    }

    private func run(
        capture: @escaping () throws -> Task<Data, Error>,
        key: String
    ) async throws {
        let stream = AsyncThrowingStream<[Data], Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let sampler = Task {
            var frames: [Data] = []
            do {
                while !Task.isCancelled {
                    let sampledAt = services.now()
                    let task = try capture()
                    let jpeg = try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    frames.append(jpeg)
                    if frames.count > 4 { frames.removeFirst() }
                    stream.continuation.yield(frames)
                    try await wait(until: sampledAt + 1)
                }
                stream.continuation.finish()
            } catch {
                stream.continuation.finish(throwing: error)
            }
        }
        sampling = sampler
        defer { sampler.cancel() }
        var images = stream.stream.makeAsyncIterator()
        guard let first = try await images.next() else { return }
        let comparison = LiveCaptionImageComparison()
        _ = try await comparison.accept(first[0])
        var lastRequest = services.now()
        let opening = try await describeOpening(first[0], key)
        try Task.checkCancellation()
        var modelDuration = services.now() - lastRequest
        try say(opening)
        var previous: String? = opening

        while !Task.isCancelled {
            let speechEnd = speech.map {
                $0.startedAt + Double($0.characters) / charactersPerSecond
            }
            try await wait(
                until: LiveCaptionPolicy.requestTime(
                    now: services.now(),
                    lastRequest: lastRequest,
                    speechEnd: speechEnd,
                    modelDuration: modelDuration
                )
            )
            guard let frames = try await images.next() else { return }
            if frames.count < 4 { continue }
            if try await !comparison.accept(frames[3]) { continue }
            lastRequest = services.now()
            let response = try await describeChange(frames, previous, key)
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

    private func wait(until time: TimeInterval) async throws {
        let delay = time - services.now()
        if delay > 0 { try await sleep(delay) }
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
