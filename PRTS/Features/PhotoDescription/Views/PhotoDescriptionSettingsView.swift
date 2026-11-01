import SwiftUI

/// Intelligence settings: the provider and its key, the photo buttons and text reading.
/// Pick a provider, paste its key. Custom adds an address and a model; each provider keeps its own key.
/// On device needs no key and sends nothing.
struct PhotoDescriptionSettingsView: View {
    @AppStorage("photoDescription.uploadAllowed") private var uploadAllowed = false
    @AppStorage(PhotoChatProvider.selectionKey) private var provider = PhotoChatProvider.onDevice
    @AppStorage(PhotoChatProvider.customEndpointKey) private var customEndpoint = ""
    @AppStorage(PhotoChatProvider.customModelKey) private var customModel = ""
    @AppStorage(PhotoPrompts.questionThinkingKey) private var questionThinking = false
    @AppStorage(PhotoHardwareButtons.volumeKey) private var volumeButtons = true
    @AppStorage(TextReadingSession.threeFingerKey) private var threeFingerReading = true
    @AppStorage(TextReadingService.selectionKey) private var readingService = TextReadingService
        .onDevice
    @State private var key = ""
    @State private var hasKey = false
    @State private var message = ""
    @State private var requestingPermissions = false
    @State private var speechAuthorized = PhotoSpeechRecognizer.authorized
    @EnvironmentObject private var speech: SpeechManager

