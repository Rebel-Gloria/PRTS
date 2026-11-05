import Foundation
import Testing

@testable import PRTS

struct LiveCaptionRequestTests {
    @Test(arguments: [nil, "一个人从左边走过。"] as [String?])
    func videoContainsFourFramesThenPreviousSentence(previous: String?) throws {
        let frames = [Data([1]), Data([2]), Data([3]), Data([4])]
        let request = try LiveCaptionBackend.request(
            video: frames,
            previous: previous,
            key: "synthetic-test-key"
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.url == PhotoChatService.qwen.endpoint)
        #expect(body["model"] as? String == "qwen3.8-omni-flash")
        #expect(body["max_tokens"] as? Int == 24)
        #expect(body["enable_thinking"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 2)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == LiveCaptionPrompts.system)
        #expect(messages[1]["role"] as? String == "user")
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "video")
        #expect(
            content[0]["video"] as? [String]
                == frames.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
        )
        #expect(content[1]["type"] as? String == "text")
        #expect(content[1]["text"] as? String == "上一句：\(previous ?? "无")")
    }

    @Test func openingUsesSingleImageAndFortyTokens() throws {
        let request = try PhotoChatProtocol.request(
            jpeg: Data([1]),
            text: SceneDescriptionPrompt.request,
            key: "synthetic-test-key",
            system: LiveCaptionPrompts.opening,
            maxTokens: 40
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 40)
        #expect(body["enable_thinking"] as? Bool == false)
        #expect(body["stream"] as? Bool == true)
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == LiveCaptionPrompts.opening)
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content[0]["text"] as? String == "描述眼前。")
        #expect(content[1]["type"] as? String == "image_url")
    }

    @Test func ordinaryDescriptionsKeepExistingLimit() throws {
        let request = try PhotoChatProtocol.request(
            jpeg: Data([1]),
            text: SceneDescriptionPrompt.request,
            key: "synthetic-test-key",
            system: PhotoPrompts.system
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] == nil)
    }
}
