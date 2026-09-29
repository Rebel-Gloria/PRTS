import SwiftUI

struct PhotoDescriptionSettingsView: View {
    @AppStorage("photoDescription.uploadAllowed") private var uploadAllowed = false
    @State private var key = ""
    @State private var hasKey = false
    @State private var message = ""

    var body: some View {
        Form {
            Section("服务") {
                Text(PhotoChatProtocol.endpoint.host ?? "")
                LabeledContent("模型", value: PhotoChatProtocol.model)
                Toggle("允许发送拍摄图片和提问", isOn: $uploadAllowed)
                Text("仅在按下拍照按钮后发送到上述服务。语音识别根据设备支持情况可能使用 Apple 服务。本功能不保存照片、录音、提问和回答；开发采集模式的独立录像设置不受影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("API Key") {
                SecureField(hasKey ? "已保存，输入可替换" : "输入 API Key", text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("保存到本机钥匙串") {
                    do {
                        try PhotoCredentialStore.save(key)
                        key = ""; hasKey = true; message = "已保存"
                    } catch { message = error.localizedDescription }
                }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("删除 API Key", role: .destructive) {
                        do {
                            try PhotoCredentialStore.delete()
                            hasKey = false; key = ""; message = "已删除"
                        } catch { message = error.localizedDescription }
                    }
                }
                if !message.isEmpty { Text(message).font(.caption) }
            }
            Section("操作") {
                Text("短按：拍照并描述。长按半秒，听到提示音后提问，松手发送。")
            }
        }
        .navigationTitle("拍照描述")
        .onAppear {
            do { hasKey = try PhotoCredentialStore.read() != nil }
            catch { message = error.localizedDescription }
        }
        .onDisappear { key = "" }
    }
}
