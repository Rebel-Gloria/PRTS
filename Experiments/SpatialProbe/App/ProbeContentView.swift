import SwiftUI
import SpatialCore
import simd

struct ProbeContentView: View {
    @ObservedObject var model: ProbeViewModel
    @State private var showSettings = false
    @State private var confirmSample = false
    private let timer = Timer.publish(every:0.1,on:.main,in:.common).autoconnect()
    private var geometryResult: AnalysisResult? { model.snapshot.activeGeometryResult(now:ProcessInfo.processInfo.systemUptime) }
    private var surfacePresentation: SurfacePresentation? { model.snapshot.activeSurfacePresentation(now:ProcessInfo.processInfo.systemUptime) }
    private var guidanceResult: AnalysisResult? { model.snapshot.activeGuidanceResult(now:ProcessInfo.processInfo.systemUptime) }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraMetalView(store:model.engine.store,diagnostics:model.engine.diagnostics).ignoresSafeArea()
            GeometryReader { geometry in
                if geometry.size.width > geometry.size.height {
                    VStack(spacing:6) {
                        HStack(alignment:.top,spacing:10) {
                            if model.options.showHUD { ScrollView { hud }.frame(maxWidth:.infinity) }
                            ScrollView {
                                VStack(spacing:8) {
                                    if !model.snapshot.running { idlePanel }
                                    freezeLabel
                                    if model.options.showHUD { resultPanel }
                                }
                            }.frame(maxWidth:.infinity)
                        }
                        controls
                    }.padding(.horizontal,12).padding(.vertical,6)
                } else {
                    VStack(spacing:8) {
                        if model.options.showHUD { hud }
                        Spacer(minLength:8)
                        if !model.snapshot.running { idlePanel }
                        freezeLabel
                        Spacer(minLength:0)
                        if model.options.showHUD { resultPanel }
                        controls
                    }.padding(.horizontal,12).padding(.vertical,8)
                }
            }
        }
        .onReceive(timer) { _ in model.poll() }
        .onAppear {
            model.poll()
            #if DEBUG
            // Deterministic simulator UI inspection; never fabricates hardware or starts capture.
            if ProcessInfo.processInfo.arguments.contains("--show-settings") { showSettings = true }
            #endif
        }
        .onChange(of:showSettings) { _,shown in model.feedbackSuspended = shown; model.poll() }
        .sheet(isPresented:$showSettings) { ProbeSettingsView(model:model) }
        .confirmationDialog("保存空间数据样本？",isPresented:$confirmSample,titleVisibility:.visible) {
            Button("保存深度＋置信度及几何（无RGB）") { model.sample() }
            Button("取消",role:.cancel) {}
        } message: { Text("保存冻结帧；未冻结时优先保存最近已分析帧（元数据含时间）。只保存空间测量数据，不保存RGB图像。空间结构仍可能包含环境隐私；不会自动上传。") }
        .alert("操作未完成",isPresented:Binding(get:{ model.errorMessage != nil && !showSettings },set:{ if !$0 { model.errorMessage = nil } })) {
            Button("确定") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }
    @ViewBuilder private var freezeLabel: some View {
        if model.snapshot.frozen != nil {
            Text("冻结检查 · 非实时 · 通道已撤销").font(.headline).padding(8).background(.orange.opacity(0.8),in:RoundedRectangle(cornerRadius:8))
        }
    }
    private var hud: some View {
        VStack(alignment:.leading,spacing:5) {
            HStack {
                Text("PRTS / SPATIAL PROBE").font(.system(.caption,design:.monospaced).weight(.semibold))
                Spacer()
                Text(model.snapshot.running ? "采集中" : "已停止").font(.caption2).foregroundStyle(model.snapshot.running ? .cyan : .secondary)
            }
            let s = model.snapshot,m = s.renderMetrics,r = s.diagnosticResult
            Text(String(format:"FPS 采集 %.1f / 分析 %.1f / 绘制 %.1f",s.captureFPS,s.analysisFPS,m.fps))
            Text(String(format:"ms 打包 %.1f / 深度 %.1f / 地面栅格 %.1f",s.frame?.captureMilliseconds ?? 0,(r?.stageMilliseconds["depth"] ?? 0)+(r?.stageMilliseconds["depthCopy"] ?? 0),r?.stageMilliseconds["groundGrid"] ?? 0))
            Text(String(format:"ms 网格 %.1f / 通道 %.1f / 绘制 CPU %.1f GPU %.1f",s.meshMS,r?.stageMilliseconds["channel"] ?? 0,m.cpuMS,m.gpuMS))
            Text("追踪：\(s.frame?.tracking ?? "未运行") · 热状态：\(s.thermal)")
            HStack {
                Text("\(s.usesMonocular ? "米制预测" : "有效深度") \(percent(r?.validDepthCoverage))")
                Text("未知栅格 \(percent(r.map { $0.grid?.unknownFraction ?? 1 }))")
                Spacer(); Text("丢帧 \(s.droppedFrames)")
            }
            Text("源帧年龄 \(age(r?.timestamp)) · 分析/显示帧差 \(milliseconds(m.analysisDisplayDeltaMS))")
            Text("网格回调年龄 \(age(s.meshes.values.map(\.callbackTime).max())) · \(s.renderStatus)")
            Text(String(format:"表面建模 %.1f ms",r?.stageMilliseconds["surfaceModel"] ?? 0))
            Text(s.usesMonocular ? "预测输入绑定RGB帧；非LiDAR硬件采样" : "RGB/深度硬件时间差：API 未提供").foregroundStyle(.secondary)
            Text(String(format:"DIAG %.1f MiB · 丢记录 %d · %@",Double(model.diagnosticStatus.bytesWritten)/1048576,model.diagnosticStatus.droppedTotal,
                model.diagnosticStatus.limitReached ? "配额已满" : (model.diagnosticStatus.error == nil ? "自动记录／无RGB" : "写入异常"))).foregroundStyle(model.diagnosticStatus.limitReached || model.diagnosticStatus.error != nil ? .orange : .secondary)
            if s.usesMonocular {
                Text("无LiDAR · Apple Core ML · 原生平面 \(s.nativePlanes.count)").foregroundStyle(.cyan)
                Text(s.currentMonocularStatus).foregroundStyle(.orange)
                Text("相对输出 \(percent(s.activeMonocular?.relativeCoverage)) · 地面：\(s.activeMonocular?.groundStatus ?? "无当前参考")").foregroundStyle(.secondary)
                Text(String(format:"CoreML %.1f / 模型流程 %.1f ms · 净空未知",r?.stageMilliseconds["coreMLPrediction"] ?? 0,r?.stageMilliseconds["modelPipeline"] ?? 0))
            }
            if (s.usesMonocular || s.displayedFrame?.frame.sceneDepth?.confidenceMap == nil),s.running { Text("置信度不可用：不得确认可通行").foregroundStyle(.orange) }
            if !s.usesMonocular && s.options.smoothedDisplay { Text("显示：smoothedSceneDepth；几何：原始 sceneDepth").foregroundStyle(.orange) }
            if !model.capabilities.depth || !model.capabilities.meshClassification { Text(model.capabilities.description).foregroundStyle(.orange) }
        }
        .font(.system(size:10,design:.monospaced)).monospacedDigit()
        .padding(10).frame(maxWidth:.infinity,alignment:.leading)
        .background(.black.opacity(0.68),in:RoundedRectangle(cornerRadius:12))
        .accessibilityElement(children:.combine)
    }
    private var idlePanel: some View {
        VStack(spacing:12) {
            Image(systemName:"viewfinder").font(.system(size:38,weight:.light)).foregroundStyle(.cyan)
            Text("原生空间感知验证").font(.headline)
            Text(model.permissionMessage ?? model.snapshot.status).font(.caption).multilineTextAlignment(.center)
            if model.permissionMessage != nil {
                Button("打开应用权限设置") { if let url = URL(string:UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            }
            Text("仅真机可验收 LiDAR；模拟器不提供传感器证据").font(.caption2).foregroundStyle(.secondary)
        }.padding(20).frame(maxWidth:360).background(.black.opacity(0.75),in:RoundedRectangle(cornerRadius:16))
    }
    private var resultPanel: some View {
        VStack(alignment:.leading,spacing:6) {
            if model.options.layer == .depth || model.options.overlayDepth {
                HStack(spacing:8) {
                    Text(model.snapshot.usesMonocular ? (model.snapshot.activeMonocular?.observation == nil ? "相对深度 · 无单位" : "预测轴向深度 m") : "轴向深度 m").font(.caption2)
                    LinearGradient(colors:[Color(red:1,green:0.12,blue:0.05),Color(red:1,green:0.9,blue:0),Color(red:0,green:0.85,blue:1),Color(red:0.12,green:0.15,blue:0.9)],startPoint:.leading,endPoint:.trailing).frame(height:8)
                }
                if model.snapshot.usesMonocular && model.snapshot.activeMonocular?.observation == nil {
                    HStack { Text("相对近"); Spacer(); Text("相对远 · 不可用于测距") }.font(.system(size:9))
                } else {
                    HStack { Text("0"); Spacer(); Text(String(format:"%.1f",model.options.heatMax/3)); Spacer(); Text(String(format:"%.1f",model.options.heatMax*2/3)); Spacer(); Text(String(format:"%.1f+",model.options.heatMax)) }.font(.system(size:9,design:.monospaced))
                }
            }
            if model.options.layer == .confidence { Text(model.snapshot.usesMonocular ? "模型不提供传感器置信度，灰色表示不可用" : "置信度：🔴 低(0)  🟠 中(1)  🟢 高(2)  灰：无效/缺失").font(.system(size:10)) }
            if !model.snapshot.usesMonocular && (model.options.showMesh || (model.options.showFloor && !model.options.showSurfaceModel)) { Text("ARKit 分类：蓝 地面 · 灰白 墙 · 紫 顶 · 橙 桌 · 粉 座椅 · 青 窗 · 浅绿 门").font(.system(size:9)).foregroundStyle(.secondary) }
            if model.options.showSurfaceModel {
                Text(model.snapshot.usesMonocular ? "预测建模：蓝 参考面附近 · 红 疑似突起 · 原生平面轮廓：蓝 floor／黄 未确认" : "表面建模：蓝 地面 · 红 突起/物品（≥5 cm）· 缺证据不建模").font(.system(size:10)).foregroundStyle(.secondary)
                if let summary = surfacePresentation?.result.surfaceModel?.summary {
                    Text("地面 \(summary.groundTriangles) 面 · 突起 \(summary.protrusionTriangles) 面 · 蓝色不等于可通行").font(.system(size:9)).foregroundStyle(.secondary)
                    if surfacePresentation?.historical != true,model.options.showBlockingColumns,let blocking = summary.blockingVolume {
                        Text(String(format:"红色阻挡柱 %d 格 · 上方禁入至 %.2f m（非实体）",blocking.columnCount,blocking.nominalCeiling)).font(.system(size:9)).foregroundStyle(.red)
                    }
                } else {
                    Text("表面模型：未知／等待初始地面参考或新的深度").font(.system(size:9)).foregroundStyle(.orange)
                    if let reasons = geometryResult?.diagnostics?.modelBlockReasons,!reasons.isEmpty {
                        Text("DIAG："+reasons.joined(separator:" / ")).font(.system(size:8,design:.monospaced)).foregroundStyle(.orange)
                    }
                }
            }
            if let result = geometryResult {
                HStack(alignment:.top,spacing:10) {
                    if let grid = result.grid {
                        let path = model.snapshot.activePath(now:ProcessInfo.processInfo.systemUptime)
                        GridMiniMap(grid:grid,segments:model.pathOptions.enabled ? [] : guidanceResult?.segments ?? [],worldPath:path?.path.points ?? [],approach:path?.approach ?? [],historical:path?.historical ?? false).frame(width:84,height:110)
                    }
                    VStack(alignment:.leading,spacing:5) {
                        ForEach(Sector.allCases,id:\.self) { sector in
                            let distance = guidanceResult?.distances.first { $0.sector == sector }
                            let segment = guidanceResult?.segments.first { $0.sector == sector }
                            Text("\(sector.title) 障碍 \(distance.map { String(format:"%.2f m",$0.groundDistance) } ?? "未知") · \(segment.map { String(format:"段长 %.1f m / 宽 %.1f m",$0.length,$0.minimumObservedWidth) } ?? "无候选通道")")
                            if let segment { Text(String(format:"  观测段起点 %.1f m；不连接脚下",segment.startDistance)).foregroundStyle(.secondary) }
                        }
                        Text(model.snapshot.usesMonocular ? result.status : guidanceResult?.status ?? (result.grid == nil || result.diagnostics?.groundReferenceMode == "retained_world_reference" ? result.status : model.snapshot.frame?.directionStable == false
                             ? "方向变化：几何继续更新，通道及方向距离暂停"
                             : "几何继续更新；等待新的稳定方向结果")).foregroundStyle(.yellow)
                    }.font(.system(size:10,design:.monospaced))
                }
            } else {
                Text(model.snapshot.running ? (model.snapshot.usesMonocular ? "无当前预测几何，尺度／地面状态见上方\n预测路径见下方；身体净空仍未知" : "左 / 中 / 右：未知 · 无候选通道\n等待有效追踪、地面支持和及时结果") : "左 / 中 / 右：未知 · 无候选通道").font(.caption)
            }
            Text("参考：相机前向的地面投影 · 胸前朝前持机，未估计人体朝向").font(.system(size:9)).foregroundStyle(.secondary)
            Text("灰 未知 · 红 障碍 · 黄圈 目标 · 黄 实测区预测线 · 青虚线 脚下盲区连接 · 橙 历史线（诊断叠加，非遮挡真实感）").font(.system(size:9)).foregroundStyle(.secondary)
        }.padding(10).background(.black.opacity(0.72),in:RoundedRectangle(cornerRadius:12))
    }
    private var controls: some View {
        VStack(spacing:8) {
            // Always visible, even when the diagnostic HUD is hidden.
            if model.options.showSurfaceModel,let surface = surfacePresentation {
                if surface.historical {
                    Text(String(format:"历史线框 %.1f s · 当前测量不足 · 非实时占用/通道",surface.age))
                        .font(.caption2).foregroundStyle(.orange).padding(5).background(.black.opacity(0.75))
                } else if ["retained_world_reference","retained_native_reference"].contains(surface.result.diagnostics?.groundReferenceMode ?? "") {
                    Text(String(format:"沿用地面参考 %.1f s＋当前深度（非净空证明） · 通道未知",
                                surface.result.diagnostics?.groundReferenceAge ?? 0))
                        .font(.caption2).foregroundStyle(.orange).padding(5).background(.black.opacity(0.75))
                }
            }
            if model.pathOptions.enabled {
                pathStatus
            }
            Text("实验验证，预测路径不等于安全路线").font(.caption.weight(.semibold)).foregroundStyle(.yellow)
            HStack(spacing:12) {
                Button { model.startOrStop() } label: {
                    Label(model.snapshot.running ? "停止" : "开始",systemImage:model.snapshot.running ? "stop.fill" : "play.fill").frame(minWidth:64)
                }.buttonStyle(.borderedProminent).tint(model.snapshot.running ? .red : .cyan).disabled(model.requestingPermission)
                Button { model.engine.freeze(); model.poll() } label: { Image(systemName:model.snapshot.frozen == nil ? "pause.rectangle" : "play.rectangle").font(.title3) }
                    .disabled(!model.snapshot.running).accessibilityLabel("冻结或恢复传感器显示")
                Button { confirmSample = true } label: { Image(systemName:"camera.badge.ellipsis").font(.title3) }
                    .disabled(model.snapshot.displayedFrame == nil).accessibilityLabel("保存同帧空间数据（不含RGB）")
                Spacer(minLength:0)
                Button { showSettings = true } label: { Label("设置",systemImage:"slider.horizontal.3").font(.callout) }
            }
        }.padding(10).background(.black.opacity(0.85),in:RoundedRectangle(cornerRadius:12))
    }
    @ViewBuilder private var pathStatus: some View {
        let now = ProcessInfo.processInfo.systemUptime
        if let p = model.snapshot.activePath(now:now) {
            let h = model.snapshot.pathHeading(now:now)
            VStack(spacing:2) {
                Text(String(format:"%@ · 长 %.1f m%@",p.historical ? "橙虚线：短时历史路径" : "黄线：已观测段",p.path.length,p.path.source.contains("coreml") ? " · 模型预测" : ""))
                if let h {
                    Text(String(format:"%@ %.0f° · 横偏 %.2f m · 观测起点 %.1f m",h.angleDegrees >= 0 ? "连线偏右" : "连线偏左",abs(h.angleDegrees),h.crossTrack,h.startDistance))
                } else { Text("方向不可用：保留世界路径，暂停振动") }
                if let target = p.path.points.last,let pose = model.snapshot.frame?.pose {
                    Text(String(format:"固定远目标 · 距估计脚下 %.1f m · 最小宽 %.2f m",simd_distance(p.path.plane.project(pose.position),target),p.path.requiredWidth))
                }
                Text(p.historical ? String(format:"历史 %.1f s；新障碍立即撤销，超时清除",p.age) : "左双短／右长／对准强振一次；青虚线盲区未验证")
            }.font(.system(size:10,design:.monospaced)).foregroundStyle(p.historical ? .orange : .yellow)
        } else if model.snapshot.running,model.snapshot.pathUpdate.goal != nil {
            Text("目标位置保留：当前连线证据不足、已到达或超出显示范围；暂停振动").font(.caption2).foregroundStyle(.orange)
        } else {
            Text(String(format:"未找到扇形内可达目标：检查蓝面支持、障碍和 %.2f m 宽度",model.pathOptions.validated().minimumWidth)).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func percent(_ value: Float?) -> String { value.map { String(format:"%.0f%%",$0*100) } ?? "—" }
    private func milliseconds(_ value: Double?) -> String { value.map { String(format:"%.0f ms",$0) } ?? "—" }
    private func age(_ time: Double?) -> String { time.map { String(format:"%.0f ms",max(0,ProcessInfo.processInfo.systemUptime-$0)*1000) } ?? "—" }
}

private struct GridMiniMap: View {
    let grid: LocalGrid
    let segments: [CandidateSegment]
    var worldPath: [V3] = []
    var approach: [V3] = []
    var historical = false
    var body: some View {
        Canvas { context,size in
            let dx = size.width/CGFloat(grid.columns),dy = size.height/CGFloat(grid.rows)
            for i in grid.cells.indices {
                let cell = grid.cells[i],x = i%grid.columns,z = i/grid.columns
                let color: Color = cell.state == .unknown ? .gray.opacity(0.5) : (cell.state == .obstacle ? .red : .mint)
                context.fill(Path(CGRect(x:CGFloat(x)*dx,y:size.height-CGFloat(z+1)*dy,width:max(1,dx-0.3),height:max(1,dy-0.3))),with:.color(color))
            }
            func screen(_ p: V3) -> CGPoint {
                let q = grid.basis.local(p)
                return CGPoint(x:CGFloat((q.x+grid.halfWidth)/grid.cellSize)*dx,y:size.height-CGFloat(q.z/grid.cellSize)*dy)
            }
            if approach.count == 2 {
                var line = Path();line.move(to:screen(approach[0]));line.addLine(to:screen(approach[1]))
                context.stroke(line,with:.color(.cyan),style:StrokeStyle(lineWidth:1,dash:[3,3]))
            }
            if let goal = worldPath.last {
                let c = screen(goal)
                context.stroke(Path(ellipseIn:CGRect(x:c.x-3,y:c.y-3,width:6,height:6)),with:.color(historical ? .orange : .yellow),lineWidth:1)
            }
            if worldPath.count > 1 {
                var line = Path()
                for (n,p) in worldPath.enumerated() {
                    let local = grid.basis.local(p)
                    let point = CGPoint(x:CGFloat((local.x+grid.halfWidth)/grid.cellSize)*dx,y:size.height-CGFloat(local.z/grid.cellSize)*dy)
                    if n == 0 { line.move(to:point) } else { line.addLine(to:point) }
                }
                context.stroke(line,with:.color(historical ? .orange : .yellow),style:StrokeStyle(lineWidth:2,dash:historical ? [3,3] : []))
            }
            for segment in segments {
                var path = Path()
                for (n,i) in segment.cellIndices.enumerated() {
                    let point = CGPoint(x:(CGFloat(i%grid.columns)+0.5)*dx,y:size.height-(CGFloat(i/grid.columns)+0.5)*dy)
                    if n == 0 { path.move(to:point) } else { path.addLine(to:point) }
                }
                context.stroke(path,with:.color(.yellow),lineWidth:2)
            }
        }.accessibilityLabel("局部栅格俯视图；灰色未知，红色障碍，青色候选观测区")
    }
}
