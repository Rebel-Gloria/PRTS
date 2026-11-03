import Foundation
import Testing

@testable import PRTS

@MainActor
private final class PhotoTestState {
    var time: TimeInterval = 0
    var allowUpload = true
    var onDevice = false
    var highResolution = false
    var capturedLongestSide: CGFloat?
    var hasCredential = true
    var speechAuthorized = true
    var events: [String] = []
}

@MainActor
private final class PhotoTestRecognizer: PhotoRecognizing {
    let state: PhotoTestState
    var question = "门在哪里？"
    init(_ state: PhotoTestState) { self.state = state }
    func start() throws { state.events.append("record") }
    func endCapture() { state.events.append("stop-mic") }
    func finish() async throws -> String {
        state.events.append("transcript")
        return question
    }
    func cancel() { state.events.append("cancel-mic") }
}

@MainActor
private final class PhotoTestAnswerAudio: AnswerAudio {
    let state: PhotoTestState
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    init(_ state: PhotoTestState) { self.state = state }
    func cue(_ cue: AnswerAudioOutput.Cue) throws {
        state.events.append(cue == .submit ? "A" : "B")
    }
    func speak(_ text: String) throws {
        state.events.append("speak")
        spoken.append(text)
    }
    func stop() { state.events.append("stop-audio") }
}

