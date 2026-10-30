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
    @AppStorage(PhotoHardwareButtons.volumeKey) private var volumeButtons = true
    @AppStorage(TextReadingSession.threeFingerKey) private var threeFingerReading = true
    @AppStorage(TextReadingService.selectionKey) private var readingService = TextReadingService.onDevice
    @AppStorage(ContentView.noPreviewKey) private var noPreview = false

    var body: some View {
        Form {
            #if PRTS_DEV_CAPTURE
            Section("开发者选项") {
                Toggle("主页面参数指标与图例",isOn:$showTechnicalOverlay).accessibilityIdentifier("devTechnicalOverlayToggle")
                Toggle("主页面测试指令栏",isOn:$showCommandEntry).accessibilityIdentifier("devCommandEntryToggle")
                Text("只控制调试信息是否显示。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("图层、路径、触觉与 DIAG 日志") { showSpatialSettings = true }.accessibilityIdentifier("spatialSettingsButton")
                NavigationLink("演示模式选项") { DemoOptionsView(model:model) }.accessibilityIdentifier("demoOptionsLink")
                Toggle("保存相机视频与分析数据",isOn:Binding(get:{ model.devCaptureStatus.enabled },set:{ enabled in
                    if enabled { model.engine.devCapture.enable() } else { model.engine.devCapture.stop() }
                    model.devCaptureStatus = model.engine.devCapture.status()
                })).accessibilityIdentifier("devCaptureToggle").disabled(model.exporting || (model.devCaptureStatus.busy && !model.devCaptureStatus.enabled))
                VStack(alignment: .leading, spacing: 4) {
                    Text("只在已取得同意的测试场地开启。")
                    Text("保存：压缩视频（≤5 FPS，最长边 960）、深度、置信度和分析结果。")
                    Text("不保存声音，不上传。停止、切到后台或导出时自动关闭。")
                }
                .font(.caption).foregroundStyle(.orange)
                Text(model.devCaptureStatus.text).font(.caption)
                Button("停止采集并打开 DIAG 导出页") { model.engine.devCapture.stop(); showSpatialSettings = true }
            }
            #endif
            Section {
                NavigationLink("settings.photo.service") { PhotoDescriptionSettingsView() }
                // Camera Control always takes photos; only phones without it get the volume option.
                if PhotoHardwareButtons.volumeAvailable {
                    Toggle("settings.photo.volumeButtons", isOn: $volumeButtons)
                        .accessibilityIdentifier("photoVolumeButtonsToggle")
                }
            } header: {
                Text("settings.photo.section")
            } footer: {
                if PhotoHardwareButtons.hasCameraControl {
                    Text("settings.photo.cameraControl.footer")
                } else if PhotoHardwareButtons.volumeAvailable {
                    Text("settings.photo.volumeButtons.footer")
                }
            }
            Section {
                Toggle("settings.ocr.threeFinger", isOn: $threeFingerReading)
                    .accessibilityIdentifier("threeFingerReadingToggle")
                Picker("settings.ocr.service", selection: $readingService) {
                    ForEach(TextReadingService.allCases) { Text(LocalizedStringKey($0.localizationKey)).tag($0) }
                }
                .accessibilityIdentifier("ocrServicePicker")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("settings.ocr.threeFinger.footer")
                    Text("settings.ocr.service.footer")
                }
            }
            Section("settings.voice.section") {
                Toggle("settings.voice.announcements", isOn: Binding(get: { speech.voiceAnnouncementsEnabled }, set: speech.setVoiceAnnouncementsEnabled))
                    .accessibilityHint("settings.voice.announcements.hint")
                Picker("settings.voice.rate", selection: Binding(get: { speech.rateOption }, set: speech.setRateOption)) {
                    ForEach(SpeechRateOption.allCases) { Text(LocalizedStringKey($0.localizationKey)).tag($0) }
                }
                .accessibilityHint("settings.voice.rate.hint")
            }
            Section {
                Toggle("settings.language.followSystem", isOn: Binding(get: { speech.followSystemLanguageEnabled }, set: speech.setFollowSystemLanguageEnabled))
                Picker("settings.language.picker", selection: Binding(get: { speech.selectedLanguage }, set: speech.setSelectedLanguage)) {
                    // Each language is named in itself so it can be found in either interface language.
                    Text(verbatim: "中文").tag(SpeechLanguage.chinese)
                    Text(verbatim: "English").tag(SpeechLanguage.english)
                }
                .disabled(speech.followSystemLanguageEnabled)
            } header: {
                Text("settings.language.section")
            } footer: {
                Text("settings.language.footer")
            }
            Section {
                Toggle("settings.display.noPreview", isOn: $noPreview)
                    .accessibilityIdentifier("noPreviewToggle")
                if model.supportsScanMesh {
                    Toggle("settings.display.scanMesh", isOn: $model.scanMesh)
                        .disabled(noPreview)
                        .accessibilityIdentifier("scanMeshToggle")
                }
            } header: {
                Text("settings.display.section")
            } footer: {
                if model.supportsScanMesh {
                    Text("settings.display.noPreview.footer") + Text(verbatim: "\n") + Text("settings.display.scanMesh.footer")
                } else {
                    Text("settings.display.noPreview.footer")
                }
            }
            Section("settings.feedback.section") {
                Toggle("settings.feedback.haptic", isOn: Binding(get: { haptics.isEnabled }, set: haptics.setEnabled))
                    .accessibilityHint("settings.feedback.haptic.hint")
            }

        }
        #if PRTS_DEV_CAPTURE
        .sheet(isPresented:$showSpatialSettings) { ProbeSettingsView(model:model) }
        #endif
        .navigationTitle("settings.title")
        .onAppear { speech.speakSettingsScreen(hapticFeedbackEnabled:haptics.isEnabled) }
        .onChange(of:haptics.isEnabled) { _,enabled in speech.speakHapticFeedbackState(enabled) }
    }
}
