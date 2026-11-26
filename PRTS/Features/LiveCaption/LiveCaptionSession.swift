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
    private var feedbackEnabled = true
    private var feedbackGeneration: UInt64 = 0
    private var interactionID = UUID()
    private var recordingGeneration: UInt64 = 0

    func setFeedbackEnabled(_ enabled: Bool) {
        guard feedbackEnabled != enabled else { return }
        feedbackEnabled = enabled
        feedbackGeneration &+= 1
        guard !enabled else { return }
        audio.stop()
        isSpeaking = false
        isAnnouncing = false
        waitingAnswer = nil
    }

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
        guard feedbackEnabled else { return }
        isAnnouncing = true
        do {
            try withRecordingContext { try audio.speak(text) }
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
            if let savedKey = try credential(PhotoChatService.qwen.keyAccount), !savedKey.isEmpty {
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
        interactionID = UUID()
        recordingGeneration = DevInteractionRecording.currentGeneration
        DevInteractionRecording.event(
            "interaction_started",
            details: ["feature": "liveCaption", "interactionID": interactionID.uuidString],
            generation: recordingGeneration
        )
        do {
            try withRecordingContext(id: interactionID) {
                try say(localized("liveCaption.on"))
            }
        } catch {
            fail(error)
            return
        }
        withRecordingContext(id: interactionID) {
            work = Task {
                do {
                    try await run(capture: capture, key: key)
                } catch {
                    if !Task.isCancelled { fail(error) }
                }
            }
        }
    }

    func shutdown() async {
        let pending = Array(requests.values) + [work, sampling, pressTimer].compactMap { $0 }
        stop()
        for task in pending { await task.value }
    }

    func stop() {
        if isRunning {
            DevInteractionRecording.event(
                "interaction_ended",
                details: ["feature": "liveCaption", "interactionID": interactionID.uuidString],
                generation: recordingGeneration
            )
        }
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
                    let frame: LiveCaptionFrame
                    do {
                        let task = try capture()
                        frame = try await withTaskCancellationHandler {
                            try await task.value
                        } onCancel: {
                            task.cancel()
                        }
                    } catch PhotoChatError.emptyInput {
                        // iOS may interrupt the camera in the background. Keep the request
                        // coordinator alive and wait for a fresh frame after capture resumes.
                        try await wait(until: sampledAt + LiveCaptionPolicy.sampleInterval)
                        continue
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
        recordSelection(first.prefix(1), phase: "opening")
        let openingFeedbackGeneration = feedbackGeneration
        do {
            let opening = try await skippingOverlong {
                try await describeOpening(first[0].jpeg, key)
            }
            try Task.checkCancellation()
            consecutiveFailures = 0
            if let opening, feedbackEnabled, feedbackGeneration == openingFeedbackGeneration {
                try present(opening)
            }
        } catch let error where !Task.isCancelled {
            requestFailed(
                error,
                mayAnnounce: feedbackEnabled && feedbackGeneration == openingFeedbackGeneration
            )
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
            guard let firstFresh = fresh.first else { continue }
            if let last = carried, firstFresh.sampledAt - last.sampledAt > LiveCaptionPolicy.window
            {
                carried = nil
            }
            guard requests.count < LiveCaptionPolicy.maximumRequestsInFlight else { continue }
            let video = [carried].compactMap { $0 } + LiveCaptionFrame.select(fresh)
            guard video.count >= LiveCaptionPolicy.minimumVideoFrames else { continue }
            carried = video.last
            send(video, key: key)
        }
    }

    private func send(_ frames: [LiveCaptionFrame], key: String) {
        let video = frames.map(\.jpeg)
        lastRequestID += 1
        let id = lastRequestID
        let previous = previous
        let describeChange = describeChange
        let requestFeedbackGeneration = feedbackGeneration
        let generation = recordingGeneration
        recordSelection(frames, phase: "change")
        requests[id] = Task {
            do {
                let response = try await skippingOverlong {
                    try await describeChange(video, previous, key)
                }
                try Task.checkCancellation()
                requests[id] = nil
                consecutiveFailures = 0
                guard let response else { return }
                DevInteractionRecording.event(
                    "interaction_result",
                    details: [
                        "feature": "liveCaption", "requestID": String(id), "answer": response,
                    ],
                    generation: generation
                )
                guard feedbackEnabled, feedbackGeneration == requestFeedbackGeneration else {
                    return
                }
                try receive(response, id: id)
            } catch {
                guard !Task.isCancelled else { return }
                requests[id] = nil
                requestFailed(
                    error,
                    mayAnnounce: feedbackEnabled && feedbackGeneration == requestFeedbackGeneration
                )
            }
        }
    }

    private func requestFailed(_ error: Error, mayAnnounce: Bool = true) {
        consecutiveFailures += 1
        if consecutiveFailures < LiveCaptionPolicy.maximumConsecutiveFailures {
            services.errors.record(error)
        } else {
            fail(error, mayAnnounce: mayAnnounce)
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
        guard feedbackEnabled else { return }
        if isSpeaking {
            waitingAnswer = text
        } else {
            previous = text
            try say(text)
        }
    }

    private func say(_ text: String) throws {
        guard feedbackEnabled else { return }
        try withRecordingContext { try audio.speak(text) }
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
        do {
            try withRecordingContext { try present(answer) }
        } catch { fail(error) }
    }

    private func fail(_ error: Error, mayAnnounce: Bool = true) {
        services.errors.record(error)
        stop()
        message = error.localizedDescription
        if mayAnnounce { announce(message) }
    }

    private func withRecordingContext<T>(
        id: UUID? = nil,
        _ body: () throws -> T
    ) rethrows -> T {
        #if PRTS_DEV
        if let id {
            return try DevInteractionRecording.$interactionID.withValue(id.uuidString) {
                try DevInteractionRecording.$recordingGeneration.withValue(
                    recordingGeneration,
                    operation: body
                )
            }
        }
        let token = DevInteractionRecording.recordingGeneration ?? recordingGeneration
        return try DevInteractionRecording.$recordingGeneration.withValue(token, operation: body)
        #else
        return try body()
        #endif
    }

    private func recordSelection(_ frames: some Collection<LiveCaptionFrame>, phase: String) {
        #if PRTS_DEV
        for (index, frame) in frames.enumerated() {
            RecordingStore.shared.event(
                "live_caption_frame_selected",
                details: [
                    "phase": phase, "frameIndex": String(index),
                    "interactionID": interactionID.uuidString,
                    "sampledAt": String(frame.sampledAt),
                    "sourceFrameID": frame.sourceFrameID.map(String.init) ?? "unavailable",
                    "sourceTimestamp": frame.sourceTimestamp.map { String($0) } ?? "unavailable",
                ],
                generation: recordingGeneration
            )
        }
        #endif
    }
}
