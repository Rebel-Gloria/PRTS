#if PRTS_DEV_CAPTURE
/// Presentation-only switches for the home-screen demonstration overlays.

import SwiftUI
import SpatialCore

/// Presentation switches only: the home screen remains the sole live display.
struct DemoOptionsView: View {
    @ObservedObject var model: ProbeViewModel
    @EnvironmentObject private var speech: SpeechManager
    var body: some View {
        Form {
            Section("主页面画面") {
                Toggle("显示相机画面",isOn:$model.options.showCameraImage).accessibilityIdentifier("demoCameraToggle")
                Text("只隐藏画面，后台照常工作。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("传感器底图",selection:$model.options.layer) {
                    ForEach(SensorLayer.allCases) { Text($0.title).tag($0) }
                }
                Toggle("叠加深度热图",isOn:$model.options.overlayDepth).disabled(model.options.layer != .rgb)
                Text("深度和置信度底图不受画面开关影响。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("主页面叠加层") {
                Toggle("几何叠加总开关",isOn:$model.options.showOverlays).accessibilityIdentifier("demoOverlaysToggle")
                Group {
                    Toggle("蓝色地面与红色突起",isOn:$model.options.showSurfaceModel)
                    Toggle("障碍上方红色阻挡柱",isOn:$model.options.showBlockingColumns).disabled(!model.options.showSurfaceModel)
                    Toggle("分类网格线框",isOn:$model.options.showMesh).disabled(model.snapshot.usesMonocular)
                    Toggle("原生地面分类",isOn:$model.options.showFloor).disabled(model.options.showSurfaceModel)
                    Toggle("局部栅格：未知／障碍／候选",isOn:$model.options.showGrid).disabled(model.options.showSurfaceModel)
                    Toggle("路径与目标点",isOn:$model.options.showPath).accessibilityIdentifier("demoPathToggle")
                }.disabled(!model.options.showOverlays)
                Text("只影响显示，不影响分析和振动。开启表面建模时，它代替地面分类和栅格显示。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("主页面信息栏") {
                Toggle("参数指标栏",isOn:$model.options.showHUD).accessibilityIdentifier("demoMetricsToggle")
                Toggle("图例与来源说明",isOn:$model.options.showLegends).accessibilityIdentifier("demoLegendsToggle")
                Text("自动保存，回到主页即生效。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("蓝色：地面。红色：障碍及上方阻挡范围。")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .onAppear { speech.speak("演示模式选项。可调整主页的画面、叠加层、路径和指标。") }
        .navigationTitle("演示模式选项")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
