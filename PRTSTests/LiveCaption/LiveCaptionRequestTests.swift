import Foundation
import Testing

@testable import PRTS

struct LiveCaptionRequestTests {
    @Test(arguments: [PhotoChatService.qwen, .deepseek])
    func changesLimitTokensAndDisableThinking(service: PhotoChatService) throws {
        let request = try PhotoChatProtocol.request(
            jpeg: Data([1]),
            text: "开场：桌上放着一台电脑。\n上一句：无",
            key: "synthetic-test-key",
            service: service,
            system: PhotoPrompts.liveCaptionSystem,
            thinking: false,
            maxTokens: 24
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] as? Int == 24)
        switch service.thinking {
        case .qwenFlag: #expect(body["enable_thinking"] as? Bool == false)
        case .deepseekObject:
            #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        case .standard: break
        }
        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages[0]["content"] as? String == PhotoPrompts.liveCaptionSystem)
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content[0]["text"] as? String == "开场：桌上放着一台电脑。\n上一句：无")
    }

    @Test func ordinaryDescriptionsKeepExistingLimit() throws {
        let request = try PhotoChatProtocol.request(
            jpeg: Data([1]),
            text: PhotoPrompts.prompt,
            key: "synthetic-test-key"
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["max_tokens"] == nil)
    }
}
