import Foundation
import LocalVLM

nonisolated enum LiveCaptionBackend {
    static func captionOpening(
        jpeg: Data,
        key: String,
        provider: PhotoChatProvider = LiveCaptionModel.current()
    ) async throws -> String {
        if provider == .onDevice {
            return try await local(
                jpeg: jpeg,
                prompt: SceneDescriptionPrompt.request,
                system: LiveCaptionPrompts.opening,
                maxTokens: 40
            )
        }
        return try await PhotoChatClient().describe(
            jpeg: jpeg,
            text: SceneDescriptionPrompt.request,
            key: key,
            service: provider.service(),
            system: LiveCaptionPrompts.opening,
            maxTokens: 40
        )
    }

    static func caption(
        video: [Data],
        previous: String?,
        key: String,
        provider: PhotoChatProvider = LiveCaptionModel.current()
    ) async throws -> String {
        if provider == .onDevice {
            return try await local(
                jpeg: try LiveCaptionCollage.jpeg(frames: video),
                prompt: "上一句：\(previous ?? "无")",
                system: LiveCaptionPrompts.localSystem,
                maxTokens: 24
            )
        }
        return try await PhotoChatClient().send(
            request(video: video, previous: previous, key: key, service: provider.service())
        )
    }

    private static func local(
        jpeg: Data,
        prompt: String,
        system: String,
        maxTokens: Int
    ) async throws -> String {
        do {
            return try await PhotoLocalModel.shared.describe(
                jpeg: jpeg,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens
            )
        } catch LocalVLM.Failure.outputLimit {
            throw PhotoChatError.answerTooLong
        }
    }

    static func request(
        video: [Data],
        previous: String?,
        key: String,
        service: PhotoChatService?
    ) throws -> URLRequest {
        guard let service else { throw PhotoChatError.invalidService }
        var text = "上一句：\(previous ?? "无")"
        let frames: [[String: Any]]
        if service.acceptsVideo {
            frames = [["type": "video", "video": video.map(PhotoChatProtocol.dataURL)]]
        } else {
            frames = video.map {
                ["type": "image_url", "image_url": ["url": PhotoChatProtocol.dataURL($0)]]
            }
            text = "这些图片是一段视频的连续画面，按时间顺序排列。" + text
        }
        return try PhotoChatProtocol.request(
            content: frames + [["type": "text", "text": text]],
            text: text,
            key: key,
            service: service,
            system: LiveCaptionPrompts.system,
            thinking: false,
            maxTokens: 24
        )
    }
}
