import Foundation
import Testing
import UIKit

@testable import PRTS

@MainActor
private final class CaptionTestAudio: PhotoAnswerAudio {
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    var stops = 0
    func cue(_ cue: PhotoAudioOutput.Cue) throws {}
    func speak(_ text: String) throws { spoken.append(text) }
    func stop() { stops += 1 }
}

private actor CaptionTestResponse {
    private var response: CheckedContinuation<String, Never>?
    private var arrival: CheckedContinuation<Void, Never>?

    func request() async -> String {
        await withCheckedContinuation {
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

    @Test func lateOpeningAfterStopStaysSilent() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.onDevice = { true }
        services.describe = { _, question, _ in
            #expect(question == nil)
            return await response.request()
        }
        let session = LiveCaptionSession(audio: audio, services: services)
        let image = jpeg()
        session.start(capture: { Task { image } })
        let work = session.work
        await response.waitForRequest()
        #expect(session.isRunning)
        session.stop()
        await response.reply("桌上放着一台电脑。")
        await work?.value
        #expect(audio.spoken.isEmpty)
        #expect(!session.suspendsFeedback)
    }

    @Test func stopCancelsImagePreparation() async {
        let response = CaptionTestResponse()
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.onDevice = { true }
        let session = LiveCaptionSession(audio: audio, services: services)
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
        services.onDevice = { false }
        services.uploadAllowed = { false }
        let session = LiveCaptionSession(audio: audio, services: services)
        var captured = false
        session.start(capture: {
            captured = true
            return Task { Data() }
        })
        #expect(!captured)
        #expect(!session.isRunning)
        #expect(session.message == "先在设置里允许发送照片")
    }

    @Test func stopDuringPrefetchWaitKeepsLoopStopped() async {
        let wakeup = CaptionTestResponse()
        let audio = CaptionTestAudio()
        var services = PhotoDescriptionServices()
        services.now = { 10 }
        services.onDevice = { true }
        services.describe = { _, _, _ in "桌上放着一台电脑。" }
        let session = LiveCaptionSession(
            audio: audio,
            services: services,
            sleep: { _ in _ = await wakeup.request() }
        )
        let image = jpeg()
        var captures = 0
        session.start(capture: {
            captures += 1
            return Task { image }
        })
        let work = session.work
        await wakeup.waitForRequest()
        #expect(audio.spoken == ["桌上放着一台电脑。"])
        session.stop()
        await wakeup.reply("")
        await work?.value
        #expect(captures == 1)
        #expect(!session.isRunning)
    }

    @Test func confirmationAudioOwnsFeedbackUntilFinished() {
        let audio = CaptionTestAudio()
        let session = LiveCaptionSession(audio: audio, services: .init())
        session.announce("再次双击以启用流式字幕")
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
