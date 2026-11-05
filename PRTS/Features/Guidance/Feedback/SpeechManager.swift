/// User-facing speech service. Perception cues and settings announcements have separate cancellation ownership.

//
//  SpeechManager.swift
//  PRTS
//

import AVFoundation
import Combine
import UIKit

@MainActor
final class SpeechManager: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var voiceAnnouncementsEnabled: Bool
    @Published private(set) var rateOption: SpeechRateOption
    @Published private(set) var followSystemLanguageEnabled: Bool
    @Published private(set) var selectedLanguage: SpeechLanguage

    private let synthesizer = AVSpeechSynthesizer()
    private let audioSession: AudioSessionCoordinator
    private var audioLease: AudioSessionCoordinator.Lease?
    private var activeUtterance: ObjectIdentifier?
    private var perceptionSpeechActive = false
    var isSpeakingPerception: Bool { perceptionSpeechActive && synthesizer.isSpeaking }
    private(set) var lastSettingsAnnouncement: String?
    func speakPerception(_ message: String) {
        speak(message)
        perceptionSpeechActive = voiceAnnouncementsEnabled
    }
    func cancelPerceptionSpeech() {
        guard perceptionSpeechActive else { return }
        stopCurrentSpeech()
    }

    override convenience init() { self.init(audioSession: .shared) }

    init(audioSession: AudioSessionCoordinator) {
        self.audioSession = audioSession
        let defaults = UserDefaults.standard
        voiceAnnouncementsEnabled =
            defaults.object(
                forKey: SpeechPreferences.Key.voiceAnnouncementsEnabled
            ) as? Bool ?? true
        rateOption =
            SpeechRateOption(
                rawValue: defaults.string(forKey: SpeechPreferences.Key.speechRateOption) ?? ""
            ) ?? .normal
        followSystemLanguageEnabled =
            defaults.object(
                forKey: SpeechPreferences.Key.followSystemLanguageEnabled
            ) as? Bool ?? true
        selectedLanguage =
            SpeechLanguage(
                rawValue: defaults.string(forKey: SpeechPreferences.Key.selectedLanguage) ?? ""
            ) ?? .english
        super.init()
        synthesizer.delegate = self
    }

    /// The locale used by SwiftUI for the entire app. For unsupported system
    /// languages, English is the supported fallback.
    var interfaceLocale: Locale {
        Locale(identifier: activeLanguage.resourceIdentifier)
    }

    /// UIKit and status strings in the same language as the SwiftUI interface.
    func interfaceString(_ key: String) -> String {
        localized(key)
    }

    func speakHomeScreen(cameraState: CameraState = .idle) {
        let cameraStatusKey =
            cameraState == .running
            ? "speech.camera.liveStatus"
            : "speech.camera.readyStatus"
        let cameraActionKey =
            cameraState == .running
            ? "speech.camera.stopAction" : "speech.camera.startAction"

        announce(
            localized(
                "speech.home",
                arguments: [localized(cameraStatusKey), localized(cameraActionKey)]
            )
        )
    }

    func speakSettingsScreen() {
        let message = localized(
            "speech.settings.summary",
            arguments: [
                localized(voiceAnnouncementsEnabled ? "speech.value.on" : "speech.value.off"),
                localized(rateOption.localizationKey),
                languageSettingAnnouncement,
            ]
        )
        lastSettingsAnnouncement = message
        announceSetting(message)
    }

    func speak(_ message: String) {
        perceptionSpeechActive = false
        guard voiceAnnouncementsEnabled else { return }

        stopCurrentSpeech()
        prepareAudioSession()

        let utterance = SpeechVoice.utterance(
            message,
            rate: rateOption,
            language: activeLanguage
        )
        activeUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    /// Interface status. With VoiceOver running it is handed to VoiceOver and queued behind
    /// what VoiceOver is reading, so it is never spoken twice or on top of the screen reader.
    func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else {
            speak(message)
            return
        }
        perceptionSpeechActive = false
        guard voiceAnnouncementsEnabled else { return }
        Self.postQueuedAnnouncement(message)
    }

    /// Camera state used to go to both VoiceOver and the synthesizer; now it uses one channel.
    func announceCameraState(_ state: CameraState) {
        if UIAccessibility.isVoiceOverRunning {
            Self.postQueuedAnnouncement(accessibilityAnnouncement(for: state))
        } else {
            speakCameraState(state)
        }
    }

    static func postQueuedAnnouncement(_ message: String) {
        UIAccessibility.post(
            notification: .announcement,
            argument: NSAttributedString(
                string: message,
                attributes: [.accessibilitySpeechQueueAnnouncement: true]
            )
        )
    }

    func speakCameraState(_ state: CameraState) {
        switch state {
        case let .unavailable(reason):
            speak(
                localized(
                    "speech.camera.unavailable",
                    arguments: [localized(reason.localizationKey)]
                )
            )
        default:
            speak(localized(state.speechLocalizationKey))
        }
    }

    func accessibilityAnnouncement(for state: CameraState) -> String {
        switch state {
        case let .unavailable(reason):
            return localized(
                "accessibility.camera.unavailable",
                arguments: [localized(reason.localizationKey)]
            )
        default:
            return localized(state.accessibilityLocalizationKey)
        }
    }

    func setVoiceAnnouncementsEnabled(_ enabled: Bool) {
        voiceAnnouncementsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: SpeechPreferences.Key.voiceAnnouncementsEnabled)

        if enabled {
            announceSetting(localized("speech.voice.enabled"))
        } else {
            stopCurrentSpeech()
        }
    }

    func setRateOption(_ option: SpeechRateOption) {
        rateOption = option
        UserDefaults.standard.set(option.rawValue, forKey: SpeechPreferences.Key.speechRateOption)

        announceSetting(
            localized("speech.rate.changed", arguments: [localized(option.localizationKey)])
        )
    }

    func setFollowSystemLanguageEnabled(_ enabled: Bool) {
        followSystemLanguageEnabled = enabled
        UserDefaults.standard.set(
            enabled,
            forKey: SpeechPreferences.Key.followSystemLanguageEnabled
        )
        speakLanguageSetting()
    }

    func setSelectedLanguage(_ language: SpeechLanguage) {
        selectedLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: SpeechPreferences.Key.selectedLanguage)

        guard !followSystemLanguageEnabled else { return }
        speakLanguageSetting()
    }

    func stopCurrentSpeech() {
        perceptionSpeechActive = false
        activeUtterance = nil
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audioSession.release(audioLease)
        audioLease = nil
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == id else { return }
            self.activeUtterance = nil
            self.perceptionSpeechActive = false
            self.audioSession.release(self.audioLease)
            self.audioLease = nil
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        speechSynthesizer(synthesizer, didFinish: utterance)
    }

    private var activeLanguage: SpeechLanguage {
        followSystemLanguageEnabled ? .fromSystemLanguage() : selectedLanguage
    }

    private var languageSettingAnnouncement: String {
        if followSystemLanguageEnabled {
            return localized("speech.language.followSystem")
        }

        return localized(
            "speech.language.custom",
            arguments: [localized(selectedLanguage.displayNameLocalizationKey)]
        )
    }

    private func speakLanguageSetting() {
        announceSetting(languageSettingAnnouncement)
    }

    /// Settings feedback. VoiceOver already reads the screen and each control's new value, so
    /// with VoiceOver running these would only repeat it.
    private func announceSetting(_ message: String) {
        guard !UIAccessibility.isVoiceOverRunning else { return }
        announce(message)
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key, language: activeLanguage)
    }

    private func localized(_ key: String, arguments: [CVarArg]) -> String {
        AppLocalization.string(key, language: activeLanguage, arguments: arguments)
    }

    private func prepareAudioSession() {
        do {
            audioLease = try audioSession.activate(.speech)
        } catch {
            // Speech synthesis can still work when another audio session owns the audio route.
            ErrorLog.application.record(error, source: .audio)
        }
    }
}
