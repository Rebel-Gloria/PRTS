import SwiftUI

struct IntelligenceSettingsView: View {
    @AppStorage("photoDescription.uploadAllowed") private var uploadAllowed = false
    @AppStorage(PhotoChatProvider.selectionKey) private var provider = PhotoChatProvider.onDevice
    @AppStorage(IntelligenceFeature.description.selectionKey) private var descriptionProvider = ""
    @AppStorage(IntelligenceFeature.question.selectionKey) private var questionProvider = ""
    @AppStorage(TextReadingService.selectionKey) private var readingService = TextReadingService.vlm
    @AppStorage(LiveCaptionModel.selectionKey) private var captionProvider = PhotoChatProvider.qwen
    @AppStorage(PhotoImagePurpose.highResolutionKey) private var highResolution = false
    @State private var configuredProviders: Set<PhotoChatProvider> = []
    @State private var message = ""
    @State private var requestingPermissions = false
    @State private var speechAuthorized = PhotoSpeechRecognizer.authorized
    @EnvironmentObject private var speech: SpeechManager

    var body: some View {
        Form {
            Section("intelligence.defaultProvider") {
                Picker("intelligence.defaultProvider", selection: $provider) {
                    ForEach(PhotoChatProvider.allCases) { provider in
                        Text(LocalizedStringKey(provider.localizationKey)).tag(provider)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityIdentifier("photoProviderPicker")
            }
            Section("intelligence.providerSettings") {
                ForEach(PhotoChatProvider.allCases) { provider in
                    NavigationLink {
                        ProviderSettingsView(provider: provider)
                    } label: {
                        LabeledContent {
                            if provider != .onDevice {
                                Text(
                                    configuredProviders.contains(provider)
                                        ? "intelligence.configured" : "intelligence.notConfigured"
                                )
                            }
                        } label: {
                            Text(LocalizedStringKey(provider.localizationKey))
                        }
                    }
                    .accessibilityIdentifier("providerSettings.\(provider.rawValue)")
                }
                if !message.isEmpty { Text(message) }
            }
            Section {
                providerPicker(
                    "intelligence.description",
                    selection: $descriptionProvider,
                    feature: .description
                )
                providerPicker(
                    "intelligence.question",
                    selection: $questionProvider,
                    feature: .question
                )
                Picker("settings.ocr.section", selection: $readingService) {
                    ForEach(TextReadingService.allCases) {
                        Text(LocalizedStringKey($0.localizationKey)).tag($0)
                    }
                }
                .accessibilityHint("settings.ocr.service.hint")
                .accessibilityIdentifier("ocrServicePicker")
                Picker("intelligence.liveCaptions", selection: $captionProvider) {
                    ForEach(LiveCaptionModel.choices) { provider in
                        Text(LocalizedStringKey(provider.localizationKey)).tag(provider)
                    }
                }
                .accessibilityIdentifier("liveCaptionProvider")
            } header: {
                Text("intelligence.servicesByFeature")
            } footer: {
                Text("settings.ocr.service.footer")
            }
            Section {
                Toggle("photo.settings.allowUpload", isOn: $uploadAllowed)
                    .accessibilityHint("photo.settings.allowUpload.hint")
                    .accessibilityIdentifier("photoUploadAllowed")
            } header: {
                Text("intelligence.allServices")
            } footer: {
                Text("photo.settings.privacy")
            }
            Section {
                Toggle("photo.settings.highResolution", isOn: $highResolution)
                    .accessibilityHint("photo.settings.highResolution.footer")
                    .accessibilityIdentifier("highResolutionToggle")
            } footer: {
                Text("photo.settings.highResolution.footer")
            }
            Section {
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
                    .accessibilityIdentifier("photoSpeechPermissions")
                }
            }
        }
        .navigationTitle("photo.settings.title")
        .onAppear { loadProviderStates() }
    }

    private func providerPicker(
        _ title: LocalizedStringKey,
        selection: Binding<String>,
        feature: IntelligenceFeature
    ) -> some View {
        Picker(
            title,
            selection: Binding(
                get: { selection.wrappedValue },
                set: { value in
                    selection.wrappedValue = value
                    if value.isEmpty {
                        UserDefaults.standard.removeObject(forKey: feature.selectionKey)
                    }
                }
            )
        ) {
            Text("intelligence.provider.default").tag("")
            ForEach(PhotoChatProvider.allCases) { provider in
                Text(LocalizedStringKey(provider.localizationKey)).tag(provider.rawValue)
            }
        }
        .accessibilityIdentifier(feature.selectionKey)
    }

    private func loadProviderStates() {
        configuredProviders = []
        message = ""
        do {
            for provider in PhotoChatProvider.allCases where provider != .onDevice {
                let hasKey = try PhotoCredentialStore.read(account: provider.keyAccount) != nil
                if hasKey && provider.service() != nil { configuredProviders.insert(provider) }
            }
        } catch { report(error.localizedDescription) }
    }

    private func report(_ text: String) {
        message = text
        SpeechManager.postQueuedAnnouncement(text)
    }
}
