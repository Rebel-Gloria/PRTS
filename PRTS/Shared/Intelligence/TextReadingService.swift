import Foundation

/// Text reading can follow the default provider, select a provider, or use Apple Vision.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vlm, onDevice, qwen, deepseek, custom, vision

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// The former "remote" value no longer decodes, so it reads as .vlm.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:))
            ?? .vlm
    }

    func provider(_ defaults: UserDefaults = .standard) -> PhotoChatProvider? {
        switch self {
        case .vlm: PhotoChatProvider.current(defaults)
        case .vision: nil
        case .onDevice, .qwen, .deepseek, .custom: PhotoChatProvider(rawValue: rawValue)!
        }
    }

    var localizationKey: String {
        switch self {
        case .vlm: "intelligence.provider.default"
        case .vision: "settings.ocr.service.vision"
        case .onDevice, .qwen, .deepseek, .custom: "photo.settings.provider.\(rawValue)"
        }
    }

}
