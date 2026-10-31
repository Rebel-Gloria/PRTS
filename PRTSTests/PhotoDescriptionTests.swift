import Foundation
import Testing
@testable import PRTS

struct PhotoDescriptionTests {
    /// The expected text is independent of the implementation constant: comparing
    /// the request only with that constant cannot detect an omitted user requirement.
    @Test func fixedPromptAndSharedSystemRules() throws {
        #expect(PhotoChatProtocol.prompt == "描述眼前。")
        for rule in ["先说离用户最近的东西", "不指挥用户往哪边走", "不编造看不清的东西", "一到两句，不超过四十个字", "只学句式，不要照抄内容"] {
            #expect(PhotoChatProtocol.system.contains(rule))
        }
        for service in [PhotoChatService.qwen, .deepseek] {
            let request = try PhotoChatProtocol.request(jpeg: Data([1]), text: PhotoChatProtocol.prompt, key: "test-only", service: service)
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let messages = try #require(body["messages"] as? [[String: Any]])
            #expect(messages.count == 2)
            #expect(messages[0]["role"] as? String == "system")
            #expect(messages[0]["content"] as? String == PhotoChatProtocol.system)
            let content = try #require(messages[1]["content"] as? [[String: Any]])
            #expect(content[0]["text"] as? String == "描述眼前。")
        }
    }

    @Test func exactRequestContract() throws {
        let jpeg = Data([0xff, 0xd8, 0xff, 0xd9])
        let request = try PhotoChatProtocol.request(jpeg: jpeg, text: PhotoChatProtocol.prompt, key: "test-only")
        #expect(request.url?.absoluteString == "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen3.8-flash")
        #expect(body["stream"] as? Bool == true)
        #expect(body["enable_thinking"] as? Bool == false)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.first?["role"] as? String == "system")
        let content = try #require(messages.last?["content"] as? [[String: Any]])
        #expect(messages.last?["role"] as? String == "user")
        #expect(content[0]["text"] as? String == PhotoChatProtocol.prompt)
        #expect((content[1]["image_url"] as? [String: String])?["url"] == "data:image/jpeg;base64,\(jpeg.base64EncodedString())")
    }

    @Test func customQuestionReplacesDefault() throws {
        let request = try PhotoChatProtocol.request(jpeg: Data([1]), text: "门在哪里？", key: "test-only")
        let data = try #require(request.httpBody)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json.contains("门在哪里？"))
        #expect(!json.contains(PhotoChatProtocol.prompt))
        #expect(!json.contains("最多两句"))
    }

    @Test func providerPresetsAndCustomEndpoint() throws {
        let deepseek = try PhotoChatProtocol.request(jpeg: Data([1]), text: "看", key: "test-only", service: .deepseek)
        #expect(deepseek.url?.absoluteString == "https://api.deepseek.com/chat/completions")
        let deepseekData = try #require(deepseek.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: deepseekData) as? [String: Any])
        #expect(body["model"] as? String == "deepseek-flash")
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect(body["enable_thinking"] == nil)

        #expect(PhotoChatService.chatURL(from: " https://api.example.com/v1/ ")?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(PhotoChatService.chatURL(from: "https://api.example.com/v1/chat/completions")?.absoluteString == "https://api.example.com/v1/chat/completions")
        #expect(PhotoChatService.chatURL(from: "http://api.example.com/v1") == nil)
        #expect(PhotoChatService.chatURL(from: "api.example.com") == nil)

        let defaults = try #require(UserDefaults(suiteName: "PhotoDescriptionTests.\(UUID().uuidString)"))
        #expect(PhotoChatProvider.current(defaults) == .onDevice)
        #expect(PhotoChatProvider.qwen.keyAccount == "api-key")
        defaults.set("custom", forKey: PhotoChatProvider.selectionKey)
        defaults.set("https://api.example.com/v1", forKey: PhotoChatProvider.customEndpointKey)
        #expect(PhotoChatProvider.custom.service(defaults) == nil)
        defaults.set("vision-mini", forKey: PhotoChatProvider.customModelKey)
        let custom = try #require(PhotoChatProvider.current(defaults).service(defaults))
        let customData = try #require(try PhotoChatProtocol.request(jpeg: Data([1]), text: "看", key: "test-only", service: custom).httpBody)
        let customBody = try #require(JSONSerialization.jsonObject(with: customData) as? [String: Any])
        #expect(customBody["model"] as? String == "vision-mini")
        #expect(customBody["thinking"] == nil && customBody["enable_thinking"] == nil)
    }

