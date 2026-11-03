import Foundation

nonisolated enum IntelligenceFeature: CaseIterable, Sendable {
    case description, question, textReading

    var selectionKey: String {
        switch self {
        case .description: "intelligence.provider.description"
        case .question: "intelligence.provider.question"
        case .textReading: TextReadingService.selectionKey
        }
    }

    /// Apple Vision has no model provider; text reading owns that selection.
    func provider(_ defaults: UserDefaults = .standard) -> PhotoChatProvider? {
        if self == .textReading {
            return TextReadingService.current(defaults).provider(defaults)
        }
        if let value = defaults.string(forKey: selectionKey) {
            return PhotoChatProvider(rawValue: value)!
        }
        return PhotoChatProvider.current(defaults)
    }
}
