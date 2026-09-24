//
//  SpeechManager.swift
//  PRTS
//

import AVFoundation
@preconcurrency import PRTSContracts
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
final class SpeechManager: NSObject, ObservableObject {
    @Published private(set) var voiceAnnouncementsEnabled: Bool
    @Published private(set) var rateOption: SpeechRateOption
    @Published private(set) var followSystemLanguageEnabled: Bool
    @Published private(set) var selectedLanguage: SpeechLanguage

    private let synthesizer = AVSpeechSynthesizer()
    private var backendQueue: [SpeechRequest] = []
    private var activeBackendRequest: SpeechRequest?
    private var activeBackendUtteranceID: ObjectIdentifier?
    private var backendExpiryTimer: Timer?
    var backendPlaybackChanged: ((Bool) -> Void)?

    private enum DefaultsKey {
        static let voiceAnnouncementsEnabled = "voiceAnnouncementsEnabled"
        static let speechRateOption = "speechRateOption"
        static let followSystemLanguageEnabled = "followSystemLanguageEnabled"
        static let selectedLanguage = "selectedLanguage"
    }

    override init() {
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

        super.init()
        synthesizer.delegate = self
    }

    /// The locale used by SwiftUI for the entire app. For unsupported system
    /// languages, English is the supported fallback.
    var interfaceLocale: Locale {
        Locale(identifier: activeLanguage.resourceIdentifier)
    }

    func speakHomeScreen(cameraState: CameraState = .idle) {
        let cameraStatusKey = cameraState == .running
            ? "speech.camera.liveStatus"
            : "speech.camera.readyStatus"
        let cameraActionKey = cameraState == .running
            ? "speech.camera.stopAction"
            : "speech.camera.startAction"

        speak(localized(
            "speech.home",
            arguments: [localized(cameraStatusKey), localized(cameraActionKey)]
        ))
    }

    func speakSettingsScreen(hapticFeedbackEnabled: Bool) {
        speak(localized(
            "speech.settings.summary",
            arguments: [
                localized(voiceAnnouncementsEnabled ? "speech.value.on" : "speech.value.off"),
                localized(rateOption.localizationKey),
                languageSettingAnnouncement,
                localized(hapticFeedbackEnabled ? "speech.value.on" : "speech.value.off")
            ]
        ))
    }

    func speakHapticFeedbackState(_ enabled: Bool) {
        speak(localized(
            "speech.haptic.changed",
            arguments: [localized(enabled ? "speech.value.on" : "speech.value.off")]
        ))
    }

    func speak(_ message: String) {
        guard voiceAnnouncementsEnabled else { return }

        prepareAudioSession()
        stopCurrentSpeech()

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = rateOption.avSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: activeLanguage.localeIdentifier)
        synthesizer.speak(utterance)
    }

    /// Enqueue a real backend speech_request. Playback feedback is emitted only from
    /// AVSpeechSynthesizerDelegate callbacks, never when a request is merely received.
    func enqueueBackendSpeech(_ request: SpeechRequest) {
        let now = ProcessInfo.processInfo.systemUptime
        guard request.expires_s > now, !request.text.isEmpty else { return }
        backendQueue.removeAll { $0.expires_s <= now || $0.replace_group == request.replace_group }
        if backendQueue.count >= 16 {
            if let lowest = backendQueue.indices.min(by: { backendQueue[$0].priority < backendQueue[$1].priority }),
               backendQueue[lowest].priority < request.priority {
                backendQueue.remove(at: lowest)
            } else if backendQueue.count >= 16 {
                return
            }
        }
        backendQueue.append(request)
        if let activeBackendRequest,
           request.replace_group == activeBackendRequest.replace_group || request.priority > activeBackendRequest.priority {
            synthesizer.stopSpeaking(at: .immediate)
        } else if activeBackendRequest == nil {
            speakNextBackendRequest()
        }
    }

    func cancelBackendSpeech() {
        backendQueue.removeAll()
        backendExpiryTimer?.invalidate()
        backendExpiryTimer = nil
        guard activeBackendRequest != nil else { return }
        synthesizer.stopSpeaking(at: .immediate)
    }

    private func speakNextBackendRequest() {
        let now = ProcessInfo.processInfo.systemUptime
        backendQueue.removeAll { $0.expires_s <= now }
        guard let index = backendQueue.indices.max(by: {
            backendQueue[$0].priority == backendQueue[$1].priority
                ? backendQueue[$0].sequence > backendQueue[$1].sequence
                : backendQueue[$0].priority < backendQueue[$1].priority
        }) else {
            backendPlaybackChanged?(false)
            return
        }
        let request = backendQueue.remove(at: index)
        guard voiceAnnouncementsEnabled else { speakNextBackendRequest(); return }
        prepareAudioSession()
        let utterance = AVSpeechUtterance(string: request.text)
        utterance.rate = rateOption.avSpeechRate
        utterance.voice = AVSpeechSynthesisVoice(language: activeLanguage.localeIdentifier)
        activeBackendRequest = request
        activeBackendUtteranceID = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
        backendExpiryTimer?.invalidate()
        let requestSequence = request.sequence
        backendExpiryTimer = Timer.scheduledTimer(withTimeInterval: max(0.01, request.expires_s - now), repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.activeBackendRequest?.sequence == requestSequence else { return }
                self.synthesizer.stopSpeaking(at: .immediate)
            }
        }
    }

    private func finishBackendUtterance(_ utteranceID: ObjectIdentifier) {
        guard activeBackendUtteranceID == utteranceID else { return }
        activeBackendRequest = nil
        activeBackendUtteranceID = nil
        backendExpiryTimer?.invalidate()
        backendExpiryTimer = nil
        backendPlaybackChanged?(false)
        speakNextBackendRequest()
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

    func localizedInterfaceString(_ key: String) -> String {
        localized(key)
    }

    func setVoiceAnnouncementsEnabled(_ enabled: Bool) {
        voiceAnnouncementsEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: DefaultsKey.voiceAnnouncementsEnabled)

        if enabled {
            speak(localized("speech.voice.enabled"))
        } else {
            stopCurrentSpeech()
        }
    }

    func setRateOption(_ option: SpeechRateOption) {
        rateOption = option
        UserDefaults.standard.set(option.rawValue, forKey: DefaultsKey.speechRateOption)

        speak(localized("speech.rate.changed", arguments: [localized(option.localizationKey)]))
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
        backendQueue.removeAll()
        backendExpiryTimer?.invalidate()
        backendExpiryTimer = nil
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
        speak(languageSettingAnnouncement)
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

extension SpeechManager: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeBackendUtteranceID == utteranceID else { return }
            self.backendPlaybackChanged?(true)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishBackendUtterance(utteranceID) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let utteranceID = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in self?.finishBackendUtterance(utteranceID) }
    }
}
