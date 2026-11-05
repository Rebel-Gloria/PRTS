import Foundation
import Testing
import UIKit
import Vision

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

@MainActor
private final class CaptionTestClock {
    var now: TimeInterval = 0
    private var sleepers: [(TimeInterval, CheckedContinuation<Void, Error>)] = []
    private var arrival: (TimeInterval, Int, CheckedContinuation<Void, Never>)?

    func sleep(_ duration: TimeInterval) async throws {
        try await withCheckedThrowingContinuation { continuation in
            let deadline = now + duration
            sleepers.append((deadline, continuation))
            if let arrival, arrival.0 == deadline,
                sleepers.filter({ $0.0 == deadline }).count == arrival.1
            {
                self.arrival = nil
                arrival.2.resume()
            }
        }
    }

    func waitForSleep(at deadline: TimeInterval, count: Int = 1) async {
        if sleepers.filter({ $0.0 == deadline }).count >= count { return }
        await withCheckedContinuation { arrival = (deadline, count, $0) }
    }

    func advance(to time: TimeInterval) {
        now = time
        let ready = sleepers.filter { $0.0 <= time }
        sleepers.removeAll { $0.0 <= time }
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

    @Test func requestFailureIsAnnouncedOnceAndCanBeCancelled() async {
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
        let image = jpeg()
        session.start(capture: {
            Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        })
        let work = session.work
        await audio.waitForSpeech(count: 2)
        #expect(
            audio.spoken == [
                "liveCaption.on", PhotoChatError.incompleteStream.localizedDescription,
            ]
        )
        #expect(!session.isRunning)
        #expect(session.isAnnouncing)
        session.stop()
        clock.finish()
        await work?.value
        #expect(!session.suspendsFeedback)
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
        await clock.waitForSleep(at: 0.25)
        clock.advance(to: 0.25)
        await clock.waitForSleep(at: 0.5)
        await clock.waitForSleep(at: 2)
        clock.advance(to: 2)
        await clock.waitForSleep(at: 2.25)
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
        for tick in 1...20 {
            let time = Double(tick) * 0.25
            await clock.waitForSleep(at: time)
            clock.advance(to: time)
        }
        await clock.waitForSleep(at: 5.25)
        #expect(captureTimes == (0...20).map { Double($0) * 0.25 })
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

    @Test func restartWaitsForOldFeatureExtraction() async throws {
        let image = jpeg()
        let observation = try await LiveCaptionFeatureGenerator.shared.generate(
            image,
            extract: LiveCaptionFeatureGenerator.extract
        )
        let entered = TestSignal()
        let restarted = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let overlap = CaptionExtractionState()
        let audio = CaptionTestAnswerAudio()
        let clock = CaptionTestClock()
        let response = CaptionTestResponse()
        var passes = 0
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            credential: { _ in "test-key" },
            describeOpening: { _, _ in await response.request() },
            makeComparison: {
                passes += 1
                let first = passes == 1
                if !first { Task { await restarted.signal() } }
                return LiveCaptionImageComparison { _ in
                    overlap.begin()
                    defer { overlap.end() }
                    if first {
                        Task { await entered.signal() }
                        release.wait()
                    }
                    return observation
                }
            },
            sleep: clock.sleep
        )
        session.localized = { $0 }
        let capture: () throws -> Task<LiveCaptionFrame, Error> = {
            Task { LiveCaptionFrame(sampledAt: clock.now, jpeg: image, grayscale: [0]) }
        }
        session.start(capture: capture)
        let oldWork = session.work
        await entered.wait()
        session.stop()
        clock.finish()
        session.start(capture: capture)
        let newWork = session.work
        await restarted.wait()
        release.signal()
        await oldWork?.value
        await response.waitForRequest()
        #expect(overlap.maximum == 1)
        #expect(overlap.count == 2)
        #expect(session.isRunning)
        session.stop()
        clock.finish()
        await response.reply("new pass")
        await newWork?.value
        #expect(audio.spoken == ["liveCaption.on", "liveCaption.on"])
    }

    @Test func cancelledQueuedFeatureDoesNotStartExtraction() async throws {
        let image = jpeg()
        let observation = try await LiveCaptionFeatureGenerator.shared.generate(
            image,
            extract: LiveCaptionFeatureGenerator.extract
        )
        let entered = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let old = LiveCaptionImageComparison { _ in
            Task { await entered.signal() }
            release.wait()
            return observation
        }
        let oldTask = Task { try await old.accept(image) }
        await entered.wait()
        let next = LiveCaptionImageComparison { _ in
            Issue.record("Cancelled queued work must not enter Vision")
            return observation
        }
        let nextTask = Task { try await next.accept(image) }
        nextTask.cancel()
        release.signal()
        _ = try await oldTask.value
        await #expect(throws: CancellationError.self) { try await nextTask.value }
    }

    @Test func identicalFramesStayBelowThreshold() async throws {
        let comparison = LiveCaptionImageComparison()
        let image = jpeg()
        #expect(try await comparison.accept(image))
        #expect(try await !comparison.accept(image))
        #expect(try await !comparison.accept(image))
    }
}

nonisolated private final class CaptionExtractionState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    private var total = 0
    var maximum: Int { lock.withLock { peak } }
    var count: Int { lock.withLock { total } }
    func begin() {
        lock.withLock {
            active += 1
            total += 1
            peak = max(peak, active)
        }
    }
    func end() { lock.withLock { active -= 1 } }
}
