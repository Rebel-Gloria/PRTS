import Foundation

/// One interpretation of the persisted voice settings for speech input and output.
nonisolated struct SpeechPreferences {
    enum Key {
        static let voiceAnnouncementsEnabled = "voiceAnnouncementsEnabled"
        static let speechRateOption = "speechRateOption"
        static let followSystemLanguageEnabled = "followSystemLanguageEnabled"
        static let selectedLanguage = "selectedLanguage"
    }

    static func language(defaults: UserDefaults = .standard) -> SpeechLanguage {
        let followSystem = defaults.object(forKey: Key.followSystemLanguageEnabled) as? Bool ?? true
        let selected =
            SpeechLanguage(rawValue: defaults.string(forKey: Key.selectedLanguage) ?? "")
            ?? .english
        return followSystem ? .fromSystemLanguage() : selected
    }
}
