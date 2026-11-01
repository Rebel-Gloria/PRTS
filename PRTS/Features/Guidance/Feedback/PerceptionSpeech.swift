import Combine
import Foundation
import SpatialCore

@MainActor
extension SpeechManager {
    func speakPerception(_ chinese: String, english: String) {
        speakPerception(
            (followSystemLanguageEnabled ? SpeechLanguage.fromSystemLanguage() : selectedLanguage)
                == .chinese ? chinese : english
        )
    }
}
