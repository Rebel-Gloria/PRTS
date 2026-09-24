//
//  SettingsView.swift
//  PRTS
//

import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var speechManager: SpeechManager
    @EnvironmentObject private var hapticManager: HapticManager
    @Environment(\.dismiss) private var dismiss
    @AppStorage("prts.runtimeProfile") private var runtimeProfile = PRTSRuntimeProfile.minimal.rawValue
    @AppStorage("prts.enableBrain") private var brainEnabled = false
    @AppStorage("prts.enablePerception") private var perceptionEnabled = false
    @AppStorage("prts.enableASR") private var asrEnabled = false
    @AppStorage("prts.enableMaps") private var mapsEnabled = false

    var body: some View {
        Form {
            Section {
                Toggle(
                    "settings.voice.announcements",
                    isOn: Binding(
                        get: { speechManager.voiceAnnouncementsEnabled },
                        set: {
                            hapticManager.buttonTapped()
                            speechManager.setVoiceAnnouncementsEnabled($0)
                        }
                    )
                )
                    .accessibilityValue(LocalizedStringKey(
                        speechManager.voiceAnnouncementsEnabled
                            ? "settings.voice.announcements.on"
                            : "settings.voice.announcements.off"
                    ))
                    .accessibilityHint("settings.voice.announcements.hint")
                    .accessibilityIdentifier("voiceToggle")

                Picker(
                    "settings.voice.rate",
                    selection: Binding(
                        get: { speechManager.rateOption },
                        set: {
                            hapticManager.buttonTapped()
                            speechManager.setRateOption($0)
                        }
                    )
                ) {
                    ForEach(SpeechRateOption.allCases) { option in
                        Text(LocalizedStringKey(option.localizationKey)).tag(option)
                    }
                }
                .accessibilityLabel("settings.voice.rate")
                .accessibilityValue(LocalizedStringKey(speechManager.rateOption.localizationKey))
                .accessibilityHint("settings.voice.rate.hint")
                .accessibilityIdentifier("speechRatePicker")
            } header: {
                Label("settings.voice.section", systemImage: "speaker.wave.2.fill")
                    .accessibilityAddTraits(.isHeader)
            }

            Section {
                Toggle(
                    "settings.language.followSystem",
                    isOn: Binding(
                        get: { speechManager.followSystemLanguageEnabled },
                        set: {
                            hapticManager.buttonTapped()
                            speechManager.setFollowSystemLanguageEnabled($0)
                        }
                    )
                )
                    .accessibilityValue(LocalizedStringKey(
                        speechManager.followSystemLanguageEnabled
                            ? "settings.voice.announcements.on"
                            : "settings.voice.announcements.off"
                    ))
                    .accessibilityHint("settings.language.followSystem.hint")
                    .accessibilityIdentifier("followSystemLanguageToggle")

                Picker(
                    "settings.language.picker",
                    selection: Binding(
                        get: { speechManager.selectedLanguage },
                        set: {
                            hapticManager.buttonTapped()
                            speechManager.setSelectedLanguage($0)
                        }
                    )
                ) {
                    ForEach(SpeechLanguage.allCases) { language in
                        Text(LocalizedStringKey(language.displayNameLocalizationKey)).tag(language)
                    }
                }
                .disabled(speechManager.followSystemLanguageEnabled)
                .accessibilityLabel("settings.language.picker")
                .accessibilityValue(LocalizedStringKey(
                    speechManager.selectedLanguage.displayNameLocalizationKey
                ))
                .accessibilityHint(LocalizedStringKey(
                    speechManager.followSystemLanguageEnabled
                        ? "settings.language.picker.disabledHint"
                        : "settings.language.picker.chooseHint"
                ))
                .accessibilityIdentifier("languagePicker")
            } header: {
                Label("settings.language.section", systemImage: "globe")
                    .accessibilityAddTraits(.isHeader)
            } footer: {
                Text("settings.language.footer")
            }

            Section {
                Picker("Runtime profile", selection: $runtimeProfile) {
                    ForEach(PRTSRuntimeProfile.allCases) { profile in
                        Text(profile.label).tag(profile.rawValue)
                    }
                }
                Toggle("Enable brain / VLM (experimental)", isOn: $brainEnabled)
                    .onChange(of: brainEnabled) { enabled in
                        if enabled { runtimeProfile = PRTSRuntimeProfile.fullExperimental.rawValue }
                    }
                Toggle("Enable perception (segmentation + detection)", isOn: $perceptionEnabled)
                Toggle("Enable ASR (on-demand)", isOn: $asrEnabled)
                Toggle("Enable maps", isOn: $mapsEnabled)
                Text("Model features remain unavailable until the pinned Apple runtime and model files are supplied. Full / experimental is never selected automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Runtime and models", systemImage: "cpu")
                    .accessibilityAddTraits(.isHeader)
            }
            .onChange(of: runtimeProfile) { rawValue in
                let profile = PRTSRuntimeProfile(rawValue: rawValue) ?? .minimal
                switch profile {
                case .minimal:
                    brainEnabled = false
                    perceptionEnabled = false
                case .perception:
                    brainEnabled = false
                    perceptionEnabled = true
                case .fullExperimental:
                    brainEnabled = true
                    perceptionEnabled = true
                }
            }

            Section {
                Toggle(
                    "settings.feedback.haptic",
                    isOn: Binding(
                        get: { hapticManager.isEnabled },
                        set: {
                            hapticManager.setEnabled($0)
                            speechManager.speakHapticFeedbackState($0)
                        }
                    )
                )
                    .accessibilityValue(LocalizedStringKey(
                        hapticManager.isEnabled
                            ? "settings.voice.announcements.on"
                            : "settings.voice.announcements.off"
                    ))
                    .accessibilityHint("settings.feedback.haptic.hint")
                    .accessibilityIdentifier("hapticToggle")
            } header: {
                Label("settings.feedback.section", systemImage: "hand.tap.fill")
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .navigationTitle("settings.title")
        .navigationBarTitleDisplayMode(.large)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    hapticManager.buttonTapped()
                    dismiss()
                } label: {
                    Label("settings.back", systemImage: "chevron.backward")
                }
                .accessibilityLabel("settings.back")
                .accessibilityIdentifier("settingsBackButton")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.025, green: 0.045, blue: 0.075))
        .onAppear {
            UIAccessibility.post(
                notification: .screenChanged,
                argument: speechManager.localizedInterfaceString("settings.title")
            )
            speechManager.speakSettingsScreen(
                hapticFeedbackEnabled: hapticManager.isEnabled
            )
        }
    }
}
