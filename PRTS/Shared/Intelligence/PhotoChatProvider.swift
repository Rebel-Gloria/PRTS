import Foundation

/// Provider selection shared across features; transport configuration lives in PhotoChatService.
nonisolated enum PhotoChatProvider: String, CaseIterable, Identifiable, Sendable {
    case onDevice, qwen, deepseek, custom

    var id: String { rawValue }

    static let selectionKey = "photoDescription.provider"
    static let customEndpointKey = "photoDescription.customEndpoint"
    static let customModelKey = "photoDescription.customModel"
    /// Broader local questions are opt-in; they do not enable model reasoning or change OCR.
    static let localEnhancedKey = "photoDescription.localEnhanced"
    /// Every Qwen request follows this, live captions included.
    static let qwenOmniKey = "photoDescription.qwenOmni"

    /// On device by default: PRTS has to work without a network.
    static func current(_ defaults: UserDefaults = .standard) -> PhotoChatProvider {
        defaults.string(forKey: selectionKey).flatMap(PhotoChatProvider.init(rawValue:))
            ?? .onDevice
    }

    var localizationKey: String { "photo.settings.provider.\(rawValue)" }

    var questionThinkingKey: String {
        self == .qwen
            ? "photoDescription.questionThinking" : "photoDescription.questionThinking.deepseek"
    }

    func questionThinking(_ defaults: UserDefaults = .standard) -> Bool {
        switch self {
        case .qwen, .deepseek: defaults.bool(forKey: questionThinkingKey)
        case .onDevice, .custom: false
        }
    }

    /// The Qwen key keeps the original Keychain account so existing installs stay configured.
    var keyAccount: String { self == .qwen ? "api-key" : "api-key.\(rawValue)" }

    /// nil on device and for an incomplete custom entry.
    func service(_ defaults: UserDefaults = .standard) -> PhotoChatService? {
        switch self {
        case .onDevice: return nil
        case .qwen: return defaults.bool(forKey: Self.qwenOmniKey) ? .qwenOmni : .qwen
        case .deepseek: return .deepseek
        case .custom:
            let model = (defaults.string(forKey: Self.customModelKey) ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !model.isEmpty,
                let url = PhotoChatService.chatURL(
                    from: defaults.string(forKey: Self.customEndpointKey) ?? ""
                )
            else { return nil }
            return PhotoChatService(endpoint: url, model: model, thinking: .standard)
        }
    }
}
