# 工程架构

PRTS 将相机采集、空间计算、界面渲染和用户反馈分开管理。避障使用同一条数据处理流程；拍照描述复用当前帧，文字识别则协调切换到后置主摄。

## 模块职责

| 目录 | 职责 |
|---|---|
| `PRTS/App/` | 启动、运行配置、Siri 与快捷指令 |
| `PRTS/UI/`、`PRTS/Capture/` | 界面、设置、相机适配和预览 |
| `PRTS/Spatial/Runtime/` | 唯一 ARSession、帧调度、快照和单目深度 |
| `PRTS/Spatial/Rendering/` | 从快照绘制相机与空间信息 |
| `PRTS/Feedback/` | 语音播报与方向振动 |
| `PRTS/PhotoDescription/`、`PRTS/TextReading/` | 画面描述、语音提问、文字识别及朗读 |
| `PRTS/Spatial/Diagnostics/`、`PRTS/Spatial/DevCapture/` | 自动诊断、手动样本和开发录像 |
| `PRTS/Spatial/Models/` | 深度模型、来源与许可证 |
| `PRTS/Integration/` | 预留检测接口，当前避障不依赖该层 |
| `Vendor/SpatialCore/` | 纯 Swift 几何分析、障碍建模和路线规划 |
| `Vendor/LocalVLM/` | 本地视觉模型封装及依赖准备 |
| `Vendor/PRTSCore/` | 旧后端契约与可选实现 |
| `Experiments/`、`scripts/` | 独立实验、回放、验证与维护工具 |

App 链接 `SpatialCore`、`LocalVLM` 和 `PRTSContracts`。`PRTSAppleModels`、`PRTSAppleModelsLite` 及实验工程不参与 App 编译。

## 避障数据流

```text
ARSession
  → ProbeEngine / FrameSnapshot：采集与调度
  → SpatialAnalyzer：地面、障碍和未知栅格
  → PathPredictor：会话与时序检查
    → TemporalOccupancyGrid：持续障碍确认
    → ObstacleWaypointPlanner：目标与路线搜索
  → RoutePublicationPolicy：整体发布路线状态
  → SharedSnapshot
    ├─ ProbeRenderer：画面
    ├─ FeedbackCoordinator：语音与振动
    └─ DiagnosticRecorder：诊断
```

`ProbeEngine` 将同一帧的时间戳、epoch、frameID、跟踪状态、位姿、内参及可用的深度、置信度、网格打包为 `FrameSnapshot`。队列只保留一帧正在分析的数据和一帧最新待处理数据，新帧替换尚未处理的旧帧。

`SpatialAnalyzer` 生成地面、障碍、未知三态栅格。规划使用独立副本，只把持续至少 300 ms 的确认障碍作为阻挡，未知格仍允许搜索。地面或深度短暂缺失不会立即撤销路线，因此“没有确认障碍”不能等同于已经确认安全。

## 路线与反馈

| 状态 | 路线行为 | 主要播报 |
|---|---|---|
| 前方通行带无确认障碍 | 不绘制路线 | 进入状态时播报“前方畅通” |
| 障碍超过 2 m | 在障碍前 0.55 m 设置接近目标 | “有障碍” |
| 障碍在 2 m 以内 | 逐点绕行 | 障碍状态与转向；距离小于 1 m 时可播报“障碍很近” |

进入近障后，距离回到 2.15 m 以上才考虑切回远障；近障退为远障需持续 0.75 s，转为空旷需持续 0.6 s。当前规划总宽为 0.50 m，身体宽度参数为 0.60 m，两者不一致的问题见[验证结果](validation.md)。

只有当前目标用于显示、播报和振动。距离目标 1.2 m 内开始准备下一目标，约每 250 ms 更新；进入 0.35 m 范围后复核下一段，再整体切换。绕行优先选择画面中的拐点，没有可见目标时提示“有障碍，转动手机”。

原地转向超过 45° 并稳定 3 s、目标离开画面或路线被确认障碍挡住时重新规划。画面边缘外 4% 以内的目标允许保留 0.35 s；超出 25% 或位于身后时立即处理。已开始绕行时保持当前目标，不因另一个更远障碍成为最近障碍而退回接近状态。绕行优先每侧多留 8 cm，必要时退回 0.50 m 总宽。

`OccupancyFootprint` 保存确认障碍格的完整世界坐标方块，时间关联点仅用于计时。搜索、路线扫掠、停靠间距和已提交路线检查使用同一组障碍，包含规划窗口外的障碍，避免旋转或裁切栅格时丢失障碍面积。

跟踪丢失、epoch 或参数变化会使旧结果失效。`RoutePublicationPolicy` 区分前方空旷与路线未就绪，迟到结果不得覆盖新结果。核心参数见 `ObstacleWaypointState.swift`。

`FeedbackCoordinator` 使用发布结果控制反馈频率。同侧目标 ID 变化不重复播报；最短间隔为 2.5 s，场景变化需稳定 0.6 s，距离或远近等级变化的重播间隔为 4 s。无法绕行时播报“有障碍，无法绕行”，感知不可用时播报“暂时看不清”。

## 会话与显示边界

只有 `ProbeEngine` 持有 ARSession。拍照描述读取当前帧；文字识别先停止 ARKit，再使用主摄会话，退出后按进入前状态恢复。异步请求均需处理取消与过期结果。

渲染器只读取 `SharedSnapshot`，语音和振动只使用分析结果。开发叠加层不另建会话或计时器。隐藏画面不停止采集和分析；完全停止绘制应使用无画面模式。

`SpatialCore` 不依赖 SwiftUI、ARKit、Metal、AVFoundation、Core ML 或 UIKit。包内 `AppendFile.swift` 仅兼容旧测试，App 不调用。`SpatialAnalyzer` 与冻结的 SpatialProbe 实现保持逐字节一致；`AnalysisResult` 比较时排除额外的 `planningObstacles` 字段。

## 依赖来源

`Vendor/PRTSCore` 来自 `https://github.com/Oldcucumber/PRTS_Core.git`，固定提交为 `0469479b0d6775940b7e50d95b2095fb7d7fedeb`，核对日期为 2026-09-24。App 仅链接其中的 `PRTSContracts`，现有业务代码没有调用该契约，主要功能不依赖它。

保留内容包括契约与测试、部分 Apple 端实现、BGRA 适配和提示音；未引入网页端、Python 运行时、视频、模型权重或 XCFramework。缺少 `Artifacts/prts_vlm.xcframework` 时，可选实现使用 `PRTSAppleModelsLite` 并返回模型不可用。

更新依赖前审查候选版本，再同步修改 `scripts/sync-prts-core.sh` 的固定提交和本文记录，运行相关测试。脚本只同步选定源码和测试，不复制模型。本地视觉模型依赖见[本地视觉模型](features/local-vlm.md)。

几何细节见[空间几何](architecture/spatial-geometry.md)，设备差异见[无 LiDAR 模式](features/no-lidar.md)，日志字段见[诊断与采集](diagnostics.md)。
