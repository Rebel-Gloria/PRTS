#if PRTS_DEV_CAPTURE
/// Read-only home overlay driven by the same `ProbeViewModel` as the renderer.

import SwiftUI
import SpatialCore

/// Read-only overlay of the same snapshot used by the home renderer; no session or timer.
struct HomeDemoOverlay: View {
    @AppStorage("developer.showTechnicalOverlay") private var showTechnicalOverlay = true
    @ObservedObject var model: ProbeViewModel
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            #if PRTS_DEV_CAPTURE
            if model.devCaptureStatus.enabled || model.devCaptureStatus.busy {
                Text("● 开发信息采集 · 摄像机视频正在保存或结束中")
                    .font(.caption.bold()).foregroundStyle(.red).padding(8).background(.black.opacity(0.8))
            }
            #endif
            if showTechnicalOverlay && model.options.showHUD {
                VStack(alignment:.leading,spacing:4) {
                    let s = model.snapshot
                    let result = s.diagnosticResult
                    Text("空间感知 · 参数指标").font(.caption.bold())
                    Text(model.snapshot.running ? "采集中" : "未采集 · 等待开始")
                    Text(String(format:"FPS 采集 %.1f / 分析 %.1f / 绘制 %.1f",s.captureFPS,s.analysisFPS,s.renderMetrics.fps))
                    Text(String(format:"ms 深度 %.1f / 地面 %.1f / 净空 %.1f / GPU %.1f",result?.stageMilliseconds["depth"] ?? 0,result?.stageMilliseconds["groundFit"] ?? 0,result?.stageMilliseconds["gridClearance"] ?? 0,s.renderMetrics.gpuMS))
                    Text("追踪：\(s.frame?.tracking ?? "未运行") · 热状态：\(s.thermal)")
                    if let result {
                        Text(String(format:"有效深度 %.0f%% · 源帧年龄 %.0f ms",result.validDepthCoverage*100,max(0,ProcessInfo.processInfo.systemUptime-result.timestamp)*1000))
                        Text("最近分析（可能过期）：\(result.status)").lineLimit(2)
                    } else { Text("等待分析") }
                    Text(String(format:"路径宽 %.2f m · 触发区 %.1f × %.2f m",model.pathOptions.minimumWidth,model.pathOptions.obstacleTriggerDistance,model.pathOptions.obstacleTriggerWidth))
                    if let strategy = s.pathUpdate.strategy {
                        Text("route \(strategy.mode.rawValue) · side \(strategy.side) · dwell \(String(format:"%.1f",strategy.turnDwell)) s")
                    }
                    if let c = s.pathUpdate.continuity {
                        Text("route \(c.status.rawValue) · map \(c.sourceMapVersion) · v\(c.geometryVersion)")
                        Text(String(format:"规划 %.2f m · 已验 %.2f m · 宽 %.2f m",c.plannedLength ?? 0,c.remainingVerifiedLength,c.requiredWidth))
                    }
                    if let filter = s.pathUpdate.occupancyFilter {
                        Text("route occupancy · pending \(filter.pendingCells) · confirmed \(filter.confirmedCells) · 300 ms")
                    }
                    Text("DIAG \(model.diagnosticStatus.bytesWritten/1024) KB · 丢弃 \(model.diagnosticStatus.droppedTotal)")
                    if let error = model.diagnosticStatus.error { Text(error).foregroundStyle(.orange) }
                }
                .accessibilityIdentifier("homeDemoMetrics")
                .padding(10).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
            }
            if showTechnicalOverlay && model.options.showLegends {
                VStack(alignment:.leading,spacing:4) {
                    if !model.capabilities.world {
                        Text("当前设备无世界追踪；仅显示界面，不提供实测空间数据")
                    } else if !model.snapshot.running {
                        Text("未采集；无当前传感器数据")
                    } else {
                        Text(model.snapshot.usesMonocular ? "来源：Core ML 预测＋原生尺度校准（非LiDAR实测）" : "来源：ARKit LiDAR")
                    }
                    if !model.options.showCameraImage { Text("RGB画面已隐藏；采集状态见主按钮") }
                    if model.options.showOverlays {
                        Text("蓝：地面 · 红：障碍范围")
                        if model.options.showPath { Text("黄线：占用规划 · 淡蓝虚线：远向投影 · 圈：局部前沿") }
                    }
                    if model.options.layer == .depth || model.options.overlayDepth {
                        LinearGradient(colors:[.red,.yellow,.cyan,.blue],startPoint:.leading,endPoint:.trailing).frame(height:6)
                        if model.snapshot.usesMonocular && model.snapshot.activeMonocular?.observation == nil {
                            Text("未校准相对深度：仅远近色阶，不提供米制距离")
                        } else { Text(String(format:"深度色标：红 0 m → 蓝 %.1f m",model.options.heatMax)) }
                    }
                    if model.options.layer == .confidence { Text("置信度：低＝红 · 中＝黄 · 高＝青；无效/缺失＝灰，无LiDAR无传感器置信度") }
                }
                .accessibilityIdentifier("homeDemoLegend")
                .padding(10).background(.black.opacity(0.65),in:RoundedRectangle(cornerRadius:12))
            }
        }
        .font(.system(.caption2,design:.monospaced))
        .foregroundStyle(.white)
        .frame(maxWidth:.infinity,alignment:.leading)
    }
}

#endif