    var body: some View {
        Form {
            Section("photo.settings.provider") {
                Picker("photo.settings.provider", selection: $provider) {
                    Text("photo.settings.provider.onDevice").tag(PhotoChatProvider.onDevice)
                    Text(verbatim: "通义千问 Qwen").tag(PhotoChatProvider.qwen)
                    Text(verbatim: "DeepSeek").tag(PhotoChatProvider.deepseek)
                    Text("photo.settings.provider.custom").tag(PhotoChatProvider.custom)
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("photoProviderPicker")
            }
            if provider == .onDevice {
                Section {
                    LabeledContent("photo.settings.model", value: "MiniCPM-V 4.7 1B")
                } header: {
                    Text("photo.settings.service")
                } footer: {
                    Text("photo.settings.onDeviceFooter")
                }
            } else {
                Section {
                    if provider == .custom {
                        TextField(
                            "photo.settings.endpoint",
                            text: $customEndpoint,
                            prompt: Text(verbatim: "https://api.example.com/v1")
                        )
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("photoCustomEndpoint")
                        TextField(
                            "photo.settings.model",
                            text: $customModel,
                            prompt: Text("photo.settings.modelPlaceholder")
                        )
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("photoCustomModel")
                    } else if let service = provider.service() {
                        detailRow("photo.settings.endpoint", service.endpoint.host ?? "")
                        detailRow("photo.settings.model", service.model)
                    }
                    Toggle("photo.settings.allowUpload", isOn: $uploadAllowed)
                        .accessibilityHint("photo.settings.allowUpload.hint")
                } header: {
                    Text("photo.settings.service")
                } footer: {
                    if provider == .custom && provider.service() == nil
                        && !(customEndpoint.isEmpty && customModel.isEmpty)
                    {
                        Text("photo.settings.customInvalid").foregroundStyle(.orange)
                    } else {
                        Text(
                            provider == .custom
                                ? "photo.settings.customFooter" : "photo.settings.privacy"
                        )
                    }
                }
                Section("API Key") {
                    SecureField(
                        hasKey ? "photo.settings.keySaved" : "photo.settings.keyPlaceholder",
                        text: $key
                    )
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    // The placeholder disappears while typing; keep a fixed name for VoiceOver.
                    .accessibilityLabel(Text(verbatim: "API Key"))
                    .accessibilityHint(
                        hasKey ? "photo.settings.keySaved" : "photo.settings.keyPlaceholder"
                    )
                    Button("photo.settings.save") {
                        do {
                            try PhotoCredentialStore.save(key, account: provider.keyAccount)
                            key = ""
                            hasKey = true
                            report(speech.interfaceString("photo.settings.saved"))
                        } catch { report(error.localizedDescription) }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("photo.settings.delete", role: .destructive) {
                            do {
                                try PhotoCredentialStore.delete(account: provider.keyAccount)
                                hasKey = false
                                key = ""
                                report(speech.interfaceString("photo.settings.deleted"))
                            } catch { report(error.localizedDescription) }
                        }
                    }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
                if provider != .custom {
                    Section {
                        Toggle("photo.settings.questionThinking", isOn: $questionThinking)
                            .accessibilityHint("photo.settings.questionThinking.hint")
                            .accessibilityIdentifier("photoQuestionThinking")
                    } footer: {
                        Text("photo.settings.questionThinking.footer")
                    }
                }
            }
            Section {
                // Camera Control always takes photos; only phones without it get the volume option.
                if PhotoHardwareButtons.volumeAvailable {
                    Toggle("settings.photo.volumeButtons", isOn: $volumeButtons)
                        .accessibilityHint("settings.photo.volumeButtons.hint")
                        .accessibilityIdentifier("photoVolumeButtonsToggle")
                }
            } header: {
                Text("settings.photo.buttons.section")
            } footer: {
                if PhotoHardwareButtons.hasCameraControl {
                    Text("settings.photo.cameraControl.footer")
                } else if PhotoHardwareButtons.volumeAvailable {
                    Text("settings.photo.volumeButtons.footer")
                }
            }
            Section {
                Toggle("settings.ocr.threeFinger", isOn: $threeFingerReading)
                    .accessibilityHint("settings.ocr.threeFinger.hint")
                    .accessibilityIdentifier("threeFingerReadingToggle")
                Picker("settings.ocr.service", selection: $readingService) {
                    ForEach(TextReadingService.allCases) {
                        Text(LocalizedStringKey($0.localizationKey)).tag($0)
                    }
                }
                .accessibilityHint("settings.ocr.service.hint")
                .accessibilityIdentifier("ocrServicePicker")
            } header: {
                Text("settings.ocr.section")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.ocr.threeFinger.footer")
                    Text("settings.ocr.service.footer")
                }
            }
            Section("photo.settings.permissions") {
                // Once granted it is a status, not a dimmed button VoiceOver would offer to press.
                if speechAuthorized {
                    Label("photo.settings.permissionsGranted", systemImage: "checkmark")
                } else {
                    Button("photo.settings.permissionsRequest") {
                        requestingPermissions = true
                        Task {
                            speechAuthorized = await PhotoSpeechRecognizer.requestPermissions()
                            requestingPermissions = false
                            report(
                                speech.interfaceString(
                                    speechAuthorized
                                        ? "photo.settings.ready" : "photo.settings.denied"
                                )
                            )
                        }
                    }
                    .disabled(requestingPermissions)
                }
            }
            Section("photo.settings.usage") {
                Text("photo.settings.usageText")
            }
        }
        .navigationTitle("photo.settings.title")
        .onAppear(perform: loadKeyState)
        .onChange(of: provider) { _, _ in
            key = ""
            message = ""
            loadKeyState()
        }
        .onDisappear { key = "" }
    }

    /// Title above value: a host name has no spaces to wrap at, and side by side it was cut off
    /// at large text sizes.
    private func detailRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            // Body size in the system secondary colour, like a LabeledContent value: smaller
            // dimmed text failed the contrast audit.
            Text(verbatim: value).foregroundStyle(Color(uiColor: .secondaryLabel))
        }
        .accessibilityElement(children: .combine)
    }

    /// Shown under the key field and read by VoiceOver, which does not notice the text appear.
    private func report(_ text: String) {
        message = text
        SpeechManager.postQueuedAnnouncement(text)
    }

    private func loadKeyState() {
        do { hasKey = try PhotoCredentialStore.read(account: provider.keyAccount) != nil } catch {
            report(error.localizedDescription)
        }
    }
}
