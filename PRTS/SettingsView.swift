import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ProbeViewModel
    @State private var showSpatialSettings = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var speech: SpeechManager
    @EnvironmentObject private var haptics: HapticManager

    var body: some View {
        Form {
            Section("语音") {
                Toggle("语音提示", isOn: Binding(get: { speech.voiceAnnouncementsEnabled }, set: speech.setVoiceAnnouncementsEnabled))
                Picker("语速", selection: Binding(get: { speech.rateOption }, set: speech.setRateOption)) {
                    ForEach(SpeechRateOption.allCases) { Text(LocalizedStringKey($0.localizationKey)).tag($0) }
                }
            }
            Section("语言") {
                Toggle("跟随系统语言", isOn: Binding(get: { speech.followSystemLanguageEnabled }, set: speech.setFollowSystemLanguageEnabled))
                Picker("提示语言", selection: Binding(get: { speech.selectedLanguage }, set: speech.setSelectedLanguage)) {
                    Text("中文").tag(SpeechLanguage.chinese)
                    Text("English").tag(SpeechLanguage.english)
                }
                .disabled(speech.followSystemLanguageEnabled)
            }
            Section("触觉") {
                Toggle("触觉提示", isOn: Binding(get: { haptics.isEnabled }, set: haptics.setEnabled))
            }
            Section("空间感知与演示") {
                Button("图层、路径、触觉与 DIAG 日志") { showSpatialSettings = true }.accessibilityIdentifier("spatialSettingsButton")
                NavigationLink("演示模式选项") { DemoOptionsView(model:model) }.accessibilityIdentifier("demoOptionsLink")
                Text("LiDAR 设备使用 ARKit 实测深度；无 LiDAR 使用原生平面与本地 Core ML 预测，预测不等于实测。候选通道不等于安全路线。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented:$showSpatialSettings) { ProbeSettingsView(model:model) }
        .navigationTitle("设置")
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("返回") { dismiss() } } }
    }
}
