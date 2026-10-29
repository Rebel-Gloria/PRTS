import SwiftUI

/// Pick a provider, paste its key. Custom adds an address and a model; each provider keeps its own key.
/// On device needs no key and sends nothing.
struct PhotoDescriptionSettingsView: View {
    @AppStorage("photoDescription.uploadAllowed") private var uploadAllowed = false
    @AppStorage(PhotoChatProvider.selectionKey) private var provider = PhotoChatProvider.qwen
    @AppStorage(PhotoChatProvider.customEndpointKey) private var customEndpoint = ""
    @AppStorage(PhotoChatProvider.customModelKey) private var customModel = ""
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
                        TextField("photo.settings.endpoint", text: $customEndpoint, prompt: Text(verbatim: "https://api.example.com/v1"))
                            .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("photoCustomEndpoint")
                        TextField("photo.settings.model", text: $customModel, prompt: Text("photo.settings.modelPlaceholder"))
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("photoCustomModel")
                    } else if let service = provider.service() {
                        LabeledContent("photo.settings.endpoint", value: service.endpoint.host ?? "")
                        LabeledContent("photo.settings.model", value: service.model)
                    }
                    Toggle("photo.settings.allowUpload", isOn: $uploadAllowed)
                } header: {
                    Text("photo.settings.service")
                } footer: {
                    if provider == .custom && provider.service() == nil && !(customEndpoint.isEmpty && customModel.isEmpty) {
                        Text("photo.settings.customInvalid").foregroundStyle(.orange)
                    } else {
                        Text(provider == .custom ? "photo.settings.customFooter" : "photo.settings.privacy")
                    }
                }
                Section("API Key") {
                    SecureField(hasKey ? "photo.settings.keySaved" : "photo.settings.keyPlaceholder", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("photo.settings.save") {
                        do {
                            try PhotoCredentialStore.save(key, account: provider.keyAccount)
                            key = ""; hasKey = true; message = speech.interfaceString("photo.settings.saved")
                        } catch { message = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if hasKey {
                        Button("photo.settings.delete", role: .destructive) {
                            do {
                                try PhotoCredentialStore.delete(account: provider.keyAccount)
                                hasKey = false; key = ""; message = speech.interfaceString("photo.settings.deleted")
                            } catch { message = error.localizedDescription }
                        }
                    }
                    if !message.isEmpty { Text(message).font(.caption) }
                }
            }
            Section("photo.settings.permissions") {
                Button(speechAuthorized ? "photo.settings.permissionsGranted" : "photo.settings.permissionsRequest") {
                    requestingPermissions = true
                    Task {
                        speechAuthorized = await PhotoSpeechRecognizer.requestPermissions()
                        requestingPermissions = false
                        message = speech.interfaceString(speechAuthorized ? "photo.settings.ready" : "photo.settings.denied")
                    }
                }.disabled(requestingPermissions || speechAuthorized)
            }
            Section("photo.settings.usage") {
                Text("photo.settings.usageText")
            }
        }
        .navigationTitle("photo.settings.title")
        .onAppear(perform: loadKeyState)
        .onChange(of: provider) { _, _ in key = ""; message = ""; loadKeyState() }
        .onDisappear { key = "" }
    }

    private func loadKeyState() {
        do { hasKey = try PhotoCredentialStore.read(account: provider.keyAccount) != nil }
        catch { message = error.localizedDescription }
    }
}
