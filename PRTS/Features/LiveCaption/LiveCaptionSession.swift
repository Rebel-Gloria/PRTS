import ARKit
import Combine
import Foundation

/// Coordinates photo-button multi-press arbitration, sampling, requests and speech; ordinary
/// photo-button events also pass through this session first.
@MainActor
final class LiveCaptionSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var isAnnouncing = false
    @Published private(set) var message = ""
    var suspendsFeedback: Bool { isRunning || isAnnouncing }

    var localized: (String) -> String = { String(localized: String.LocalizationValue($0)) }

    private var press = LiveCaptionPressState()
    private var pressTimer: Task<Void, Never>?
    private let audio: any AnswerAudio
    private let services: LiveCaptionServices
    private let credential: (String) throws -> String?
    private let describeOpening: @Sendable (Data, String) async throws -> String
    private let describeChange: @Sendable ([Data], String?, String) async throws -> String
    private let sleep: (TimeInterval) async throws -> Void
    private(set) var work: Task<Void, Never>?
    private var sampling: Task<Void, Never>?
    private var requests: [Int: Task<Void, Never>] = [:]
    private var lastRequestID = 0
    private var newestAnswerID = 0
    private var consecutiveFailures = 0
    private var isSpeaking = false
    /// The newest answer waiting for the current sentence to end; older ones are never read.
    private var waitingAnswer: String?
    private var previous: String?

    convenience init() {
        self.init(audio: AnswerAudioOutput(), services: .init())
    }

    init(
        audio: any AnswerAudio,
        services: LiveCaptionServices,
        credential: @escaping (String) throws -> String? = {
            try PhotoCredentialStore.read(account: $0)
        },
        describeOpening: @escaping @Sendable (Data, String) async throws -> String = {
            try await LiveCaptionBackend.captionOpening(jpeg: $0, key: $1)
        },
        describeChange: @escaping @Sendable ([Data], String?, String) async throws -> String = {
            try await LiveCaptionBackend.caption(video: $0, previous: $1, key: $2)
        },
        sleep: @escaping (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.audio = audio
        self.services = services
        self.credential = credential
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
        do {
            try audio.speak(text)
        } catch {
            services.errors.record(error)
            audio.stop()
            isAnnouncing = false
            message = error.localizedDescription
        }
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
            let sampledAt = now()
            return Task.detached(priority: .userInitiated) {
                try LiveCaptionFrame.capture(
                    image: PhotoImageEncoder.image(
                        pixelBuffer: frame.frame.capturedImage,
                        orientation: frame.orientation
                    ),
                    sampledAt: sampledAt
                )
            }
        })
    }

    func start(capture: @escaping () throws -> Task<LiveCaptionFrame, Error>) {
        interruptAnnouncement()
        guard services.uploadAllowed() else {
            stop()
            message = localized("photo.message.allowUpload")
            announce(message)
            return
        }
        let key: String
        do {
            if let savedKey = try credential(PhotoChatProvider.qwen.keyAccount), !savedKey.isEmpty {
                key = savedKey
            } else {
                announce(localized("liveCaption.requiresQwen"))
                return
            }
        } catch {
            fail(error)
            return
        }
        isRunning = true
        do { try say(localized("liveCaption.on")) } catch {
            fail(error)
            return
        }
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
        requests.values.forEach { $0.cancel() }
        requests = [:]
        lastRequestID = 0
        newestAnswerID = 0
        consecutiveFailures = 0
        audio.stop()
        isSpeaking = false
        waitingAnswer = nil
        previous = nil
        isRunning = false
        isAnnouncing = false
        cancelPress()
        message = ""
    }

    private func run(
        capture: @escaping () throws -> Task<LiveCaptionFrame, Error>,
        key: String
    ) async throws {
        let stream = AsyncThrowingStream<[LiveCaptionFrame], Error>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        let sampler = Task {
            var frames: [LiveCaptionFrame] = []
            do {
                while !Task.isCancelled {
                    let sampledAt = services.now()
                    let task = try capture()
                    let frame = try await withTaskCancellationHandler {
                        try await task.value
                    } onCancel: {
                        task.cancel()
                    }
                    frames.append(frame)
                    frames.removeAll { frame.sampledAt - $0.sampledAt >= LiveCaptionPolicy.window }
                    if frames.count > LiveCaptionPolicy.maximumSamples { frames.removeFirst() }
                    stream.continuation.yield(frames)
                    try await wait(until: sampledAt + LiveCaptionPolicy.sampleInterval)
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
        do {
            let opening = try await skippingOverlong {
                try await describeOpening(first[0].jpeg, key)
            }
            try Task.checkCancellation()
            consecutiveFailures = 0
            if let opening { try present(opening) }
        } catch let error where !Task.isCancelled {
            requestFailed(error)
        }

        var carried: LiveCaptionFrame?
        var nextRequest = services.now()
        while !Task.isCancelled {
            nextRequest = max(nextRequest + LiveCaptionPolicy.requestInterval, services.now())
            try await wait(until: nextRequest)
            guard let frames = try await images.next() else { return }
            let now = services.now()
            let fresh = frames.filter {
                now - $0.sampledAt < LiveCaptionPolicy.window
                    && $0.sampledAt > (carried?.sampledAt ?? -.infinity)
            }
            let video = [carried].compactMap { $0 } + LiveCaptionFrame.select(fresh)
            guard video.count >= LiveCaptionPolicy.minimumVideoFrames,
                requests.count < LiveCaptionPolicy.maximumRequestsInFlight
            else { continue }
            carried = video.last
            send(video.map(\.jpeg), key: key)
        }
    }

    private func send(_ video: [Data], key: String) {
        lastRequestID += 1
        let id = lastRequestID
        let previous = previous
        let describeChange = describeChange
        requests[id] = Task {
            do {
                let response = try await skippingOverlong {
                    try await describeChange(video, previous, key)
                }
                try Task.checkCancellation()
                requests[id] = nil
                consecutiveFailures = 0
                guard let response else { return }
                try receive(response, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                requests[id] = nil
                requestFailed(error)
            }
        }
    }

    private func requestFailed(_ error: Error) {
        consecutiveFailures += 1
        if consecutiveFailures < LiveCaptionPolicy.maximumConsecutiveFailures {
            services.errors.record(error)
        } else {
            fail(error)
        }
    }

    /// Requests overlap and can return out of order; an answer older than one already handled
    /// describes something that has passed.
    private func receive(_ response: String, id: Int) throws {
        guard id > newestAnswerID else { return }
        newestAnswerID = id
        if let answer = LiveCaptionPolicy.answer(response, previous: previous) {
            try present(answer)
        }
    }

    /// Captions must stay short: an answer over the token budget is skipped like any other
    /// overlong line, and the session keeps running.
    private func skippingOverlong(_ request: () async throws -> String) async throws -> String? {
        do {
            return try await request()
        } catch PhotoChatError.answerTooLong {
            return nil
        }
    }

    private func wait(until time: TimeInterval) async throws {
        let delay = time - services.now()
        if delay > 0 { try await sleep(delay) }
    }

    private func present(_ text: String) throws {
        if isSpeaking {
            waitingAnswer = text
        } else {
            previous = text
            try say(text)
        }
    }

    private func say(_ text: String) throws {
        try audio.speak(text)
        isSpeaking = true
    }

    private func speechFinished() {
        guard isSpeaking else {
            isAnnouncing = false
            audio.stop()
            return
        }
        isSpeaking = false
        guard let answer = waitingAnswer else { return }
        waitingAnswer = nil
        do { try present(answer) } catch { fail(error) }
    }

    private func fail(_ error: Error) {
        services.errors.record(error)
        stop()
        message = error.localizedDescription
        announce(message)
    }
}
