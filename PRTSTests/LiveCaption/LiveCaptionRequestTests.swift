import Foundation
import Testing
import UIKit

@testable import PRTS

struct LiveCaptionRequestTests {
    @Test(arguments: [nil, "一个人从左边走过。"] as [String?])
    func videoContainsFourFramesThenPreviousSentence(previous: String?) throws {
        let frames = [Data([1]), Data([2]), Data([3]), Data([4])]
        let request = try LiveCaptionBackend.request(
            video: frames,
            previous: previous,
            key: "synthetic-test-key",
            service: .qwen
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(request.url == PhotoChatService.qwen.endpoint)
        #expect(body["model"] as? String == PhotoChatService.qwen.model)
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

    @Test func deepSeekReceivesFramesAsImagesInOrder() throws {
        let frames = [Data([1]), Data([2]), Data([3]), Data([4])]
        let request = try LiveCaptionBackend.request(
            video: frames,
            previous: nil,
            key: "synthetic-test-key",
            service: .deepseek
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == PhotoChatService.deepseek.model)
        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        let messages = try #require(body["messages"] as? [[String: Any]])
        let content = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(content.count == 5)
        #expect(content.prefix(4).allSatisfy { $0["type"] as? String == "image_url" })
        #expect(
            content.prefix(4).map { ($0["image_url"] as? [String: String])?["url"] }
                == frames.map { "data:image/jpeg;base64,\($0.base64EncodedString())" }
        )
        #expect((content[4]["text"] as? String)?.contains("按时间顺序") == true)
    }

    @Test func modelChoiceDefaultsToQwenAndRejectsOthers() {
        let name = "LiveCaptionRequestTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(LiveCaptionModel.current(defaults) == .qwen)
        defaults.set(PhotoChatProvider.deepseek.rawValue, forKey: LiveCaptionModel.selectionKey)
        #expect(LiveCaptionModel.current(defaults) == .deepseek)
        defaults.set(PhotoChatProvider.onDevice.rawValue, forKey: LiveCaptionModel.selectionKey)
        #expect(LiveCaptionModel.current(defaults) == .onDevice)
        defaults.set(PhotoChatProvider.custom.rawValue, forKey: LiveCaptionModel.selectionKey)
        #expect(LiveCaptionModel.current(defaults) == .qwen)
    }

    @Test func collageKeepsFramesInReadingOrder() throws {
        func frame(_ color: CGFloat) throws -> Data {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let size = CGSize(width: 40, height: 40)
            let image = UIGraphicsImageRenderer(size: size, format: format).image {
                UIColor(white: color, alpha: 1).setFill()
                $0.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
            }
            return try #require(image.jpegData(compressionQuality: 1))
        }
        let jpeg = try LiveCaptionCollage.jpeg(
            frames: [try frame(0), try frame(0.33), try frame(0.66), try frame(1)]
        )
        let image = try #require(UIImage(data: jpeg)?.cgImage)
        #expect(image.width == 40)
        #expect(image.height == 40)
        let pixels = try #require(image.dataProvider?.data as Data?)
        let row = image.bytesPerRow
        let brightness = [
            pixels[10 * row + 10 * 4], pixels[10 * row + 30 * 4],
            pixels[30 * row + 10 * 4], pixels[30 * row + 30 * 4],
        ]
        #expect(brightness == brightness.sorted())
        #expect(brightness[0] < 30)
        #expect(brightness[3] > 225)
    }

    @Test func omniKeepsThinkingOff() throws {
        let request = try LiveCaptionBackend.request(
            video: [Data([1]), Data([2]), Data([3]), Data([4])],
            previous: nil,
            key: "synthetic-test-key",
            service: .qwenOmni
        )
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["model"] as? String == "qwen3.8-omni-flash")
        #expect(body["enable_thinking"] as? Bool == false)
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
