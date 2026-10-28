import Foundation

/// Photo description providers. Every one speaks OpenAI-compatible streaming Chat Completions
/// with an inline JPEG; presets only differ in endpoint, model and one Qwen-specific flag.
nonisolated enum PhotoChatProvider: String, CaseIterable, Identifiable, Sendable {
    case qwen, deepseek, custom

    var id: String { rawValue }

    static let selectionKey = "photoDescription.provider"
    static let customEndpointKey = "photoDescription.customEndpoint"
    static let customModelKey = "photoDescription.customModel"

    static func current(_ defaults: UserDefaults = .standard) -> PhotoChatProvider {
        defaults.string(forKey: selectionKey).flatMap(PhotoChatProvider.init(rawValue:)) ?? .qwen
    }

    /// The Qwen key keeps the original Keychain account so existing installs stay configured.
    var keyAccount: String { self == .qwen ? "api-key" : "api-key.\(rawValue)" }

    /// nil only for an incomplete custom entry.
    func service(_ defaults: UserDefaults = .standard) -> PhotoChatService? {
        switch self {
        case .qwen: return .qwen
        case .deepseek: return .deepseek
        case .custom:
            let model = (defaults.string(forKey: Self.customModelKey) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty, let url = PhotoChatService.chatURL(from: defaults.string(forKey: Self.customEndpointKey) ?? "") else { return nil }
            return PhotoChatService(endpoint: url, model: model, thinking: .standard)
        }
    }
}

nonisolated struct PhotoChatService: Equatable, Sendable {
    var endpoint: URL
    var model: String
    /// How this provider turns reasoning off; custom endpoints get only standard fields.
    var thinking: ThinkingSwitch

    enum ThinkingSwitch: Sendable { case qwenFlag, deepseekObject, standard }

    static let qwen = PhotoChatService(endpoint: PhotoChatProtocol.endpoint, model: PhotoChatProtocol.model, thinking: .qwenFlag)
    static let deepseek = PhotoChatService(endpoint: URL(string: "https://api.deepseek.com/chat/completions")!,
                                           model: "deepseek-flash", thinking: .deepseekObject)

    /// Accepts a base URL ("https://host/v1") or the full Chat Completions URL. HTTPS only:
    /// the request carries the API key and a camera image.
    static func chatURL(from text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.query == nil, parts.fragment == nil else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if !path.hasSuffix("/chat/completions") { path += "/chat/completions" }
        parts.path = path
        return parts.url
    }
}
