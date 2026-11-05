import Combine
import Foundation

/// Owns a guide playback, using the same cancellable output as other requested speech.
@MainActor
final class UserGuideReader: ObservableObject {
    @Published private(set) var isReading = false
    private let makeAudio: (SpeechRateOption, SpeechLanguage) -> any AnswerAudio
    private let errors: ErrorReporter
    private var audio: (any AnswerAudio)?
    private var generation = UUID()

    convenience init() {
        self.init { rate, language in
            AnswerAudioOutput(makeUtterance: {
                SpeechVoice.utterance($0, rate: rate, language: language)
            })
        }
    }

    init(
        errors: ErrorReporter = .init(source: .audio),
        makeAudio: @escaping (SpeechRateOption, SpeechLanguage) -> any AnswerAudio
    ) {
        self.errors = errors
        self.makeAudio = makeAudio
    }

    func read(_ text: String, rate: SpeechRateOption, language: SpeechLanguage) {
        stop()
        let id = generation
        let output = makeAudio(rate, language)
        audio = output
        output.onFinished = { [weak self] in
            guard let self, self.generation == id else { return }
            self.stop()
        }
        do {
            try output.speak(text)
            isReading = true
        } catch {
            errors.record(error)
            stop()
        }
    }

    func stop() {
        generation = UUID()
        audio?.stop()
        audio = nil
        isReading = false
    }
}
