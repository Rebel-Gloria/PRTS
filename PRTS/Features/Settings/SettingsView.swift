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
    @AppStorage(ContentView.noPreviewKey) private var noPreview = false
    @AppStorage(ContentView.tapToStopKey) private var tapToStop = false
    @State private var showUserGuide = false
    @AppStorage(ContentView.lowVisionKey) private var lowVisionMode = false
    @State private var confirmLowVision = false

    var body: some View {
        Form {
            #if PRTS_DEV_CAPTURE
            Section("开发者选项") {
                Toggle("主页面参数指标与图例", isOn: $showTechnicalOverlay).accessibilityIdentifier(
                    "devTechnicalOverlayToggle"
                )
                Toggle("主页面测试指令栏", isOn: $showCommandEntry).accessibilityIdentifier(
                    "devCommandEntryToggle"
                )
                Text("只控制调试信息是否显示。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("图层、路径、触觉与 DIAG 日志") { showSpatialSettings = true }.accessibilityIdentifier(
                    "spatialSettingsButton"
                )
                NavigationLink("演示模式选项") { DemoOptionsView(model: model) }.accessibilityIdentifier(
                    "demoOptionsLink"
                )
                Toggle(
                    "保存相机视频与分析数据",
                    isOn: Binding(
                        get: { model.devCaptureStatus.enabled },
                        set: { enabled in
                            if enabled {
                                model.engine.devCapture.enable()
                            } else {
                                model.engine.devCapture.stop()
                            }
                            model.devCaptureStatus = model.engine.devCapture.status()
                        }
                    )
                ).accessibilityIdentifier("devCaptureToggle").disabled(
                    model.exporting
                        || (model.devCaptureStatus.busy && !model.devCaptureStatus.enabled)
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("只在已取得同意的测试场地开启。")
                    Text("保存：压缩视频（≤5 FPS，最长边 960）、深度、置信度和分析结果。")
                    Text("不保存声音，不上传。停止、切到后台或导出时自动关闭。")
                }
                .font(.caption).foregroundStyle(.orange)
                Text(model.devCaptureStatus.text).font(.caption)
                Button("停止采集并打开 DIAG 导出页") {
                    model.engine.devCapture.stop()
                    showSpatialSettings = true
                }
            }
            #endif
            Section("settings.photo.section") {
                NavigationLink("settings.photo.service") { PhotoDescriptionSettingsView() }
            }
            Section {
                Toggle("settings.tapToStop", isOn: $tapToStop)
                    .accessibilityIdentifier("tapToStopToggle")
            } footer: {
                Text("settings.tapToStop.footer")
            }
            Section {
                // Turning it on stops obstacle guidance, so it asks first; turning it off does not.
                Toggle(
                    "settings.lowVision",
                    isOn: Binding(
                        get: { lowVisionMode },
                        set: { on in on ? (confirmLowVision = true) : (lowVisionMode = false) }
                    )
                )
                .accessibilityIdentifier("lowVisionToggle")
                .alert("settings.lowVision.confirm.title", isPresented: $confirmLowVision) {
                    Button("settings.lowVision.confirm.turnOn") { lowVisionMode = true }
                    Button("settings.lowVision.confirm.cancel", role: .cancel) {}
                } message: {
                    Text("settings.lowVision.confirm.message")
                }
            } footer: {
                Text("settings.lowVision.footer")
            }
            Section("settings.voice.section") {
                Toggle(
                    "settings.voice.announcements",
                    isOn: Binding(
                        get: { speech.voiceAnnouncementsEnabled },
                        set: speech.setVoiceAnnouncementsEnabled
                    )
                )
                .accessibilityHint("settings.voice.announcements.hint")
                Picker(
                    "settings.voice.rate",
                    selection: Binding(get: { speech.rateOption }, set: speech.setRateOption)
                ) {
                    ForEach(SpeechRateOption.allCases) {
                        Text(LocalizedStringKey($0.localizationKey)).tag($0)
                    }
                }
                .accessibilityHint("settings.voice.rate.hint")
            }
            Section {
                Toggle(
                    "settings.language.followSystem",
                    isOn: Binding(
                        get: { speech.followSystemLanguageEnabled },
                        set: speech.setFollowSystemLanguageEnabled
                    )
                )
                // Shown only when it can be used: a dimmed picker leaves VoiceOver users guessing why.
                if !speech.followSystemLanguageEnabled {
                    Picker(
                        "settings.language.picker",
                        selection: Binding(
                            get: { speech.selectedLanguage },
                            set: speech.setSelectedLanguage
                        )
                    ) {
                        // Each language is named in itself so it can be found in either interface
                        // language.
                        Text(verbatim: "中文").tag(SpeechLanguage.chinese)
                        Text(verbatim: "English").tag(SpeechLanguage.english)
                    }
                }
            } header: {
                Text("settings.language.section")
            } footer: {
                Text("settings.language.footer")
            }
            Section {
                Toggle("settings.display.noPreview", isOn: $noPreview)
                    .accessibilityHint("settings.display.noPreview.hint")
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
                    Text("settings.display.noPreview.footer") + Text(verbatim: "\n")
                        + Text("settings.display.scanMesh.footer")
                } else {
                    Text("settings.display.noPreview.footer")
                }
            }
            Section {
                Button("settings.userGuide") { showUserGuide = true }
                    .accessibilityIdentifier("userGuideButton")
                    // Attached here, not to the Form, so it never competes with the developer sheet.
                    .sheet(isPresented: $showUserGuide) {
                        UserGuideView().environmentObject(speech)
                    }
            }
        }
        #if PRTS_DEV_CAPTURE
        .sheet(isPresented: $showSpatialSettings) { ProbeSettingsView(model: model) }
        #endif
        .navigationTitle("settings.title")
        .onAppear { speech.speakSettingsScreen() }
    }
}
