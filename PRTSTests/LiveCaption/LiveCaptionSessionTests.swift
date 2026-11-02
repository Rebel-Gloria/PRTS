import Foundation
import Testing
import UIKit

@testable import PRTS

@MainActor
private final class CaptionTestAudio: PhotoAnswerAudio {
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    var stops = 0
    private var arrival: CheckedContinuation<Void, Never>?

    func cue(_ cue: PhotoAudioOutput.Cue) throws {}
    func speak(_ text: String) throws {
        spoken.append(text)
        arrival?.resume()
        arrival = nil
    }
    func stop() { stops += 1 }

    func waitForSpeech() async {
        if !spoken.isEmpty { return }
        await withCheckedContinuation { arrival = $0 }
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

@MainActor
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

    private func services(clock: CaptionTestClock) -> PhotoDescriptionServices {
        var services = PhotoDescriptionServices()
        services.now = { clock.now }
        services.uploadAllowed = { true }
        services.credential = { "synthetic-test-key" }
        return services
    }

    @Test(arguments: [PhotoChatProvider.onDevice, .deepseek, .custom])
    func otherProvidersAnnounceQwenRequirementBeforeCapture(provider: PhotoChatProvider) {
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.uploadAllowed = {
            Issue.record("Upload consent must only be checked for Qwen")
            return false
        }
        services.credential = {
            Issue.record("Credentials must only be read for Qwen")
            return nil
        }
        let session = LiveCaptionSession(audio: audio, services: services, provider: { provider })
        session.localized = { key in
            #expect(key == "liveCaption.requiresQwen")
            return "流式字幕需要在智能设置中选择通义千问。"
        }
        session.start(capture: {
            Issue.record("Unsupported providers must not capture")
            return Task { Data() }
        })
        #expect(session.work == nil)
        #expect(!session.isRunning)
        #expect(audio.spoken == ["流式字幕需要在智能设置中选择通义千问。"])
        #expect(session.suspendsFeedback)
        audio.onFinished?()
        #expect(!session.suspendsFeedback)
    }

    @Test func lateOpeningAfterStopStaysSilent() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            provider: { .qwen },
            describeOpening: { _, _ in await response.request() },
            sleep: clock.sleep
        )
        let image = jpeg()
        session.start(capture: { Task { image } })
        let work = session.work
        await response.waitForRequest()
        #expect(session.isRunning)
        session.stop()
        clock.finish()
        await response.reply("桌上放着一台电脑。")
        await work?.value
        #expect(audio.spoken.isEmpty)
        #expect(!session.suspendsFeedback)
    }

    @Test func stopCancelsImagePreparation() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            provider: { .qwen },
            sleep: clock.sleep
        )
        let image = jpeg()
        var imageTask: Task<Data, Error>?
        session.start(capture: {
            let task = Task {
                _ = await response.request()
                try Task.checkCancellation()
                return image
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
        #expect(audio.spoken.isEmpty)
    }

    @Test func cloudConsentIsRequiredBeforeCapture() {
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.uploadAllowed = { false }
        let session = LiveCaptionSession(audio: audio, services: services, provider: { .qwen })
        session.start(capture: {
            Issue.record("Capture requires upload consent")
            return Task { Data() }
        })
        #expect(!session.isRunning)
        #expect(session.message == "先在设置里允许发送照片")
    }

    @Test func qwenKeyIsRequiredBeforeCapture() {
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.uploadAllowed = { true }
        services.credential = { nil }
        let session = LiveCaptionSession(audio: audio, services: services, provider: { .qwen })
        session.start(capture: {
            Issue.record("Capture requires a Qwen key")
            return Task { Data() }
        })
        #expect(!session.isRunning)
        #expect(session.message == PhotoChatError.missingKey.localizedDescription)
    }

    @Test func fewerThanFourFramesNeverRequestChanges() async {
        let audio = CaptionTestAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            provider: { .qwen },
            describeOpening: { _, _ in "门口。" },
            describeChange: { _, _, _ in
                Issue.record("A video request requires four frames")
                return "无"
            },
            sleep: clock.sleep
        )
        let image = jpeg()
        var captures = 0
        session.start(capture: {
            captures += 1
            return Task { image }
        })
        let work = session.work
        await audio.waitForSpeech()
        await clock.waitForSleep(at: 1)
        clock.advance(to: 1)
        await clock.waitForSleep(at: 2, count: 2)
        clock.advance(to: 2)
        await clock.waitForSleep(at: 3)
        #expect(captures == 3)
        session.stop()
        clock.finish()
        await work?.value
        #expect(audio.spoken == ["门口。"])
    }

    @Test func samplingContinuesDuringOpeningRequestAndStopsWithSession() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAudio()
        let clock = CaptionTestClock()
        let session = LiveCaptionSession(
            audio: audio,
            services: services(clock: clock),
            provider: { .qwen },
            describeOpening: { _, _ in await response.request() },
            sleep: clock.sleep
        )
        let image = jpeg()
        var captureTimes: [TimeInterval] = []
        session.start(capture: {
            captureTimes.append(clock.now)
            return Task { image }
        })
        let work = session.work
        await response.waitForRequest()
        for second in 1...5 {
            await clock.waitForSleep(at: Double(second))
            clock.advance(to: Double(second))
        }
        await clock.waitForSleep(at: 6)
        #expect(captureTimes == [0, 1, 2, 3, 4, 5])
        session.stop()
        clock.finish()
        await response.reply("门口。")
        await work?.value
        #expect(captureTimes.count == 6)
        #expect(audio.spoken.isEmpty)
    }

    @Test func exitAudioOwnsFeedbackUntilFinished() {
        let audio = CaptionTestAudio()
        let session = LiveCaptionSession(audio: audio, services: .init())
        session.announce("已退出流式字幕")
        #expect(session.suspendsFeedback)
        #expect(!session.isRunning)
        audio.onFinished?()
        #expect(!session.suspendsFeedback)
    }

    @Test func identicalFramesStayBelowThreshold() async throws {
        let comparison = LiveCaptionImageComparison()
        let image = jpeg()
        #expect(try await comparison.accept(image))
        #expect(try await !comparison.accept(image))
        #expect(try await !comparison.accept(image))
    }
}
