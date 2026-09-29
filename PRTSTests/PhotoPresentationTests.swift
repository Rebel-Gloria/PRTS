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

    @Test func answerSpeechUsesSeparatePitchAndMandarinVoice() {
        let utterance = PhotoAudioOutput.answerUtterance("前方有门。")
        #expect(utterance.speechString == "前方有门。")
        #expect(utterance.pitchMultiplier == 0.8)
        #expect(utterance.rate == 0.46)
        if let voice = utterance.voice { #expect(voice.language == "zh-CN") }
        let defaultID = AVSpeechSynthesisVoice(language: "zh-CN")?.identifier
        if AVSpeechSynthesisVoice.speechVoices().contains(where: { $0.language == "zh-CN" && $0.identifier != defaultID }) {
            #expect(utterance.voice?.identifier != defaultID)
        }
    }
}
