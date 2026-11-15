import Foundation
import Testing

@testable import PRTS

@MainActor
struct TextReadingServiceTests {
    @Test(arguments: [
        "<5℃冷藏", "<div>营业时间</div>", "a<b", "原文</thi", "<think>", "<think>原文</think>",
        "<think><think>原文</think></think>", "<think>一</think><think>二</think>",
    ])
    func remoteCopyPreservesLiteralText(text: String) throws {
        let (surface, copy) = try TextReadingBackend.parseRemoteAnswer("纸张\n\(text)")
        #expect(surface == .paper)
        var answer = TextReadingAnswer(lead: "你面前的纸张上写着")
        let spoken = answer.append(copy) + answer.finish()
        #expect(spoken == ["你面前的纸张上写着：\(text)"])
    }

    @Test func remoteCopyStopsOnlyAtTheKnownModelMarker() throws {
        let (surface, copy) = try TextReadingBackend.parseRemoteAnswer(
            "牌子\n温度<5℃。请冷藏。</think>\n牌子\n虚构的下一轮"
        )
        #expect(surface == .sign)
        var answer = TextReadingAnswer(lead: "你面前的牌子上写着")
        let spoken = answer.append(copy) + answer.finish()
        #expect(spoken == ["你面前的牌子上写着：温度<5℃。", "请冷藏。"])
    }

    @Test(arguments: ["", " \n\t"])
    func streamedReasoningEnvelopeNeverReachesSpeech(whitespace: String) throws {
        var stream = PhotoChatStream()
        for piece in [whitespace + "<thi", "nk>我在识别文本。</think>\n纸张\n", "药品名称"] {
            let event: [String: Any] = [
                "choices": [[
                    "index": 0,
                    "delta": ["content": piece, "reasoning_content": "不应朗读的独立思考字段"],
                ]],
            ]
            let data = try JSONSerialization.data(withJSONObject: event)
            let payload = try #require(String(data: data, encoding: .utf8))
            try stream.receive(line: "data: \(payload)")
            try stream.receive(line: "")
        }
        try stream.receive(line: "data: [DONE]")
        try stream.receive(line: "")
        let (surface, copy) = try TextReadingBackend.parseRemoteAnswer(stream.finish())
        #expect(surface == .paper)
        var answer = TextReadingAnswer(lead: "你面前的纸张上写着")
        #expect(answer.append(copy) + answer.finish() == ["你面前的纸张上写着：药品名称"])
    }

    @Test func reasoningEnvelopeCanReportNoText() throws {
        let (_, copy) = try TextReadingBackend.parseRemoteAnswer("<think>没有文字。</think>\n无")
        var answer = TextReadingAnswer(lead: "你面前的物体上写着")
        #expect(answer.append(copy) + answer.finish() == [])
        #expect(!answer.spokeText)
    }

