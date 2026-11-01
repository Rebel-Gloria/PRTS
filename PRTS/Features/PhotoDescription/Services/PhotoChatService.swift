import Foundation

nonisolated struct PhotoChatService: Equatable, Sendable {
    var endpoint: URL
    var model: String
    /// How this provider turns reasoning off; custom endpoints get only standard fields.
    var thinking: ThinkingSwitch
    /// A dedicated text-recognition model on the same endpoint, used for reading text.
    var ocrModel: String? = nil

    enum ThinkingSwitch: Sendable { case qwenFlag, deepseekObject, standard }

    /// qwen-vl-ocr over qwen3.5-ocr: as fast and as accurate on text, and it said "无" on photos
    /// where qwen3.5-ocr made up a word (docs/features/text-reading.md).
    static let qwen = PhotoChatService(
        endpoint: PhotoChatProtocol.endpoint,
        model: PhotoChatProtocol.model,
        thinking: .qwenFlag,
        ocrModel: "qwen-vl-ocr"
    )
    static let deepseek = PhotoChatService(
        endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
        model: "deepseek-flash",
        thinking: .deepseekObject
    )

    /// Accepts a base URL ("https://host/v1") or the full Chat Completions URL. HTTPS only:
    /// the request carries the API key and a camera image.
    static func chatURL(from text: String) -> URL? {
        guard
            var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
            parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        return parts.url
    }
}