    @Test func questionsCanTurnThinkingOn() throws {
        func body(_ service: PhotoChatService) throws -> [String: Any] {
            let data = try #require(try PhotoChatProtocol.request(jpeg: Data([1]), text: "看", key: "test-only", service: service,
                                                                  system: PhotoChatProtocol.questionSystem, thinking: true).httpBody)
            return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try body(.qwen)["enable_thinking"] as? Bool == true)
        #expect((try body(.deepseek)["thinking"] as? [String: String])?["type"] == "enabled")
    }

    @Test func questionAnswersStopAtThreeSentences() {
        #expect(PhotoChatProtocol.threeSentences("一。二！三？四。") == "一。二！三？")
        #expect(PhotoChatProtocol.threeSentences("看不清。\n太暗了。\n换个地方。\n再试试。") == "看不清。\n太暗了。\n换个地方。")
        #expect(PhotoChatProtocol.threeSentences("开的，写着24小时营业。") == "开的，写着24小时营业。")
    }

    @Test func reasoningNeverBecomesSpeech() throws {
        var stream = PhotoChatStream()
        for line in [
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"private reasoning\"}}]}", "",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"前方\"}}]}", "",
            "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"有一把椅子。\"},\"finish_reason\":\"stop\"}]}", "",
            "data: [DONE]", ""
        ] { try stream.receive(line: line) }
        #expect(try stream.finish() == "前方有一把椅子。")
    }

    @Test func truncatedResponseIsNotSpoken() throws {
        var stream = PhotoChatStream()
        try stream.receive(line: "data: {\"choices\":[{\"delta\":{\"content\":\"半句\"}}]}")
        try stream.receive(line: "")
        #expect(throws: PhotoChatError.self) { try stream.finish() }
    }

    @Test func emptyAnswerAndMissingKeyFail() throws {
        var stream = PhotoChatStream()
        try stream.receive(line: "data: [DONE]")
        #expect(throws: PhotoChatError.self) { try stream.finish() }
        #expect(throws: PhotoChatError.self) {
            try PhotoChatProtocol.request(jpeg: Data([1]), text: "test", key: " ")
        }
    }
}

struct PhotoPressTests {
    @Test func shortPressAndThreshold() {
        var press = PhotoPressState()
        press.begin(at: 10)
        #expect(press.release(at: 10.499) == [.shortCapture])
        press.begin(at: 20)
        #expect(press.release(at: 20.5) == [.startRecording, .stopRecording])
    }
    @Test func longPressStartsOnceAndCancelNeverSubmits() {
        var press = PhotoPressState()
        press.begin(at: 0)
        #expect(press.advance(to: 0.5) == .startRecording)
        #expect(press.advance(to: 0.6) == .none)
        #expect(press.release(at: 1) == [.stopRecording])
        press.begin(at: 2)
        press.cancel()
        #expect(press.release(at: 3).isEmpty)
        #expect(press.advance(to: 3) == .none)
    }
}

import CoreVideo
import UIKit
import SpatialCore

struct PhotoImageTests {
    @Test func imageRotationRetainsFullAspectRatio() throws {
        var storage: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess)
        let buffer = try #require(storage)
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 100, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for orientation in ImageOrientation.allCases {
            let data = try PhotoImageEncoder.jpeg(pixelBuffer: buffer, orientation: orientation)
            let image = try #require(UIImage(data: data)?.cgImage)
            #expect(image.width == (orientation.swapsAxes ? 480 : 640))
            #expect(image.height == (orientation.swapsAxes ? 640 : 480))
        }
    }
}

/// Intercepts every request in these tests; no DNS, real credentials or photos.
nonisolated final class PhotoMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let unauthorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer test-401"
        let response = HTTPURLResponse(url: request.url!, statusCode: unauthorized ? 401 : 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let sse = "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"not spoken\",\"content\":\"前方是门。\"},\"finish_reason\":\"stop\"}]}\r\n\r\ndata: [DONE]\r\n\r\n"
        client?.urlProtocol(self, didLoad: Data((unauthorized ? "private server error" : sse).utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

struct PhotoTransportTests {
    @Test func receivesMockStreamWithoutReasoning() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoMockURLProtocol.self]
        let answer = try await PhotoChatClient().describe(jpeg: Data([1]), text: "测试", key: "test-only", configuration: configuration)
        #expect(answer == "前方是门。")
    }
    @Test func HTTPFailureDoesNotExposeServerBody() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotoMockURLProtocol.self]
        do {
            _ = try await PhotoChatClient().describe(jpeg: Data([1]), text: "测试", key: "test-401", configuration: configuration)
            Issue.record("HTTP failure must throw")
        } catch {
            #expect(error.localizedDescription.contains("401"))
            #expect(!error.localizedDescription.contains("private server error"))
        }
    }
}
