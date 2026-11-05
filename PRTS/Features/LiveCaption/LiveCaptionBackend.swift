import Foundation

nonisolated enum LiveCaptionBackend {
    static func captionOpening(jpeg: Data, key: String) async throws -> String {
        try await PhotoChatClient().describe(
            jpeg: jpeg,
            text: SceneDescriptionPrompt.request,
            key: key,
            service: PhotoChatProvider.qwen.service(),
            system: LiveCaptionPrompts.opening,
            maxTokens: 40
        )
    }

    static func caption(video: [Data], previous: String?, key: String) async throws -> String {
        try await PhotoChatClient().send(
            request(video: video, previous: previous, key: key)
        )
    }

    static func request(
        video: [Data],
        previous: String?,
        key: String,
        service: PhotoChatService? = PhotoChatProvider.qwen.service()
    ) throws -> URLRequest {
        guard let service else { throw PhotoChatError.invalidService }
        let text = "上一句：\(previous ?? "无")"
        return try PhotoChatProtocol.request(
            content: [
                ["type": "video", "video": video.map(PhotoChatProtocol.dataURL)],
                ["type": "text", "text": text],
            ],
            text: text,
            key: key,
            service: service,
            system: LiveCaptionPrompts.system,
            thinking: false,
            maxTokens: 24
        )
    }
}