    @Test(arguments: [
        "<think>未结束", "<think>推理。</think>", "<think>推理。</think>\n分类不明\n正文",
        "<think>推理。</think>\n纸张上的文字\n正文",
    ])
    func ambiguousReasoningEnvelopeFailsInsteadOfSpeaking(text: String) {
        #expect(throws: PhotoChatError.self) {
            try TextReadingBackend.parseRemoteAnswer(text)
        }
    }

    @Test func ambiguousReasoningEnvelopeUsesTheExistingLocalFallback() async throws {
        var readers: [TextReadingService.Reader] = []
        try await TextReadingService.custom.read(remoteAvailable: true) { reader in
            readers.append(reader)
            if reader == .remote {
                _ = try TextReadingBackend.parseRemoteAnswer("<think>推理。</think>\n分类不明")
            }
        }
        #expect(readers == [.remote, .onDevice])
    }

    @Test(arguments: [
        "<think>字样</think>", "<think><think>字样</think></think>", "<think>一</think><think>二</think>",
    ])
    func literalPairedTagsDoNotHideALaterStrayMarker(literal: String) throws {
        let (_, copy) = try TextReadingBackend.parseRemoteAnswer(
            "纸张\n\(literal)与a<b</think>虚构的下一轮"
        )
        #expect(copy == "\n\(literal)与a<b")
    }

    @Test func strayMarkerOnClassificationLineCannotExposeTheNextTurn() throws {
        let (surface, copy) = try TextReadingBackend.parseRemoteAnswer("牌子</think>\n虚构下一轮")
        #expect(surface == .sign)
        #expect(copy.isEmpty)
    }

    @Test func selectionsPreserveProviderAndVisionValues() {
        let name = "TextReadingServiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(
            TextReadingService.allCases == [.vlm, .onDevice, .qwen, .deepseek, .custom, .vision]
        )
        #expect(TextReadingService.current(defaults) == .vlm)
        for selection in TextReadingService.allCases {
            defaults.set(selection.rawValue, forKey: TextReadingService.selectionKey)
            #expect(TextReadingService.current(defaults) == selection)
        }
    }

    @Test(arguments: TextReadingService.allCases, PhotoChatProvider.allCases)
    func fallbackChainUsesTheSelectedProvider(
        selection: TextReadingService,
        defaultProvider: PhotoChatProvider
    ) async throws {
        let name = "TextReadingServiceTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(defaultProvider.rawValue, forKey: PhotoChatProvider.selectionKey)
        defaults.set(selection.rawValue, forKey: TextReadingService.selectionKey)
        let provider = IntelligenceFeature.textReading.provider(defaults)
        let remoteAvailable = provider != nil && provider != .onDevice
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.current(defaults).read(remoteAvailable: remoteAvailable) {
            calls.append($0)
            if $0 != .vision { throw URLError(.cannotConnectToHost) }
        }
        let expected: [TextReadingService.Reader]
        switch selection {
        case .vision: expected = [.vision]
        case .onDevice: expected = [.onDevice, .vision]
        case .vlm:
            expected =
                defaultProvider == .onDevice
                ? [.onDevice, .vision] : [.remote, .onDevice, .vision]
        case .qwen, .deepseek, .custom: expected = [.remote, .onDevice, .vision]
        }
        #expect(calls == expected)
    }

    @Test func successfulRemoteReadingDoesNotStartLocalReaders() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { calls.append($0) }
        #expect(calls == [.remote])
    }

    @Test func unavailableRemoteFallsBackToTheLocalModel() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
            calls.append(reader)
            if reader == .remote { throw URLError(.cannotConnectToHost) }
        }
        #expect(calls == [.remote, .onDevice])
    }

    @Test func missingRemoteSetupStartsOffline() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: false) { calls.append($0) }
        #expect(calls == [.onDevice])
    }

    @Test func failedModelsFallBackToVision() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
            calls.append(reader)
            if reader != .vision { throw URLError(.unknown) }
        }
        #expect(calls == [.remote, .onDevice, .vision])
    }

    @Test func visionNeverStartsAModel() async throws {
        var calls: [TextReadingService.Reader] = []
        try await TextReadingService.vision.read(remoteAvailable: true) { calls.append($0) }
        #expect(calls == [.vision])
    }

    @Test func failedVisionDoesNotStartAnotherReader() async {
        var calls: [TextReadingService.Reader] = []
        do {
            try await TextReadingService.vision.read(remoteAvailable: true) { reader in
                calls.append(reader)
                throw URLError(.unknown)
            }
            Issue.record("Expected the final reader's error")
        } catch {
            #expect((error as? URLError)?.code == .unknown)
        }
        #expect(calls == [.vision])
    }

    @Test func cancellationNeverStartsFallback() async {
        let errors: [any Error] = [CancellationError(), URLError(.cancelled)]
        for error in errors {
            var calls: [TextReadingService.Reader] = []
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
                    calls.append(reader)
                    throw error
                }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
            #expect(calls == [.remote])
        }
    }

    @Test func cancelledTaskDoesNotStartAReader() async {
        var calls: [TextReadingService.Reader] = []
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { calls.append($0) }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
        #expect(calls.isEmpty)
    }

    @Test func cancellationDuringARequestPreventsFallbackAfterANetworkError() async {
        var calls: [TextReadingService.Reader] = []
        let task = Task { @MainActor in
            do {
                try await TextReadingService.vlm.read(remoteAvailable: true) { reader in
                    calls.append(reader)
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw URLError(.networkConnectionLost)
                }
                Issue.record("Expected cancellation")
            } catch {
                #expect(error is CancellationError)
            }
        }
        await task.value
        #expect(calls == [.remote])
    }
}
