import AVFoundation
import Testing
import UIKit
@testable import PRTS

@MainActor
struct PhotoPresentationTests {
    @Test func cameraControlOpacityAndTouchCancellation() throws {
        let button = PhotoCaptureButton.makeControl()
        button.frame = CGRect(x: 0, y: 0, width: 160, height: 160)
        button.layoutIfNeeded()
        #expect(button.image(for: .normal) != nil)
        #expect(button.alpha * (button.imageView?.alpha ?? 1) == 0.25)
        #expect(button.accessibilityIdentifier == "photoCaptureButton")
        #expect(button.accessibilityCustomActions?.count == 2)
        var actions: [String] = []
        button.down = { actions.append("down") }
        button.up = { actions.append("up") }
        button.cancel = { actions.append("cancel") }
        button.sendActions(for: .touchDown)
        button.sendActions(for: .touchDragExit)
        #expect(actions == ["down", "cancel"])
        actions.removeAll()
        #expect(button.accessibilityActivate())
        #expect(actions == ["down", "up"])
        button.isHighlighted = true
        button.layoutIfNeeded()
        #expect(button.alpha == 0.25)
        button.isHighlighted = false
        button.layoutIfNeeded()
        #expect(button.alpha * (button.imageView?.alpha ?? 1) == 0.25)
    }

    @Test func nativeToneAssetsAreDistinctAndDecodableWithoutPlayback() throws {
        let a = PhotoAudioOutput.toneData(for: .submit)
        let b = PhotoAudioOutput.toneData(for: .record)
        #expect(a != b)
        for data in [a, b] {
            let player = try AVAudioPlayer(data: data)
            #expect(abs(player.duration - 0.1) < 0.001)
            #expect(player.numberOfChannels == 1)
            #expect(!player.isPlaying)
        }
    }

    @Test func answerSpeechMatchesAnnouncementVoiceAndRate() throws {
        let suite = "PhotoPresentationTests.voice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "followSystemLanguageEnabled")

        for language in SpeechLanguage.allCases {
            defaults.set(language.rawValue, forKey: "selectedLanguage")
            for rate in SpeechRateOption.allCases {
                defaults.set(rate.rawValue, forKey: "speechRateOption")
                let answer = PhotoAudioOutput.answerUtterance("前方有门。", defaults: defaults)
                let announcement = SpeechManager.announcementUtterance(
                    "前方有门。", rate: rate, language: language
                )
                #expect(answer.speechString == announcement.speechString)
                #expect(answer.voice?.identifier == announcement.voice?.identifier)
                #expect(answer.rate == announcement.rate)
                #expect(answer.pitchMultiplier == announcement.pitchMultiplier)
                #expect(answer.volume == announcement.volume)
                #expect(answer.rate == rate.avSpeechRate)
                #expect(answer.pitchMultiplier == 1)
            }
        }
    }

    @Test func answerSpeechReadsCurrentPreferencesForEveryResponse() throws {
        let suite = "PhotoPresentationTests.currentVoice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "followSystemLanguageEnabled")
        defaults.set(SpeechLanguage.chinese.rawValue, forKey: "selectedLanguage")
        defaults.set(SpeechRateOption.slow.rawValue, forKey: "speechRateOption")
        let first = PhotoAudioOutput.answerUtterance("门在左边。", defaults: defaults)
        #expect(first.rate == SpeechRateOption.slow.avSpeechRate)

        defaults.set(SpeechRateOption.fast.rawValue, forKey: "speechRateOption")
        defaults.set(SpeechLanguage.english.rawValue, forKey: "selectedLanguage")
        let second = PhotoAudioOutput.answerUtterance("The door is on the left.", defaults: defaults)
        #expect(second.rate == SpeechRateOption.fast.avSpeechRate)
        #expect(second.voice?.identifier == AVSpeechSynthesisVoice(language: "en-US")?.identifier)
        // The automatic-announcement switch must not mute a manually requested answer.
        defaults.set(false, forKey: "voiceAnnouncementsEnabled")
        #expect(PhotoAudioOutput.answerUtterance("回答", defaults: defaults).speechString == "回答")
    }

    @Test func answerSpeechUsesTheSameSystemLanguageAndDefaultsAsAnnouncements() throws {
        let suite = "PhotoPresentationTests.defaultVoice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let expected = SpeechManager.announcementUtterance(
            "回答", rate: .normal, language: .fromSystemLanguage()
        )
        let answer = PhotoAudioOutput.answerUtterance("回答", defaults: defaults)
        #expect(answer.voice?.identifier == expected.voice?.identifier)
        #expect(answer.rate == expected.rate)
        #expect(answer.pitchMultiplier == expected.pitchMultiplier)

        defaults.set(true, forKey: "followSystemLanguageEnabled")
        defaults.set(SpeechLanguage.chinese.rawValue, forKey: "selectedLanguage")
        #expect(PhotoAudioOutput.answerUtterance("回答", defaults: defaults).voice?.identifier
                == expected.voice?.identifier)
    }
}
