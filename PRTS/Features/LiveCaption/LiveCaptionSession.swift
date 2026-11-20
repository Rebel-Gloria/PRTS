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
    #if PRTS_DEV
    private var recordingGeneration: UInt64 = 0
    private var waitingAnswerRecordingGeneration: UInt64?
    #endif

    func setFeedbackEnabled(_ enabled: Bool) {
        guard feedbackEnabled != enabled else { return }
        feedbackEnabled = enabled
        feedbackGeneration &+= 1
        guard !enabled else { return }
        audio.stop()
        isSpeaking = false
        isAnnouncing = false
        waitingAnswer = nil
        #if PRTS_DEV
        waitingAnswerRecordingGeneration = nil
        #endif
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
            #if PRTS_DEV
            try DevInteractionRecording.$recordingGeneration.withValue(recordingGeneration) {
                try audio.speak(text)
            }
            #else
            try audio.speak(text)
            #endif
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
        interactionID = UUID()
        #if PRTS_DEV
        recordingGeneration = RecordingStore.shared.admissionGeneration
        let recordingGeneration = self.recordingGeneration
        let recordingInteractionID = interactionID.uuidString
        RecordingStore.shared.event(
            "interaction_started",
            details: ["feature": "liveCaption", "interactionID": interactionID.uuidString],
            generation: recordingGeneration
        )
        #endif
        do { try say(localized("liveCaption.on")) } catch {
            fail(error)
            return
        }
        work = Task {
            do {
                #if PRTS_DEV
                try await DevInteractionRecording.$interactionID.withValue(recordingInteractionID) {
                    try await DevInteractionRecording.$recordingGeneration.withValue(
                        recordingGeneration
                    ) {
                        try await run(capture: capture, key: key)
                    }
                }
                #else
                try await run(capture: capture, key: key)
                #endif
            } catch {
                if !Task.isCancelled { fail(error) }
            }
        }
    }

    func shutdown() async {
        let pending = Array(requests.values) + [work, sampling, pressTimer].compactMap { $0 }
        stop()
        for task in pending { await task.value }
    }

    func stop() {
        #if PRTS_DEV
        if isRunning {
            RecordingStore.shared.event(
                "interaction_ended",
                details: ["feature": "liveCaption", "interactionID": interactionID.uuidString],
                generation: recordingGeneration
            )
        }
        #endif
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
        #if PRTS_DEV
        waitingAnswerRecordingGeneration = nil
        #endif
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
        #if PRTS_DEV
        let openingRecordingGeneration = recordingToken(for: first.prefix(1))
        recordSelection(first.prefix(1), phase: "opening")
        #endif
        let openingFeedbackGeneration = feedbackGeneration
        do {
            let opening = try await skippingOverlong {
                #if PRTS_DEV
                try await DevInteractionRecording.$recordingGeneration.withValue(
                    openingRecordingGeneration
                ) {
                    try await describeOpening(first[0].jpeg, key)
                }
                #else
                try await describeOpening(first[0].jpeg, key)
                #endif
            }
            try Task.checkCancellation()
            consecutiveFailures = 0
            if let opening, feedbackEnabled, feedbackGeneration == openingFeedbackGeneration {
                #if PRTS_DEV
                try DevInteractionRecording.$recordingGeneration.withValue(
                    openingRecordingGeneration
                ) {
                    try present(opening)
                }
                #else
                try present(opening)
                #endif
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
            let video = [carried].compactMap { $0 } + LiveCaptionFrame.select(fresh)
            guard video.count >= LiveCaptionPolicy.minimumVideoFrames,
                requests.count < LiveCaptionPolicy.maximumRequestsInFlight
            else { continue }
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
        #if PRTS_DEV
        let recordingGeneration = recordingToken(for: frames)
        recordSelection(frames, phase: "change")
        #endif
        requests[id] = Task {
            do {
                let response = try await skippingOverlong {
                    #if PRTS_DEV
                    try await DevInteractionRecording.$recordingGeneration.withValue(
                        recordingGeneration
                    ) {
                        try await describeChange(video, previous, key)
                    }
                    #else
                    try await describeChange(video, previous, key)
                    #endif
                }
                try Task.checkCancellation()
                requests[id] = nil
                consecutiveFailures = 0
                guard let response else { return }
                #if PRTS_DEV
                RecordingStore.shared.event(
                    "interaction_result",
                    details: [
                        "feature": "liveCaption", "requestID": String(id), "answer": response,
                    ],
                    generation: recordingGeneration
                )
                #endif
                guard feedbackEnabled, feedbackGeneration == requestFeedbackGeneration else {
                    return
                }
                #if PRTS_DEV
                try DevInteractionRecording.$recordingGeneration.withValue(recordingGeneration) {
                    try receive(response, id: id)
                }
                #else
                try receive(response, id: id)
                #endif
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
            #if PRTS_DEV
            waitingAnswerRecordingGeneration =
                DevInteractionRecording.recordingGeneration ?? recordingGeneration
            #endif
        } else {
            previous = text
            try say(text)
        }
    }

    private func say(_ text: String) throws {
        guard feedbackEnabled else { return }
        #if PRTS_DEV
        let token = DevInteractionRecording.recordingGeneration ?? recordingGeneration
        try DevInteractionRecording.$recordingGeneration.withValue(token) {
            try audio.speak(text)
        }
        #else
        try audio.speak(text)
        #endif
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
            #if PRTS_DEV
            let token = waitingAnswerRecordingGeneration ?? recordingGeneration
            waitingAnswerRecordingGeneration = nil
            try DevInteractionRecording.$recordingGeneration.withValue(token) {
                try present(answer)
            }
            #else
            try present(answer)
            #endif
        } catch { fail(error) }
    }

    private func fail(_ error: Error, mayAnnounce: Bool = true) {
        services.errors.record(error)
        stop()
        message = error.localizedDescription
        if mayAnnounce { announce(message) }
    }

    #if PRTS_DEV
    private func recordingToken(for frames: some Collection<LiveCaptionFrame>) -> UInt64 {
        // Keep inference selection unchanged. A request containing any pre-clear image is
        // excluded from the new recording; fresh windows resume recording automatically.
        let current = RecordingStore.shared.admissionGeneration
        let boundary = RecordingStore.shared.recordingBoundaryUptime
        guard frames.allSatisfy({ $0.sampledAt >= boundary }) else { return recordingGeneration }
        if recordingGeneration != current {
            recordingGeneration = current
            RecordingStore.shared.event(
                "live_caption_recording_resumed_after_clear",
                details: ["interactionID": interactionID.uuidString],
                generation: current
            )
        }
        return current
    }

    private func recordSelection(_ frames: some Collection<LiveCaptionFrame>, phase: String) {
        DevInteractionRecording.noteSuppressedAfterClear(
            feature: "liveCaption",
            id: interactionID.uuidString,
            generation: recordingGeneration
        )
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
    }
    #endif
}
