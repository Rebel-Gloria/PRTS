import SpatialCore
import SwiftUI
import UniformTypeIdentifiers

struct ProbeSettingsView: View {
    @ObservedObject var model: ProbeViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("深度数据来源") {
                    Toggle("模拟无LiDAR设备",isOn:Binding(get:{ model.snapshot.usesMonocular },set:{ model.setSimulatedNoLiDAR($0) }))
                        .disabled(!model.capabilities.depth)
                        .accessibilityIdentifier("simulateNoLiDAR")
                    Text(model.capabilities.depth ? "开启后禁用 sceneDepth、平滑深度及场景网格；运行中切换将重建会话，清空旧证据。" : "本机不支持 sceneDepth：无LiDAR模式固定开启，不能关闭。").font(.caption)
                    Text("Apple Depth Anything V2 Small FP16 · 相对深度。结合ARKit原生平面/稀疏特征校验尺度；无法确认时只显示相对深度。没有传感器置信度，可绘实验预测线，但不授权已验证净空通道。").font(.caption).foregroundStyle(.secondary)
                    if model.snapshot.usesMonocular { Text(model.snapshot.monocularStatus).font(.caption).foregroundStyle(.orange) }
                }
                Section("扇形目标路径与偏航振动") {
                    Toggle("绘制脚下到扇形目标的预测线",isOn:$model.pathOptions.enabled)
                        .accessibilityIdentifier("pathPrediction")
                    Toggle("振动提示方向偏差",isOn:$model.pathOptions.haptics).disabled(!model.pathOptions.enabled)
                        .accessibilityIdentifier("pathHaptics")
                    Text(String(format:"选点范围：正前方左右各 %.0f°",model.pathOptions.targetHalfAngleDegrees))
                    Slider(value:$model.pathOptions.targetHalfAngleDegrees,in:15...75,step:5)
                    Text("只按沿地面距离选择最远可达点，不偏好正前方。选中后固定世界位置，不因新出现更远点而移动。范围边缘有5°/0.2m余量，持续越界0.3秒后重选。新障碍、追踪异常和地面冲突仍优先撤销提示。").font(.caption)
                    Text(String(format:"到达目标半径 %.2f m（相机地面投影）",model.pathOptions.arrivalRadius))
                    Slider(value:$model.pathOptions.arrivalRadius,in:0.2...0.75,step:0.05)
                    Text(String(format:"路径最小总宽度 %.2f m",model.pathOptions.minimumWidth))
                    Slider(value:$model.pathOptions.minimumWidth,in:0.5...1.2,step:0.05)
                    Text("0.50m仅是预测线的通道宽度要求，不额外叠加身体宽度/余量，也不代表所有人的身体都能通过。原有净空检查参数不变。").font(.caption).foregroundStyle(.orange)
                    Text(String(format:"对准后偏离 %.0f° 才重新提示",model.pathOptions.deviationDegrees))
                    Slider(value:$model.pathOptions.deviationDegrees,in:6...30,step:1)
                    Text(String(format:"失去证据时连线最长显示 %.1f 秒",model.pathOptions.retentionSeconds))
                    Slider(value:$model.pathOptions.retentionSeconds,in:0.5...5,step:0.5)
                    Text(String(format:"前视距离 %.1f m",model.pathOptions.lookAhead))
                    Slider(value:$model.pathOptions.lookAhead,in:0.4...1.5,step:0.1)
                    Text(String(format:"对准角度范围 ±%.0f°",model.pathOptions.validated().alignmentDegrees))
                    Slider(value:$model.pathOptions.alignmentDegrees,in:2...max(2,model.pathOptions.deviationDegrees-2),step:1)
                    Text("连线偏左：重复双短振；偏右：重复长振。偏差越大越强、越密。进入对准范围稳定0.3秒强振一次，之后保持静默；达到重新提示角度并持续0.25秒才恢复。只有单个振动器，靠节奏区分左右，不是在手机左右两侧发振。强振只确认角度，不确认位置或安全。").font(.caption)
                    Text("目标位置与连线证据分开保留。证据过期时隐藏连线并停振，但不另换一个目标；恢复后仍尝试连接同一世界点。").font(.caption)
                    Text("黄圈：远端目标；黄实线：已观测区连线；橙虚线：短时缓存。青虚线：估计脚下至观测起点的未验证连接，不能据此确认盲区可通行。已观测路线不跨未知缺口；蓝地面并不证明头部净空、台阶或落差安全。无LiDAR使用已校准预测几何，误差更大。").font(.caption).foregroundStyle(.orange)
                    Text(model.hapticStatus).font(.caption2)
                }
                Section("传感器显示") {
                    Picker("主图层",selection:$model.options.layer) { ForEach(SensorLayer.allCases) { Text($0.title).tag($0) } }
                    Toggle("RGB 叠加深度热图",isOn:$model.options.overlayDepth)
                    HStack { Text("叠加透明度"); Slider(value:$model.options.overlayAlpha,in:0.1...0.9) }
                    HStack { Text(String(format:"色标上限 %.1f m",model.options.heatMax)); Slider(value:$model.options.heatMax,in:1...8,step:0.5) }
                    Toggle("平滑深度（仅显示）",isOn:$model.options.smoothedDisplay).disabled(model.snapshot.running || !model.capabilities.smooth || model.snapshot.usesMonocular)
                    Text("LiDAR几何使用原始sceneDepth。无LiDAR热图与输入RGB同帧显示，推理存在延迟；无传感器置信度。所有图层保持完整视野。").font(.caption).foregroundStyle(.secondary)
                }
                Section("几何叠加") {
                    Toggle("表面建模：蓝地面／红突起",isOn:$model.options.showSurfaceModel)
                    Toggle("障碍及上方阻挡柱（红色）",isOn:$model.options.showBlockingColumns).disabled(!model.options.showSurfaceModel)
                    Text(String(format:"有体积支持的障碍占地向上标红至 %.2f m（身体检查高度）。上方半透明红色是禁入范围，不是实测实体。至少2个相邻障碍格、6个有效点、1 L几何包络；不跨未知空隙。",model.parameters.bodyHeight)).font(.caption).foregroundStyle(.secondary)
                    Text("仅当前深度的可见表面；高出已确认地面至少5 cm并有空间支持时标红。不补遮挡背面，不保证物体与地面接触。蓝色表示地面表面，不代表可通行。启用时替代历史floor填色和二维栅格投影，俯视图仍保留未知状态。").font(.caption).foregroundStyle(.secondary)
                    Toggle("分类网格线框",isOn:$model.options.showMesh).disabled(model.snapshot.usesMonocular)
                    Toggle("ARKit floor 分类填色",isOn:$model.options.showFloor).disabled(model.options.showSurfaceModel)
                    Toggle("局部栅格投影：未知／障碍／候选",isOn:$model.options.showGrid).disabled(model.options.showSurfaceModel)
                    Toggle("旧版多方向候选段（关闭预测线后显示）",isOn:$model.options.showChannels).disabled(model.pathOptions.enabled)
                    Text("主页面画面、叠加层和指标栏请在“演示模式选项”中设置。").font(.caption)
                    Text("floor 分类不是地面真值；候选区域不代表安全。关闭面板可检查图像四角，底部仍保留实验警告。").font(.caption).foregroundStyle(.secondary)
                }
                Section("几何参数（更改会撤销旧结果）") {
                    valueSlider("人体宽度",value:$model.parameters.bodyWidth,range:0.3...1.2,step:0.05)
                    valueSlider("单侧安全余量",value:$model.parameters.sideMargin,range:0.05...0.5,step:0.05)
                    valueSlider("身体检查高度",value:$model.parameters.bodyHeight,range:1...2.4,step:0.05)
                    Text(String(format:"所需通道宽度 %.2f m",model.parameters.requiredWidth)).foregroundStyle(.cyan)
                    HStack { Text(String(format:"分析 %.0f Hz",model.parameters.processingHz)); Slider(value:$model.parameters.processingHz,in:2...20,step:1) }
                    Stepper("深度采样步长 \(model.parameters.samplingStep)",value:$model.parameters.samplingStep,in:1...8)
                    Text("局部范围：前4 m／左右各1.5 m；栅格10 cm；仅高置信度建立肯定证据；最多250 ms结果年龄。更稀疏采样可能只得到更多未知，不会补洞。").font(.caption).foregroundStyle(.secondary)
                }
                Section("DIAG · 每次启动自动记录") {
                    Text("自动保存深度／置信度帧（按分析频率）、位姿、网格更新、各阶段判定与性能。不会保存 RGB／彩色视频，也不上传。相机仍需点击开始。").font(.caption)
                    Text("本次：\(model.diagnosticStatus.runID)").font(.caption2).textSelection(.enabled)
                    Text(String(format:"已写 %.1f MiB · 排队 %d · 丢弃 %d",Double(model.diagnosticStatus.bytesWritten)/1048576,model.diagnosticStatus.pending,model.diagnosticStatus.droppedTotal)).font(.caption)
                    if model.diagnosticStatus.limitReached { Text("诊断达到磁盘限额，已停止新增数据；请导出并通过文件管理清理历史记录。").foregroundStyle(.orange).font(.caption) }
                    if let error = model.diagnosticStatus.error { Text("DIAG记录异常："+error).foregroundStyle(.red).font(.caption) }
                    Text("无损压缩、32 MiB分段；单次启动512 MiB、Diagnostics目录2 GiB上限。达到限额不删除旧记录；丢失数据会计数。深度／空间结构同样可能包含环境隐私。").font(.caption).foregroundStyle(.secondary)
                    Button("导出本次完整 DIAG") { model.exportDiagnostics() }.disabled(model.exporting)
                    Menu("导出历史 DIAG（最近30次）") {
                        ForEach(model.diagnosticRuns) { run in Button(run.id) { model.exportDiagnostics(runID:run.id) } }
                    }.disabled(model.exporting || model.diagnosticRuns.isEmpty)
                    Button("刷新诊断记录列表") { model.refreshDiagnostics() }
                }
                Section("会话指标与手动空间样本") {
                    Text("LiDAR手动样本含深度、置信度和几何；无LiDAR手动样本写入DIAG的prediction记录。均不保存RGB。预测数据不能用旧测量深度回放器冒充LiDAR数据。").font(.caption)
                    Text(model.recorderStatus.message).font(.caption).textSelection(.enabled)
                    if let error = model.recorderStatus.error { Text(error).font(.caption).foregroundStyle(.red) }
                    Text("丢弃日志记录：\(model.recorderStatus.droppedRecords)").font(.caption)
                    Button(model.exporting ? "正在准备导出…" : "导出会话文件夹到“文件”") { model.export() }.disabled(model.exporting || model.recorderStatus.directory == nil)
                    Text("包含 manifest.json、frames.jsonl、metrics.csv、events.jsonl，以及手动样本。导出运行中会话时得到该时刻的快照；停止后导出可获得完整会话。").font(.caption).foregroundStyle(.secondary)
                }
                Section("能力与边界") {
                    Text(model.capabilities.description).font(.caption)
                    Text("参考方向是相机朝向的地面投影，不等于人体前进方向。近身盲区不连接到候选段。不能宣称可靠台阶、落差、玻璃或细小障碍检测。").font(.caption)
                    Text("所有行走测试由视力正常人员在受控环境完成，不进行无保护盲行。真机能力须实测，模拟器不构成 LiDAR 验收。").font(.caption).foregroundStyle(.orange)
                    Text("实验验证，候选通道不等于安全路线").font(.caption.weight(.bold))
                }
            }
            .navigationTitle("验证参数").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.confirmationAction) { Button("完成") { dismiss() } } }
        }
        .sheet(isPresented:Binding(get:{ model.exportURL != nil },set:{ if !$0 { model.exportURL = nil } })) {
            if let url = model.exportURL { ExportDocumentPicker(url:url,onFinish:{ model.exportURL = nil }) }
        }
        .alert("导出未完成",isPresented:Binding(get:{ model.errorMessage != nil },set:{ if !$0 { model.errorMessage = nil } })) {
            Button("确定") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .onAppear { model.refreshDiagnostics() }
        .onChange(of:model.pathOptions) { _,_ in model.updatePathSettings() }
        .onChange(of:model.parameters) { _,_ in model.updateSettings() }
        .onChange(of:model.options.layer) { _,_ in model.updateLayers() }
        .onChange(of:model.options.overlayDepth) { _,_ in model.updateLayers() }
        .onChange(of:model.options.overlayAlpha) { _,_ in model.updateLayers() }
        .onChange(of:model.options.smoothedDisplay) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showMesh) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showBlockingColumns) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showSurfaceModel) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showFloor) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showGrid) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showChannels) { _,_ in model.updateLayers() }
        .onChange(of:model.options.showHUD) { _,_ in model.updateLayers() }
        .onChange(of:model.options.heatMax) { _,_ in model.updateLayers() }
    }
    private func valueSlider(_ title: String,value: Binding<Float>,range: ClosedRange<Float>,step: Float) -> some View {
        VStack(alignment:.leading) { Text(String(format:"%@ %.2f m",title,value.wrappedValue)); Slider(value:value,in:range,step:step) }
    }
}

struct ExportDocumentPicker: UIViewControllerRepresentable {
    let url: URL
    let onFinish: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish:onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting:[url],asCopy:true)
        picker.shouldShowFileExtensions = true; picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController,context: Context) {}
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish() }
        func documentPicker(_ controller: UIDocumentPickerViewController,didPickDocumentsAt urls: [URL]) { onFinish() }
    }
}
