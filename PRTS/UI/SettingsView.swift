/// Product settings page; uses the system navigation back button.

import SwiftUI
import SpatialCore

struct SettingsView: View {
    @ObservedObject var model: ProbeViewModel
    #if PRTS_DEV_CAPTURE
    @AppStorage("developer.showTechnicalOverlay") private var showTechnicalOverlay = true
    @AppStorage("developer.showCommandEntry") private var showCommandEntry = true
    @State private var showSpatialSettings = false
    #endif
    @EnvironmentObject private var speech: SpeechManager
    @EnvironmentObject private var haptics: HapticManager
    @AppStorage(PhotoCaptureButton.hardwareButtonsKey) private var photoHardwareButtons = true
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
                Toggle("settings.photo.hardwareButtons", isOn: $photoHardwareButtons)
                    .accessibilityIdentifier("photoHardwareButtonsToggle")
            } header: {
                Text("settings.photo.section")
            } footer: {
                Text("settings.photo.hardwareButtons.footer")
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
            Section {
                PassageWidthSlider(model: model)
            } header: {
                Text("settings.guidance.section")
            } footer: {
                Text("settings.guidance.width.footer")
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

/// Flexible ← Balanced → Comfortable: the hard body width the route must fit through.
private struct PassageWidthSlider: View {
    @ObservedObject var model: ProbeViewModel
    static let range: ClosedRange<Float> = 0.4...0.6
    static let balanced: Float = 0.5

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Text("settings.guidance.width")
                Spacer()
                Text(meters).foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(value: $model.parameters.bodyWidth, in: Self.range, step: 0.05) {
                Text("settings.guidance.width")
            } onEditingChanged: { editing in
                if !editing { model.updateSettings() }
            }
            .accessibilityValue(Text(LocalizedStringKey(styleKey)) + Text(verbatim: ", " + meters))
            .accessibilityIdentifier("passageWidthSlider")
            HStack {
                Text(verbatim: "← ") + Text("settings.guidance.width.flexible")
                Spacer()
                Text("settings.guidance.width.balanced")
                Spacer()
                Text("settings.guidance.width.comfortable") + Text(verbatim: " →")
            }
            .font(.caption).foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }

    private var meters: String {
        Measurement(value: (Double(model.parameters.bodyWidth) * 100).rounded(), unit: UnitLength.centimeters)
            .formatted(.measurement(width: .abbreviated, usage: .asProvided))
    }

    private var styleKey: String {
        let width = model.parameters.bodyWidth
        if abs(width - Self.balanced) < 0.01 { return "settings.guidance.width.balanced" }
        return width < Self.balanced ? "settings.guidance.width.flexible" : "settings.guidance.width.comfortable"
    }
}
