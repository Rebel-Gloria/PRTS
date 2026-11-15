/// Product settings page; uses the system navigation back button.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ProbeViewModel
    #if PRTS_DEV
    @State private var confirmClearRecordings = false
    #endif
    @EnvironmentObject private var speech: SpeechManager
    @AppStorage(InteractionPreferences.noPreviewKey) private var noPreview = false
    @AppStorage(InteractionPreferences.tapToStopKey) private var tapToStop = false
    @State private var showUserGuide = false
    @AppStorage(InteractionPreferences.lowVisionKey) private var lowVisionMode = false
    @State private var confirmLowVision = false
    @AppStorage(PhotoChatProvider.selectionKey) private var provider = PhotoChatProvider.onDevice
    @AppStorage(InteractionPreferences.volumeKey) private var volumeButtons = true
    @AppStorage(InteractionPreferences.threeFingerKey) private var threeFingerReading = true

    var body: some View {
        Form {
            Section("photo.settings.title") {
                NavigationLink {
                    IntelligenceSettingsView()
                } label: {
                    LabeledContent("photo.settings.title") {
                        Text(LocalizedStringKey(provider.localizationKey))
                    }
                }
                .accessibilityIdentifier("intelligenceSettingsLink")
            }
            Section {
                // Turning it on stops obstacle guidance, so it asks first; turning it off does not.
                Toggle(
                    "settings.lowVision",
                    isOn: Binding(
                        get: { lowVisionMode },
                        set: { on in on ? (confirmLowVision = true) : (lowVisionMode = false) }
                    )
                )
                .accessibilityIdentifier("lowVisionToggle")
                .alert("settings.lowVision.confirm.title", isPresented: $confirmLowVision) {
                    Button("settings.lowVision.confirm.turnOn") { lowVisionMode = true }
                    Button("settings.lowVision.confirm.cancel", role: .cancel) {}
                } message: {
                    Text("settings.lowVision.confirm.message")
                }
            } header: {
                Text("settings.interaction.section")
            } footer: {
                Text("settings.lowVision.footer")
            }
            Section {
                Toggle("settings.tapToStop", isOn: $tapToStop)
                    .accessibilityIdentifier("tapToStopToggle")
            } footer: {
                Text("settings.tapToStop.footer")
            }
            if PhotoHardwareButtons.volumeAvailable || PhotoHardwareButtons.hasCameraControl {
                Section {
                    if PhotoHardwareButtons.volumeAvailable {
                        Toggle("settings.photo.volumeButtons", isOn: $volumeButtons)
                            .accessibilityHint("settings.photo.volumeButtons.hint")
                            .accessibilityIdentifier("photoVolumeButtonsToggle")
                    }
                } footer: {
                    if PhotoHardwareButtons.hasCameraControl {
                        Text("settings.photo.cameraControl.footer")
                    } else if PhotoHardwareButtons.volumeAvailable {
                        Text("settings.photo.volumeButtons.footer")
                    }
                }
            }
            Section {
                Toggle("settings.ocr.threeFinger", isOn: $threeFingerReading)
                    .accessibilityHint("settings.ocr.threeFinger.hint")
                    .accessibilityIdentifier("threeFingerReadingToggle")
            } footer: {
                Text("settings.ocr.threeFinger.footer")
            }
            Section {
                Toggle("settings.display.noPreview", isOn: $noPreview)
                    .accessibilityHint("settings.display.noPreview.hint")
                    .accessibilityIdentifier("noPreviewToggle")
                if model.supportsScanMesh {
                    Toggle("settings.display.scanMesh", isOn: $model.scanMesh)
                        .disabled(noPreview)
                        .accessibilityIdentifier("scanMeshToggle")
                }
            } footer: {
                if model.supportsScanMesh {
                    Text("settings.display.noPreview.footer") + Text(verbatim: "\n")
                        + Text("settings.display.scanMesh.footer")
                } else {
                    Text("settings.display.noPreview.footer")
                }
            }
            Section("settings.languageAndSpeech.section") {
                Toggle(
                    "settings.voice.announcements",
                    isOn: Binding(
                        get: { speech.voiceAnnouncementsEnabled },
                        set: speech.setVoiceAnnouncementsEnabled
                    )
                )
                .accessibilityHint("settings.voice.announcements.hint")
                Picker(
                    "settings.voice.rate",
                    selection: Binding(get: { speech.rateOption }, set: speech.setRateOption)
                ) {
                    ForEach(SpeechRateOption.allCases) {
                        Text(LocalizedStringKey($0.localizationKey)).tag($0)
                    }
                }
                .accessibilityHint("settings.voice.rate.hint")
            }
            Section {
                Toggle(
                    "settings.language.followSystem",
                    isOn: Binding(
                        get: { speech.followSystemLanguageEnabled },
                        set: speech.setFollowSystemLanguageEnabled
                    )
                )
                // Shown only when it can be used: a dimmed picker leaves VoiceOver users guessing why.
                if !speech.followSystemLanguageEnabled {
                    Picker(
                        "settings.language.picker",
                        selection: Binding(
                            get: { speech.selectedLanguage },
                            set: speech.setSelectedLanguage
                        )
                    ) {
                        // Each language is named in itself so it can be found in either interface
                        // language.
                        Text(verbatim: "中文").tag(SpeechLanguage.chinese)
                        Text(verbatim: "English").tag(SpeechLanguage.english)
                    }
                }
            } footer: {
                Text("settings.language.footer")
            }
            Section {
                Button("settings.userGuide") { showUserGuide = true }
                    .accessibilityIdentifier("userGuideButton")
                    // Attached here, not to the Form, so it never competes with the developer sheet.
                    .sheet(isPresented: $showUserGuide) {
                        UserGuideView().environmentObject(speech)
                    }
            }
            #if PRTS_DEV
            Section("recording.settings.title") {
                Text(verbatim: model.recordingStatus)
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("recordingStatus")
                if let error = model.errorMessage {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("recordingOperationError")
                }
                Button("recording.settings.export") { model.exportRecordings() }
                    .disabled(model.exporting || model.clearingRecordings)
                    .accessibilityIdentifier("exportRecordingsButton")
                Button("recording.settings.clear", role: .destructive) {
                    confirmClearRecordings = true
                }
                .foregroundStyle(.red)
                .disabled(model.exporting || model.clearingRecordings)
                .accessibilityIdentifier("clearRecordingsButton")
                .alert("recording.clear.title", isPresented: $confirmClearRecordings) {
                    Button("recording.clear.confirm", role: .destructive) {
                        model.clearRecordings()
                    }
                    Button("recording.clear.cancel", role: .cancel) {}
                } message: {
                    Text("recording.clear.message")
                }
            }
            #endif
        }
        #if PRTS_DEV
        .sheet(
            isPresented: Binding(
                get: { model.exportURL != nil },
                set: { shown in
                    if !shown { model.exportURL = nil }
                }
            )
        ) {
            if let url = model.exportURL {
                RecordingShareSheet(url: url, onFinish: { model.exportURL = nil })
            }
        }
        #endif
        .navigationTitle("settings.title")
        .onAppear { speech.speakSettingsScreen() }
    }
}
