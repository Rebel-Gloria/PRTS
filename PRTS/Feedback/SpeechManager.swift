/// User-facing speech service. Perception cues and settings announcements have separate cancellation ownership.

//
//  SpeechManager.swift
//  PRTS
//

import AVFoundation
import UIKit
import Combine

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
final class SpeechManager: ObservableObject {
    @Published private(set) var voiceAnnouncementsEnabled: Bool
    @Published private(set) var rateOption: SpeechRateOption
    @Published private(set) var followSystemLanguageEnabled: Bool
    @Published private(set) var selectedLanguage: SpeechLanguage

    private let synthesizer = AVSpeechSynthesizer()
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

    private enum DefaultsKey {
        static let voiceAnnouncementsEnabled = "voiceAnnouncementsEnabled"
        static let speechRateOption = "speechRateOption"
        static let followSystemLanguageEnabled = "followSystemLanguageEnabled"
        static let selectedLanguage = "selectedLanguage"
    }

    init() {
        let defaults = UserDefaults.standard
        voiceAnnouncementsEnabled = defaults.object(
            forKey: DefaultsKey.voiceAnnouncementsEnabled
        ) as? Bool ?? true
        rateOption = SpeechRateOption(
            rawValue: defaults.string(forKey: DefaultsKey.speechRateOption) ?? ""
        ) ?? .normal
        followSystemLanguageEnabled = defaults.object(
            forKey: DefaultsKey.followSystemLanguageEnabled
        ) as? Bool ?? true
        selectedLanguage = SpeechLanguage(
            rawValue: defaults.string(forKey: DefaultsKey.selectedLanguage) ?? ""
        ) ?? .english
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
        let cameraStatusKey = cameraState == .running
            ? "speech.camera.liveStatus"
            : "speech.camera.readyStatus"
        let cameraActionKey = cameraState == .running
            ? "speech.camera.stopAction"
            : "speech.camera.startAction"

        announce(localized(
            "speech.home",
            arguments: [localized(cameraStatusKey), localized(cameraActionKey)]
        ))
    }

    func speakSettingsScreen(hapticFeedbackEnabled: Bool) {
        let message = localized(
            "speech.settings.summary",
            arguments: [
                localized(voiceAnnouncementsEnabled ? "speech.value.on" : "speech.value.off"),
                localized(rateOption.localizationKey),
                languageSettingAnnouncement,
                localized(hapticFeedbackEnabled ? "speech.value.on" : "speech.value.off")
            ]
        )
        lastSettingsAnnouncement = message
        announce(message)
    }

    func speakHapticFeedbackState(_ enabled: Bool) {
        announce(localized(
            "speech.haptic.changed",
            arguments: [localized(enabled ? "speech.value.on" : "speech.value.off")]
        ))
    }

    func speak(_ message: String) {
        perceptionSpeechActive = false
        guard voiceAnnouncementsEnabled else { return }

        prepareAudioSession()
        stopCurrentSpeech()

        let utterance = Self.announcementUtterance(message, rate: rateOption, language: activeLanguage)
        synthesizer.speak(utterance)
    }

    /// Shared voice profile for announcements and manually requested photo answers.
    /// Keep the system pitch/volume; only the existing language and rate settings vary.
    static func announcementUtterance(
        _ message: String, rate: SpeechRateOption, language: SpeechLanguage
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
    static func announcementUtterance(
        _ message: String, defaults: UserDefaults = .standard
    ) -> AVSpeechUtterance {
        let rate = SpeechRateOption(
            rawValue: defaults.string(forKey: DefaultsKey.speechRateOption) ?? ""
        ) ?? .normal
        let followSystem = defaults.object(
            forKey: DefaultsKey.followSystemLanguageEnabled
        ) as? Bool ?? true
        let selected = SpeechLanguage(
            rawValue: defaults.string(forKey: DefaultsKey.selectedLanguage) ?? ""
        ) ?? .english
        let language = followSystem ? SpeechLanguage.fromSystemLanguage() : selected
        return announcementUtterance(message, rate: rate, language: language)
    }

    /// Interface status. With VoiceOver running it is handed to VoiceOver and queued behind
    /// what VoiceOver is reading, so it is never spoken twice or on top of the screen reader.
    func announce(_ message: String) {
        guard UIAccessibility.isVoiceOverRunning else { speak(message); return }
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
        UIAccessibility.post(notification: .announcement, argument: NSAttributedString(
            string: message, attributes: [.accessibilitySpeechQueueAnnouncement: true]))
    }

    func speakCameraState(_ state: CameraState) {
        switch state {
        case let .unavailable(reason):
            speak(localized(
                "speech.camera.unavailable",
                arguments: [localized(reason.localizationKey)]
            ))
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
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.voiceAnnouncementsEnabled)

        if enabled {
            announce(localized("speech.voice.enabled"))
        } else {
            stopCurrentSpeech()
        }
    }

    func setRateOption(_ option: SpeechRateOption) {
        rateOption = option
        UserDefaults.standard.set(option.rawValue, forKey: DefaultsKey.speechRateOption)

        announce(localized("speech.rate.changed", arguments: [localized(option.localizationKey)]))
    }

    func setFollowSystemLanguageEnabled(_ enabled: Bool) {
        followSystemLanguageEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.followSystemLanguageEnabled)
        speakLanguageSetting()
    }

    func setSelectedLanguage(_ language: SpeechLanguage) {
        selectedLanguage = language
        UserDefaults.standard.set(language.rawValue, forKey: DefaultsKey.selectedLanguage)

        guard !followSystemLanguageEnabled else { return }
        speakLanguageSetting()
    }

    func stopCurrentSpeech() {
        perceptionSpeechActive = false
        guard synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
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
        announce(languageSettingAnnouncement)
    }

    private func localized(_ key: String) -> String {
        AppLocalization.string(key, language: activeLanguage)
    }

    private func localized(_ key: String, arguments: [CVarArg]) -> String {
        AppLocalization.string(key, language: activeLanguage, arguments: arguments)
    }

    private func prepareAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()

        do {
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            // Speech synthesis can still work when another audio session owns the audio route.
        }
    }
}