/// Responses intentionally ignore task cancellation, exercising the coordinator's
/// generation check against callbacks which arrive after the user has cancelled.
private actor PhotoTestNetwork {
    nonisolated struct Request: Sendable {
        let image: Data
        let question: String?
        let key: String
    }
    private(set) var requests: [Request] = []
    private var responses: [Int: CheckedContinuation<String, Error>] = [:]
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ image: Data, _ question: String?, _ key: String) async throws -> String {
        let index = requests.count
        requests.append(Request(image: image, question: question, key: key))
        return try await withCheckedThrowingContinuation { continuation in
            responses[index] = continuation
            let ready = arrivals.filter { $0.0 <= requests.count }
            arrivals.removeAll { $0.0 <= requests.count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { arrivals.append((count, $0)) }
    }
    func reply(_ index: Int, _ answer: String) {
        responses.removeValue(forKey: index)?.resume(returning: answer)
    }
}

@MainActor
private final class PhotoFixture {
    let state = PhotoTestState()
    let network = PhotoTestNetwork()
    let audio: PhotoTestAnswerAudio
    let recognizer: PhotoTestRecognizer
    let coordinator: PhotoDescriptionCoordinator
    init(configure: (inout PhotoDescriptionServices) -> Void = { _ in }) {
        let state = self.state
        let network = self.network
        audio = PhotoTestAnswerAudio(state)
        recognizer = PhotoTestRecognizer(state)
        var services = PhotoDescriptionServices()
        services.now = { state.time }
        services.onDevice = { _ in state.onDevice }
        services.highResolution = { state.highResolution }
        services.uploadAllowed = { state.allowUpload }
        services.credential = { _ in state.hasCredential ? "synthetic-test-key" : nil }
        services.speechAuthorized = { state.speechAuthorized }
        services.requestSpeechPermission = { false }
        configure(&services)
        services.describe = { try await network.send($0, $1, $2) }
        coordinator = PhotoDescriptionCoordinator(
            recognizer: recognizer,
            audio: audio,
            services: services
        )
    }
    func down() {
        coordinator.down(
            capture: { [state] longestSide in
                state.capturedLongestSide = longestSide
                state.events.append("capture")
                return Task { Data([0xff, 0xd8, 0xff, 0xd9]) }
            },
            silence: { [state] in state.events.append("silence") }
        )
    }
}

@MainActor
struct PhotoLifecycleTests {
    @Test(arguments: [false, true], [false, true])
    func highResolutionAppliesAtQuestionCapture(highResolution: Bool, onDevice: Bool) async {
        let f = PhotoFixture()
        f.state.highResolution = highResolution
        f.state.onDevice = onDevice
        f.down()
        f.state.time = 0.5
        f.coordinator.advancePress()
        #expect(f.state.capturedLongestSide == (highResolution ? 1920 : 1280))
        f.coordinator.cancel()

        f.state.time = 1
        f.down()
        f.state.time = 1.1
        f.coordinator.up()
        #expect(f.state.capturedLongestSide == 1280)
        await f.network.waitForRequests(1)
        await f.network.reply(0, "门口。")
        await f.coordinator.work?.value
        f.coordinator.cancel()
    }

    @Test func shortPressUsesReleaseFrameAndFixedQuestion() async throws {
        let f = PhotoFixture()
        f.down()
        #expect(f.state.events == ["silence"])
        f.state.time = 0.49
        f.coordinator.up()
        #expect(f.state.events == ["silence", "capture", "A"])
        await f.network.waitForRequests(1)
        let requests = await f.network.requests
        #expect(requests[0].question == nil)
        #expect(requests[0].image == Data([0xff, 0xd8, 0xff, 0xd9]))
        await f.network.reply(0, "前方是门。")
        await f.coordinator.work?.value
        #expect(f.audio.spoken == ["前方是门。"])
        #expect(f.coordinator.busy)
        f.audio.onFinished?()
        #expect(!f.coordinator.busy)
    }

    @Test func longPressCapturesAtThresholdAndStopsBeforeSubmitCue() async throws {
        let f = PhotoFixture()
        f.down()
        f.state.time = 0.499
        f.coordinator.advancePress()
        #expect(f.state.events == ["silence"])
        f.state.time = 0.5
        f.coordinator.advancePress()
        #expect(f.state.events == ["silence", "capture", "B", "record"])
        f.state.time = 1
        f.coordinator.advancePress()
        f.coordinator.up()
        #expect(f.state.events.suffix(2) == ["stop-mic", "A"])
        await f.network.waitForRequests(1)
        let requests = await f.network.requests
        #expect(requests[0].question == "门在哪里？")
        #expect(f.state.events.filter { $0 == "capture" }.count == 1)
        await f.network.reply(0, "门在左侧。")
        await f.coordinator.work?.value
        #expect(f.audio.spoken == ["门在左侧。"])
        f.coordinator.cancel()
    }

    @Test func repeatedLongPressSendsOnlyTheCurrentTranscript() async throws {
        let f = PhotoFixture()
        let questions = ["请告诉我\n门的“颜色”是什么？", "路牌上写了什么？"]
        for (index, question) in questions.enumerated() {
            f.recognizer.question = question
            let start = Double(index) * 2
            f.state.time = start
            f.down()
            f.state.time = start + 0.5
            f.coordinator.advancePress()
            f.state.time = start + 1
            f.coordinator.up()
            await f.network.waitForRequests(index + 1)
            let sent = await f.network.requests[index]
            #expect(sent.question == question)
            // Verify the question survives JSON encoding without changing the transcript's
            // punctuation/newlines or accumulating prior prompts.
            let request = try PhotoChatProtocol.request(
                jpeg: sent.image,
                text: try #require(sent.question),
                key: sent.key,
                system: PhotoPrompts.questionSystem
            )
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.first?["content"] as? String == PhotoPrompts.questionSystem)
            let content = try #require(messages.last?["content"] as? [[String: Any]])
            #expect(content[0]["text"] as? String == question)
            await f.network.reply(index, "测试回答")
            await f.coordinator.work?.value
            f.audio.onFinished?()
            #expect(!f.coordinator.busy)
        }
    }

    @Test func cancelledPressDoesNotCaptureOrUpload() async {
        let f = PhotoFixture()
        f.down()
        f.coordinator.cancel()
        f.state.time = 1
        f.coordinator.advancePress()
        f.coordinator.up()
        #expect(!f.state.events.contains("capture"))
        #expect(!f.state.events.contains("A"))
        #expect(await f.network.requests.isEmpty)
        #expect(!f.coordinator.busy)
    }

    @Test func oldResponseCannotSpeakOrCancelNewInteraction() async {
        let f = PhotoFixture()
        f.down()
        f.state.time = 0.1
        f.coordinator.up()
        let oldWork = f.coordinator.work
        await f.network.waitForRequests(1)
        f.coordinator.cancel()
        f.state.time = 2
        f.down()
        f.state.time = 2.1
        f.coordinator.up()
        await f.network.waitForRequests(2)
        await f.network.reply(0, "旧回答")
        await oldWork?.value
        #expect(f.audio.spoken.isEmpty)
        #expect(f.coordinator.busy)
        await f.network.reply(1, "新回答")
        await f.coordinator.work?.value
        #expect(f.audio.spoken == ["新回答"])
        f.coordinator.cancel()
    }

    @Test func noConsentOrCredentialNeverCaptures() async {
        let f = PhotoFixture()
        f.state.allowUpload = false
        f.down()
        f.coordinator.up()
        #expect(!f.coordinator.busy)
        f.state.allowUpload = true
        f.state.hasCredential = false
        f.down()
        f.coordinator.up()
        #expect(!f.state.events.contains("capture"))
        #expect(!f.state.events.contains("record"))
        #expect(await f.network.requests.isEmpty)
    }

    @Test(arguments: [false, true])
    func onDeviceNeedsNeitherUploadPermissionNorKey(question: Bool) async {
        let f = PhotoFixture()
        f.state.onDevice = true
        f.state.allowUpload = false
        f.state.hasCredential = false
        f.down()
        if question {
            f.state.time = 0.5
            f.coordinator.advancePress()
        }
        f.coordinator.up()
        await f.network.waitForRequests(1)
        let requests = await f.network.requests
        #expect(requests[0].key.isEmpty)
        await f.network.reply(0, "门口。")
        await f.coordinator.work?.value
        f.coordinator.cancel()
    }

    @Test(arguments: [false, true])
    func eachActionUsesItsSelectedProviderAndCredential(question: Bool) async {
        let name = "PhotoLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: PhotoChatProvider.selectionKey)
        defaults.set("qwen", forKey: IntelligenceFeature.description.selectionKey)
        defaults.set("deepseek", forKey: IntelligenceFeature.question.selectionKey)
        defaults.set(true, forKey: "photoDescription.uploadAllowed")
        var accounts: [String] = []
        let f = PhotoFixture { services in
            let configured = PhotoDescriptionServices(defaults: defaults) { account in
                accounts.append(account)
                return "test-\(account)"
            }
            services.onDevice = configured.onDevice
            services.uploadAllowed = configured.uploadAllowed
            services.credential = configured.credential
        }
        f.down()
        #expect(accounts.isEmpty)
        if question {
            f.state.time = 0.5
            f.coordinator.advancePress()
        }
        f.coordinator.up()
        await f.network.waitForRequests(1)
        let request = await f.network.requests[0]
        let account = question ? "api-key.deepseek" : "api-key"
        #expect(accounts == [account])
        #expect(request.key == "test-\(account)")
        #expect((request.question != nil) == question)
        await f.network.reply(0, "门口。")
        await f.coordinator.work?.value
        f.coordinator.cancel()
    }

    @Test(arguments: [false, true])
    func localOverrideWorksWhenOtherActionHasNoConsentOrKey(question: Bool) async {
        let name = "PhotoLifecycleTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("qwen", forKey: PhotoChatProvider.selectionKey)
        let localFeature: IntelligenceFeature = question ? .question : .description
        defaults.set("onDevice", forKey: localFeature.selectionKey)
        let f = PhotoFixture { services in
            let configured = PhotoDescriptionServices(defaults: defaults) { _ in
                Issue.record("On-device actions must not read a credential")
                return nil
            }
            services.onDevice = configured.onDevice
            services.uploadAllowed = configured.uploadAllowed
            services.credential = configured.credential
        }
        f.down()
        if question {
            f.state.time = 0.5
            f.coordinator.advancePress()
        }
        f.coordinator.up()
        await f.network.waitForRequests(1)
        #expect(await f.network.requests[0].key.isEmpty)
        await f.network.reply(0, "门口。")
        await f.coordinator.work?.value
        f.coordinator.cancel()
    }

    @Test func missingSpeechPermissionNeverFallsBackToDefaultQuestion() async {
        let f = PhotoFixture()
        f.state.speechAuthorized = false
        f.down()
        f.state.time = 0.5
        f.coordinator.advancePress()
        await f.coordinator.work?.value
        f.coordinator.up()
        #expect(!f.state.events.contains("capture"))
        #expect(!f.state.events.contains("record"))
        #expect(await f.network.requests.isEmpty)
        #expect(!f.coordinator.busy)
    }
}
