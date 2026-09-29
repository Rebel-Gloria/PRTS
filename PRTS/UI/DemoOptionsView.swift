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
                Toggle("显示摄像机画面",isOn:$model.options.showCameraImage).accessibilityIdentifier("demoCameraToggle")
                Text("只隐藏 RGB 画面；相机采集、空间感知、路径计算和 DIAG 继续运行。关闭后仍可在深色背景查看叠加层。停止采集请使用主页面停止按钮。")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("传感器底图",selection:$model.options.layer) {
                    ForEach(SensorLayer.allCases) { Text($0.title).tag($0) }
                }
                Toggle("叠加深度热图",isOn:$model.options.overlayDepth).disabled(model.options.layer != .rgb)
                Text("深度和置信度底图独立于 RGB 开关；缺失数据不会显示为有效观测。")
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
                Text("关闭叠加层或路径显示不停止分析，也不关闭方向振动。表面建模开启时替代地面分类填色及栅格投影。振动请在触觉和路径设置中调整。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("主页面信息栏") {
                Toggle("参数指标栏",isOn:$model.options.showHUD).accessibilityIdentifier("demoMetricsToggle")
                Toggle("图例与来源说明",isOn:$model.options.showLegends).accessibilityIdentifier("demoLegendsToggle")
                Text("开关自动保存；返回主页面立即生效，无需另行启动演示模式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("蓝色：地面。红色：障碍及上方阻挡范围。")
                    .font(.footnote).foregroundStyle(.orange)
            }
        }
        .onAppear { speech.speak("演示模式选项。可控制主页面摄像机画面、叠加层、路径和参数指标。隐藏画面不会停止采集。") }
        .navigationTitle("演示模式选项")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#endif
