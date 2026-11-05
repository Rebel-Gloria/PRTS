import AVFoundation

enum SpeechRateOption: String, CaseIterable, Identifiable, Hashable {
    case slow = "Slow"
    case normal = "Normal"
    case fast = "Fast"

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .slow:
            return "settings.rate.slow"
        case .normal:
            return "settings.rate.normal"
        case .fast:
            return "settings.rate.fast"
        }
    }

    var avSpeechRate: Float {
        switch self {
        case .slow:
            return 0.42
        case .normal:
            return AVSpeechUtteranceDefaultSpeechRate
        case .fast:
            return 0.58
        }
    }
}

@MainActor
enum SpeechVoice {
    /// Shared voice profile for announcements and manually requested photo answers.
    /// Keep the system pitch/volume; only the existing language and rate settings vary.
    static func utterance(
        _ message: String,
        rate: SpeechRateOption,
        language: SpeechLanguage
    ) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = rate.avSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: language.localeIdentifier)
        // With VoiceOver on, cues and photo answers use its voice and rate instead.
        utterance.prefersAssistiveTechnologySettings = true
        return utterance
    }

    /// Photo responses read preferences at playback time without creating another
    /// SpeechManager or sharing announcement cancellation/queue ownership.
    static func utterance(
        _ message: String,
        defaults: UserDefaults = .standard
    ) -> AVSpeechUtterance {
        let rate =
            SpeechRateOption(
                rawValue: defaults.string(forKey: SpeechPreferences.Key.speechRateOption) ?? ""
            ) ?? .normal
        let language = SpeechPreferences.language(defaults: defaults)
        return utterance(message, rate: rate, language: language)
    }

}
