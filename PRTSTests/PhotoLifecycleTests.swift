import Foundation
import Testing
@testable import PRTS

@MainActor
private final class PhotoTestState {
    var time: TimeInterval = 0
    var allowUpload = true
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
    func finish() async throws -> String { state.events.append("transcript"); return question }
    func cancel() { state.events.append("cancel-mic") }
}

@MainActor
private final class PhotoTestAudio: PhotoAnswerAudio {
    let state: PhotoTestState
    var onFinished: (() -> Void)?
    var spoken: [String] = []
    init(_ state: PhotoTestState) { self.state = state }
    func cue(_ cue: PhotoAudioOutput.Cue) throws { state.events.append(cue == .submit ? "A" : "B") }
    func speak(_ text: String) throws { state.events.append("speak"); spoken.append(text) }
    func stop() { state.events.append("stop-audio") }
}

/// Responses intentionally ignore task cancellation, exercising the coordinator's
/// generation check against callbacks which arrive after the user has cancelled.
private actor PhotoTestNetwork {
    nonisolated struct Request: Sendable {
        let image: Data
        let text: String
        let key: String
    }
    private(set) var requests: [Request] = []
    private var responses: [Int: CheckedContinuation<String, Error>] = [:]
    private var arrivals: [(Int, CheckedContinuation<Void, Never>)] = []

    func send(_ image: Data, _ text: String, _ key: String) async throws -> String {
        let index = requests.count
        requests.append(Request(image: image, text: text, key: key))
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
    func reply(_ index: Int, _ answer: String) { responses.removeValue(forKey: index)?.resume(returning: answer) }
}

@MainActor
private final class PhotoFixture {
    let state = PhotoTestState()
    let network = PhotoTestNetwork()
    let audio: PhotoTestAudio
    let recognizer: PhotoTestRecognizer
    let coordinator: PhotoDescriptionCoordinator
    init() {
        let state = self.state, network = self.network
        audio = PhotoTestAudio(state)
        recognizer = PhotoTestRecognizer(state)
        var services = PhotoDescriptionServices()
        services.now = { state.time }
        services.uploadAllowed = { state.allowUpload }
        services.credential = { state.hasCredential ? "synthetic-test-key" : nil }
        services.speechAuthorized = { state.speechAuthorized }
        services.requestSpeechPermission = { false }
        services.describe = { try await network.send($0, $1, $2) }
        coordinator = PhotoDescriptionCoordinator(recognizer: recognizer, audio: audio, services: services)
    }
    func down() {
        coordinator.down(capture: { [state] in
            state.events.append("capture")
            return Task { Data([0xff, 0xd8, 0xff, 0xd9]) }
        }, silence: { [state] in state.events.append("silence") })
    }
}

@MainActor
struct PhotoLifecycleTests {
    @Test func shortPressUsesReleaseFrameAndFixedQuestion() async throws {
        let f = PhotoFixture()
        f.down()
        #expect(f.state.events == ["silence"])
        f.state.time = 0.49
        f.coordinator.up()
        #expect(f.state.events == ["silence", "capture", "A"])
        await f.network.waitForRequests(1)
        let requests = await f.network.requests
        #expect(requests[0].text == PhotoChatProtocol.prompt)
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
        #expect(requests[0].text == "门在哪里？")
        #expect(f.state.events.filter { $0 == "capture" }.count == 1)
        await f.network.reply(0, "门在左侧。")
        await f.coordinator.work?.value
        #expect(f.audio.spoken == ["门在左侧。"])
        f.coordinator.cancel()
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
        f.down(); f.state.time = 0.1; f.coordinator.up()
        let oldWork = f.coordinator.work
        await f.network.waitForRequests(1)
        f.coordinator.cancel()
        f.state.time = 2; f.down(); f.state.time = 2.1; f.coordinator.up()
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
        f.down(); f.coordinator.up()
        #expect(!f.coordinator.busy)
        f.state.allowUpload = true; f.state.hasCredential = false
        f.down(); f.coordinator.up()
        #expect(f.state.events.isEmpty)
        #expect(await f.network.requests.isEmpty)
    }

    @Test func missingSpeechPermissionNeverFallsBackToDefaultQuestion() async {
        let f = PhotoFixture()
        f.state.speechAuthorized = false
        f.down(); f.state.time = 0.5; f.coordinator.advancePress()
        await f.coordinator.work?.value
        f.coordinator.up()
        #expect(!f.state.events.contains("capture"))
        #expect(!f.state.events.contains("record"))
        #expect(await f.network.requests.isEmpty)
        #expect(!f.coordinator.busy)
    }
}
