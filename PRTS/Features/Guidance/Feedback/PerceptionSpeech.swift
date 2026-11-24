import Foundation

@MainActor
extension SpeechManager {
    func speakPerception(_ chinese: String, english: String) {
        speakPerception(
            (followSystemLanguageEnabled ? SpeechLanguage.fromSystemLanguage() : selectedLanguage)
                == .chinese ? chinese : english
        )
    }
}
