/// Product settings page; uses the system navigation back button.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: ProbeViewModel
    #if PRTS_DEV_CAPTURE
    @AppStorage("developer.showTechnicalOverlay") private var showTechnicalOverlay = true
    @AppStorage("developer.showCommandEntry") private var showCommandEntry = true
    @State private var showSpatialSettings = false
    #endif
    @EnvironmentObject private var speech: SpeechManager
    @EnvironmentObject private var haptics: HapticManager

    var body: some View {
        Form {
            #if PRTS_DEV_CAPTURE
            Section("开发者选项") {
                Toggle("主页面参数指标与图例",isOn:$showTechnicalOverlay).accessibilityIdentifier("devTechnicalOverlayToggle")
                Toggle("主页面测试指令栏",isOn:$showCommandEntry).accessibilityIdentifier("devCommandEntryToggle")
                Text("仅控制调试界面显示，不停止空间计算、方向反馈或日志记录；录像提示不受这些开关影响。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("图层、路径、触觉与 DIAG 日志") { showSpatialSettings = true }.accessibilityIdentifier("spatialSettingsButton")
                NavigationLink("演示模式选项") { DemoOptionsView(model:model) }.accessibilityIdentifier("demoOptionsLink")
                Toggle("保存摄像机视频与分析数据",isOn:Binding(get:{ model.devCaptureStatus.enabled },set:{ enabled in
                    if enabled { model.engine.devCapture.enable() } else { model.engine.devCapture.stop() }
                    model.devCaptureStatus = model.engine.devCapture.status()
                })).accessibilityIdentifier("devCaptureToggle").disabled(model.exporting || (model.devCaptureStatus.busy && !model.devCaptureStatus.enabled))
                Text("仅在知情同意的受控场地开启。将保存未叠加标注的压缩RGB视频（上限5 FPS、最长边960）及ARKit深度/置信度、DA原始相对输出与尺度校准、完整分析结果；无音频、不上传。隐藏主页面摄像机画面不会停止记录。停止、后台或导出会关闭此模式；下次需手动开启。")
                    .font(.caption).foregroundStyle(.orange)
                Text(model.devCaptureStatus.text).font(.caption)
                Button("停止采集并打开 DIAG 导出页") { model.engine.devCapture.stop(); showSpatialSettings = true }
            }
            #endif
            Section("拍照描述") {
                NavigationLink("服务与 API Key") { PhotoDescriptionSettingsView() }
            }
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

        }
        #if PRTS_DEV_CAPTURE
        .sheet(isPresented:$showSpatialSettings) { ProbeSettingsView(model:model) }
        #endif
        .navigationTitle("设置")
        .onAppear { speech.speakSettingsScreen(hapticFeedbackEnabled:haptics.isEnabled) }
        .onChange(of:haptics.isEnabled) { _,enabled in speech.speakHapticFeedbackState(enabled) }
    }
}
