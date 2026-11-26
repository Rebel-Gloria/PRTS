import SwiftUI

struct ProviderSettingsView: View {
    let provider: PhotoChatProvider
    @AppStorage(PhotoChatProvider.customEndpointKey) private var customEndpoint = ""
    @AppStorage(PhotoChatProvider.customModelKey) private var customModel = ""
    @AppStorage private var questionThinking: Bool
    @AppStorage(PhotoChatProvider.localEnhancedKey) private var localEnhanced = false
    @AppStorage(PhotoChatProvider.qwenOmniKey) private var qwenOmni = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var message = ""
    @EnvironmentObject private var speech: SpeechManager

    init(provider: PhotoChatProvider) {
        self.provider = provider
        _questionThinking = AppStorage(wrappedValue: false, provider.questionThinkingKey)
    }

    private var keyAccount: String? {
        if provider == .custom {
            return PhotoChatService.chatURL(from: customEndpoint).flatMap(
                PhotoChatService.customKeyAccount
            )
        }
        return provider.service()?.keyAccount
    }

    var body: some View {
        let keyAccount = self.keyAccount
        Form {
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
                            "photo.settings.modelPlaceholder",
                            text: $customModel,
                            prompt: Text("photo.settings.modelPlaceholder")
                        )
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("photoCustomModel")
                    } else if let service = provider.service() {
                        detailRow("photo.settings.endpoint", service.endpoint.host ?? "")
                        detailRow("photo.settings.model", service.model)
                    }
                } header: {
                    Text("photo.settings.service")
                } footer: {
                    if provider == .custom && provider.service() == nil
                        && !(customEndpoint.isEmpty && customModel.isEmpty)
                    {
                        Text("photo.settings.customInvalid").foregroundStyle(.orange)
                    } else if provider == .custom {
                        Text("photo.settings.customFooter")
                    }
                }
                Section {
                    SecureField("photo.settings.keyPlaceholder", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        // The placeholder disappears while typing; keep a fixed name for VoiceOver.
                        .accessibilityLabel(Text(verbatim: "API Key"))
                        .accessibilityHint("photo.settings.keyPlaceholder")
                        .accessibilityIdentifier("photoAPIKey")
                    Button("photo.settings.save") {
                        guard let keyAccount else { return }
                        do {
                            try PhotoCredentialStore.save(key, account: keyAccount)
                            key = ""
                            hasKey = true
                            report(speech.interfaceString("photo.settings.saved"))
                        } catch { report(error.localizedDescription) }
                    }
                    .disabled(
                        keyAccount == nil
                            || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("photoSaveKey")
                    if hasKey, let keyAccount {
                        Button("photo.settings.delete", role: .destructive) {
                            do {
                                try PhotoCredentialStore.delete(account: keyAccount)
                                hasKey = false
                                key = ""
                                report(speech.interfaceString("photo.settings.deleted"))
                            } catch { report(error.localizedDescription) }
                        }
                        .accessibilityIdentifier("photoDeleteKey")
                    }
                    if !message.isEmpty { Text(message).font(.caption) }
                } header: {
                    Text(verbatim: "API Key")
                } footer: {
                    // In the footer, not the field's placeholder: the field is one line wide. Body size,
                    // as smaller dimmed text failed the contrast audit.
                    if hasKey { Text("photo.settings.saved").font(.body) }
                }
            }
            if provider == .qwen {
                Section {
                    Toggle("photo.settings.qwenOmni", isOn: $qwenOmni)
                        .accessibilityHint("photo.settings.qwenOmni.footer")
                        .accessibilityIdentifier("photoQwenOmni")
                } footer: {
                    Text("photo.settings.qwenOmni.footer")
                }
            }
            if provider == .onDevice {
                Section {
                    Toggle("photo.settings.localEnhanced", isOn: $localEnhanced)
                        .accessibilityHint("photo.settings.localEnhanced.hint")
                        .accessibilityIdentifier("photoLocalEnhanced")
                } footer: {
                    Text("photo.settings.localEnhanced.footer")
                }
            } else if provider != .custom {
                Section {
                    Toggle("photo.settings.questionThinking", isOn: $questionThinking)
                        .accessibilityHint("photo.settings.questionThinking.hint")
                        .accessibilityIdentifier("photoQuestionThinking")
                } footer: {
                    Text("photo.settings.questionThinking.footer")
                }
            }
        }
        .navigationTitle(LocalizedStringKey(provider.localizationKey))
        .onChange(of: keyAccount, initial: true) {
            key = ""
            message = ""
            loadKeyState(for: keyAccount)
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

    private func loadKeyState(for keyAccount: String?) {
        hasKey = false
        guard let keyAccount else { return }
        do { hasKey = try PhotoCredentialStore.read(account: keyAccount) != nil } catch {
            report(error.localizedDescription)
        }
    }
}
