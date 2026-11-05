import Foundation
import Testing

@testable import PRTS

@MainActor
private final class GuideTestAudio: AnswerAudio {
    var onFinished: (() -> Void)?
    var active = false
    var fail = false
    var stops = 0
    var spoken: [String] = []
    func cue(_ cue: AnswerCue) throws {}
    func speak(_ text: String) throws {
        active = true
        spoken.append(text)
        if fail { throw PhotoChatError.emptyAnswer }
    }
    func stop() {
        active = false
        stops += 1
    }
}

@MainActor
struct UserGuideReaderTests {
    @Test(arguments: [false, true])
    func completionAndExplicitStopBothReleaseOutput(explicit: Bool) {
        let audio = GuideTestAudio()
        let reader = UserGuideReader(errors: .ignored) { rate, language in
            #expect(rate == .slow)
            #expect(language == .english)
            return audio
        }
        reader.read("Guide", rate: .slow, language: .english)
        #expect(reader.isReading)
        #expect(audio.active)
        if explicit { reader.stop() } else { audio.onFinished?() }
        #expect(!reader.isReading)
        #expect(!audio.active)
        #expect(audio.stops == 1)
        reader.stop()
        #expect(audio.stops == 1)
    }

    @Test func previousCompletionCannotStopNewPlayback() {
        var outputs: [GuideTestAudio] = []
        let reader = UserGuideReader(errors: .ignored) { _, _ in
            let audio = GuideTestAudio()
            outputs.append(audio)
            return audio
        }
        reader.read("First", rate: .normal, language: .english)
        let oldCompletion = outputs[0].onFinished
        reader.stop()
        reader.read("Second", rate: .normal, language: .english)
        oldCompletion?()
        #expect(reader.isReading)
        #expect(outputs[1].active)
        #expect(outputs[1].stops == 0)
        reader.stop()
    }

    @Test func failedPlaybackReleasesActivatedOutput() {
        let audio = GuideTestAudio()
        audio.fail = true
        let reader = UserGuideReader(errors: .ignored) { _, _ in audio }
        reader.read("Guide", rate: .normal, language: .english)
        #expect(!reader.isReading)
        #expect(!audio.active)
        #expect(audio.stops == 1)
    }

    @Test func inputAndOutputUseCurrentLanguagePreference() throws {
        let suite = "SpeechPreferences.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SpeechPreferences.language(defaults: defaults) == .fromSystemLanguage())
        defaults.set(false, forKey: "followSystemLanguageEnabled")
        for language in [SpeechLanguage.chinese, .english] {
            defaults.set(language.rawValue, forKey: "selectedLanguage")
            #expect(SpeechPreferences.language(defaults: defaults) == language)
            #expect(
                SpeechPreferences.language(defaults: defaults).locale.identifier
                    == language.localeIdentifier
            )
        }
        defaults.set(true, forKey: "followSystemLanguageEnabled")
        #expect(SpeechPreferences.language(defaults: defaults) == .fromSystemLanguage())
    }
}
