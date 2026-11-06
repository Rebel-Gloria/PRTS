import Foundation
import Testing
import UIKit

@testable import PRTS

@MainActor
private final class CaptionTestAnswerAudio: AnswerAudio {
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    var stops = 0
    var playbackFails = false
    private var arrival: CheckedContinuation<Void, Never>?

    func cue(_ cue: AnswerCue) throws {}
    func speak(_ text: String) throws {
        spoken.append(text)
        if playbackFails { throw PhotoChatError.emptyAnswer }
        arrival?.resume()
        arrival = nil
    }
    func stop() { stops += 1 }

    func waitForSpeech(count: Int = 1) async {
        while spoken.count < count {
            await withCheckedContinuation { arrival = $0 }
        }
    }
}

private actor CaptionTestResponse {
    private var response: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func request() async -> String {
        return await withCheckedContinuation {
            response = $0
            arrival?.resume()
            arrival = nil
        }
    }

    func waitForRequest() async {
        if response != nil { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func reply(_ text: String) {
        response!.resume(returning: text)
        response = nil
    }
}

private actor CaptionTestReplies {
    private(set) var videos: [[Data]] = []
    private var responses: [Int: CheckedContinuation<String, Error>] = [:]
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []

    func request(_ video: [Data]) async throws -> String {
        let index = videos.count
        videos.append(video)
        return try await withCheckedThrowingContinuation { continuation in
            responses[index] = continuation
            let ready = arrivals.filter { $0.0 <= videos.count }
            arrivals.removeAll { $0.0 <= videos.count }
            ready.forEach { $0.1.resume() }
        }
    }

    func waitForRequests(_ count: Int) async {
        if videos.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }

    func reply(_ index: Int, _ text: String) {
        responses.removeValue(forKey: index)?.resume(returning: text)
    }

    func fail(_ index: Int) {
        responses.removeValue(forKey: index)?.resume(throwing: PhotoChatError.incompleteStream)
    }

    func finish() {
        responses.values.forEach { $0.resume(returning: "无") }
        responses = [:]
    }
}

@MainActor
private final class CaptionTestClock {
    var now: TimeInterval = 0
    private var sleepers: [(TimeInterval, CheckedContinuation<Void, Error>)] = []
    private var arrival: (TimeInterval, Int, CheckedContinuation<Void, Never>)?

    /// Deadlines are sums of sample intervals, so they differ by rounding.
    private func same(_ first: TimeInterval, _ second: TimeInterval) -> Bool {
        abs(first - second) < 1e-9
    }

    func sleep(_ duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let deadline = now + duration
            sleepers.append((deadline, continuation))
            if let arrival, same(arrival.0, deadline),
                sleepers.filter({ same($0.0, deadline) }).count == arrival.1
            {
                self.arrival = nil
                arrival.2.resume()
            }
        }
    }

    func waitForSleep(at deadline: TimeInterval, count: Int = 1) async {
        if sleepers.filter({ same($0.0, deadline) }).count >= count { return }
        await withCheckedContinuation { arrival = (deadline, count, $0) }
    }

    func advance(to time: TimeInterval) {
        now = time
        let ready = sleepers.filter { $0.0 <= time + 1e-9 }
        sleepers.removeAll { $0.0 <= time + 1e-9 }
        for (_, continuation) in ready { continuation.resume() }
    }

    func finish() {
        let pending = sleepers
        sleepers = []
        for (_, continuation) in pending { continuation.resume(throwing: CancellationError()) }
    }
}

@MainActor @Suite(.serialized)
struct LiveCaptionSessionTests {
    private func jpeg() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).jpegData(
            withCompressionQuality: 0.8
        ) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            UIColor.black.setFill()
            context.fill(CGRect(x: 10, y: 10, width: 20, height: 40))
        }
    }

    private func services(clock: CaptionTestClock) -> LiveCaptionServices {
        var services = LiveCaptionServices()
        services.errors = .ignored
        services.now = { clock.now }
        services.uploadAllowed = { true }
        return services
    }

    @Test(arguments: [PhotoChatProvider.onDevice, .deepseek, .custom])
    func qwenKeyStartsCaptionsWithAnyDefaultProvider(provider: PhotoChatProvider) async {
        let name = "LiveCaptionSessionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(provider.rawValue, forKey: PhotoChatProvider.selectionKey)
        defaults.set(true, forKey: "photoDescription.uploadAllowed")
        let response = CaptionTestResponse()
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        var services = LiveCaptionServices(defaults: defaults)
        services.errors = .ignored
        services.now = { clock.now }
        let session = LiveCaptionSession(
            audio: audio,
            services: services,
            credential: { account in
                #expect(account == PhotoChatProvider.qwen.keyAccount)
                return "test-qwen-key"
            },
            describeOpening: { _, key in
                #expect(key == "test-qwen-key")
                return await response.request()
            },
            sleep: clock.sleep
        )
        let image = jpeg()
        session.start(capture: {
            Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        await response.waitForRequest()
        #expect(session.isRunning)
        session.stop()
        clock.finish()
        await response.reply("门口。")
        await work?.value
    }

    @Test func lateOpeningAfterStopStaysSilent() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in await response.request() },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let image = jpeg()
        session.start(capture: {
            Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        await response.waitForRequest()
        #expect(session.isRunning)
        session.stop()
        clock.finish()
        await response.reply("桌上放着一台电脑。")
        await work?.value
        #expect(audio.spoken == ["liveCaption.on"])
        #expect(!session.suspendsFeedback)
    }

    @Test func stopCancelsImagePreparation() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let image = jpeg()
        var imageTask: Task<LiveCaptionFrame, Error>?
        session.start(capture: {
            let task = Task {
                _ = await response.request()
                try Task.checkCancellation()
                return LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0])
            }
            imageTask = task
            return task
        })
        let work = session.work
        await response.waitForRequest()
        session.stop()
        #expect(imageTask?.isCancelled == true)
        await response.reply("")
        await work?.value
        #expect(audio.spoken == ["liveCaption.on"])
    }

    @Test func cloudConsentIsRequiredBeforeCapture() {
        let audio = CaptionTestAnswerAudio()
        var services = LiveCaptionServices()
        services.errors = .ignored
        services.uploadAllowed = { false }
        let session = LiveCaptionSession(
            audio: audio,
            services: services,
            credential: { _ in
                Issue.record("Upload consent must be checked before the Qwen key")
                return nil
            }
        )
        session.start(capture: {
            Issue.record("Capture requires upload consent")
            return Task { LiveCaptionFrame(sampledAt: 0, jpeg: Data(), grayscale: []) }
        })
        #expect(!session.isRunning)
        #expect(session.message == "先在设置里允许发送照片")
        #expect(audio.spoken == ["先在设置里允许发送照片"])
        #expect(session.suspendsFeedback)
        audio.onFinished?()
        #expect(!session.suspendsFeedback)
    }

    @Test func failingStatusAudioDoesNotRecursivelyAnnounceErrors() {
        let audio = CaptionTestAnswerAudio()
        audio.playbackFails = true
        var services = LiveCaptionServices()
        services.errors = .ignored
        services.uploadAllowed = { false }
        let session = LiveCaptionSession(audio: audio, services: services)
        session.start(capture: {
            Issue.record("Consent failure must not start capturing")
            return Task { LiveCaptionFrame(sampledAt: 0, jpeg: Data(), grayscale: []) }
        })
        #expect(audio.spoken.count == 1)
        #expect(!session.suspendsFeedback)
        #expect(session.work == nil)
    }

    @Test func overlongOpeningIsSkippedWithoutEndingTheSession() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in throw PhotoChatError.answerTooLong },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let image = jpeg()
        session.start(capture: {
            Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        // The session reaches its first send once the opening has been skipped.
        await clock.waitForSleep(at: LiveCaptionPolicy.requestInterval)
        #expect(session.isRunning)
        #expect(audio.spoken == ["liveCaption.on"])
        session.stop()
        clock.finish()
        await work?.value
    }

    @Test func qwenKeyIsRequiredBeforeCapture() {
        let audio = CaptionTestAnswerAudio()
        var services = LiveCaptionServices()
        services.errors = .ignored
        services.uploadAllowed = { true }
        let session = LiveCaptionSession(
            audio: audio,
            services: services,
            credential: { account in
                #expect(account == PhotoChatProvider.qwen.keyAccount)
                return nil
            }
        )
        session.localized = { key in
            #expect(key == "liveCaption.requiresQwen")
            return "流式字幕需要通义千问的 API Key"
        }
        session.start(capture: {
            Issue.record("Capture requires a Qwen key")
            return Task { LiveCaptionFrame(sampledAt: 0, jpeg: Data(), grayscale: []) }
        })
        #expect(!session.isRunning)
        #expect(session.work == nil)
        #expect(audio.spoken == ["流式字幕需要通义千问的 API Key"])
        #expect(session.suspendsFeedback)
        audio.onFinished?()
        #expect(!session.suspendsFeedback)
    }

    @Test func fewerThanFourFramesNeverRequestChanges() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in "门口。" },
            describeChange: { _, _, _ in
                Issue.record("A video request requires four frames")
                return "无"
            },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let image = jpeg()
        var captures = 0
        session.start(capture: {
            captures += 1
            return Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        await audio.waitForSpeech()
        // The opening waits until the start cue has been read.
        audio.onFinished?()
        await audio.waitForSpeech(count: 2)
        await clock.waitForSleep(at: 0.1)
        clock.advance(to: 0.1)
        await clock.waitForSleep(at: 0.2)
        await clock.waitForSleep(at: 2)
        clock.advance(to: 2)
        await clock.waitForSleep(at: 2.1)
        #expect(captures == 3)
        session.stop()
        clock.finish()
        await work?.value
        #expect(audio.spoken == ["liveCaption.on", "门口。"])
    }

    @Test func samplingContinuesDuringOpeningRequestAndStopsWithSession() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in await response.request() },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let image = jpeg()
        var captureTimes: [TimeInterval] = []
        session.start(capture: {
            captureTimes.append(clock.now)
            return Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        await response.waitForRequest()
        var time = 0.0
        var expected = [time]
        for _ in 1...20 {
            time += LiveCaptionPolicy.sampleInterval
            await clock.waitForSleep(at: time)
            clock.advance(to: time)
            expected.append(time)
        }
        await clock.waitForSleep(at: time + LiveCaptionPolicy.sampleInterval)
        #expect(captureTimes == expected)
        session.stop()
        clock.finish()
        await response.reply("门口。")
        await work?.value
        #expect(captureTimes.count == 21)
        #expect(audio.spoken == ["liveCaption.on"])
    }

    @Test func exitAudioOwnsFeedbackUntilFinished() {
        let audio = CaptionTestAnswerAudio()
        let session = LiveCaptionSession(audio: audio, services: .init())
        session.announce("已退出流式字幕")
        #expect(session.suspendsFeedback)
        #expect(!session.isRunning)
        audio.onFinished?()
        #expect(!session.suspendsFeedback)
    }

    private func moving(_ clock: CaptionTestClock) -> () throws -> Task<LiveCaptionFrame, Error> {
        var count: UInt8 = 0
        return {
            count &+= 1
            let frame = LiveCaptionFrame(
                sampledAt: clock.now,
                jpeg: Data([count]),
                grayscale: [count]
            )
            return Task { frame }
        }
    }

    private func advance(_ clock: CaptionTestClock, samples: Int, from start: inout Double) async {
        for _ in 0..<samples {
            start += LiveCaptionPolicy.sampleInterval
            await clock.waitForSleep(at: start)
            clock.advance(to: start)
        }
    }

    /// The sending loop can fall a beat behind the sampler, so the clock runs until it catches up.
    private func advance(
        _ clock: CaptionTestClock,
        until count: Int,
        _ replies: CaptionTestReplies,
        from start: inout Double
    ) async {
        while await replies.videos.count < count {
            await advance(clock, samples: 5, from: &start)
            await settle()
        }
    }

    private func captionSession(
        _ audio: CaptionTestAnswerAudio,
        _ clock: CaptionTestClock,
        _ replies: CaptionTestReplies
    ) -> LiveCaptionSession {
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in throw PhotoChatError.answerTooLong },
            describeChange: { video, _, _ in try await replies.request(video) },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        session.start(capture: moving(clock))
        return session
    }

    @Test func sendsEveryTwoSecondsWithThePreviousLastFrame() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        var time = 0.0
        await advance(clock, until: 1, replies, from: &time)
        await advance(clock, until: 2, replies, from: &time)
        let videos = await replies.videos
        #expect((LiveCaptionPolicy.minimumVideoFrames...6).contains(videos[0].count))
        #expect((LiveCaptionPolicy.minimumVideoFrames...6).contains(videos[1].count))
        #expect(videos[1].first == videos[0].last)
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func requestsInFlightAreLimited() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        var time = 0.0
        await advance(clock, until: LiveCaptionPolicy.maximumRequestsInFlight, replies, from: &time)
        await advance(clock, samples: 20, from: &time)
        #expect(await replies.videos.count == LiveCaptionPolicy.maximumRequestsInFlight)
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func anAnswerOlderThanOneAlreadyReadIsDropped() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        audio.onFinished?()
        var time = 0.0
        await advance(clock, until: 2, replies, from: &time)
        await replies.reply(1, "新的动作。")
        await audio.waitForSpeech(count: 2)
        audio.onFinished?()
        await replies.reply(0, "旧的动作。")
        await settle()
        #expect(audio.spoken == ["liveCaption.on", "新的动作。"])
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func onlyTheNewestAnswerWaitsForTheCurrentSentence() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        var time = 0.0
        await advance(clock, until: 2, replies, from: &time)
        await replies.reply(0, "第一句。")
        for _ in 0..<50 { await Task.yield() }
        await replies.reply(1, "第二句。")
        await settle()
        #expect(audio.spoken == ["liveCaption.on"])
        audio.onFinished?()
        #expect(audio.spoken == ["liveCaption.on", "第二句。"])
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func aFailedOpeningIsSkipped() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "synthetic-test-key" },
            describeOpening: { _, _ in throw PhotoChatError.incompleteStream },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        session.start(capture: moving(clock))
        let work = session.work
        await clock.waitForSleep(at: LiveCaptionPolicy.requestInterval)
        #expect(session.isRunning)
        #expect(audio.spoken == ["liveCaption.on"])
        session.stop()
        clock.finish()
        await work?.value
    }

    private func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }

    @Test func threeFailuresInARowEndCaptions() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        var time = 0.0
        await advance(clock, until: 3, replies, from: &time)
        await replies.fail(0)
        await settle()
        await replies.fail(1)
        await settle()
        #expect(session.isRunning)
        #expect(audio.spoken == ["liveCaption.on"])
        await replies.fail(2)
        await settle()
        #expect(!session.isRunning)
        #expect(audio.spoken.last == PhotoChatError.incompleteStream.localizedDescription)
        #expect(session.isAnnouncing)
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func aSuccessResetsTheFailureCount() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        var time = 0.0
        await advance(clock, until: 3, replies, from: &time)
        await replies.fail(0)
        await settle()
        await replies.fail(1)
        await settle()
        await replies.reply(2, "无")
        await settle()
        await advance(clock, until: 5, replies, from: &time)
        await replies.fail(3)
        await settle()
        await replies.fail(4)
        await settle()
        #expect(session.isRunning)
        session.stop()
        clock.finish()
        await replies.finish()
    }

    @Test func stopDropsAnswersStillInFlight() async {
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let replies = CaptionTestReplies()
        let session = captionSession(audio, clock, replies)
        audio.onFinished?()
        var time = 0.0
        await advance(clock, until: 1, replies, from: &time)
        session.stop()
        await replies.reply(0, "迟到的动作。")
        await settle()
        #expect(audio.spoken == ["liveCaption.on"])
        clock.finish()
        await replies.finish()
    }
}
