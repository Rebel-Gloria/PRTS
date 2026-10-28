import SwiftUI

struct PhotoDescriptionSettingsView: View {
    @AppStorage("photoDescription.uploadAllowed") private var uploadAllowed = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var message = ""
    @State private var requestingPermissions = false
    @State private var speechAuthorized = PhotoSpeechRecognizer.authorized
    @EnvironmentObject private var speech: SpeechManager

    var body: some View {
        Form {
            Section("photo.settings.service") {
                Text(PhotoChatProtocol.endpoint.host ?? "")
                LabeledContent("photo.settings.model", value: PhotoChatProtocol.model)
                Toggle("photo.settings.allowUpload", isOn: $uploadAllowed)
                Text("photo.settings.privacy")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField(hasKey ? "photo.settings.keySaved" : "photo.settings.keyPlaceholder", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("photo.settings.save") {
                    do {
                        try PhotoCredentialStore.save(key)
                        key = ""; hasKey = true; message = speech.interfaceString("photo.settings.saved")
                    } catch { message = error.localizedDescription }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("photo.settings.delete", role: .destructive) {
                        do {
                            try PhotoCredentialStore.delete()
                            hasKey = false; key = ""; message = speech.interfaceString("photo.settings.deleted")
                        } catch { message = error.localizedDescription }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption) }
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
        .onAppear {
            do { hasKey = try PhotoCredentialStore.read() != nil }
            catch { message = error.localizedDescription }
        }
        .onDisappear { key = "" }
    }
}
