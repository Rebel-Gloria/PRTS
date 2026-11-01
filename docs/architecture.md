# 工程架构

PRTS 将相机采集、空间计算、界面渲染和用户反馈分开管理。避障使用同一条数据处理流程；拍照描述复用当前帧，文字识别则协调切换到后置主摄。

## 模块职责

| 目录 | 职责 |
|---|---|
| `PRTS/App/` | 启动、运行配置、Siri 与快捷指令 |
| `PRTS/Features/Home/`、`Settings/` | 首页组合、交互协调和通用设置 |
| `PRTS/Features/Guidance/` | 避障入口、相机状态、语音和振动反馈 |
| `PRTS/Features/PhotoDescription/` | 照片交互、模型服务、请求编码、流式解析和提示词 |
| `PRTS/Features/TextReading/` | 文字识别流程、独立主摄、识别服务和阅读界面 |
| `PRTS/Features/Developer/` | 开发叠加层、诊断设置和演示选项 |
| `PRTS/Shared/` | 共享音频、外观和本地化能力 |
| `PRTS/Spatial/Runtime/` | 唯一 ARSession、帧调度和共享状态 |
| `PRTS/Spatial/Capture/`、`Depth/` | 帧与网格快照、单目深度实现 |
| `PRTS/Spatial/Rendering/` | 从快照绘制相机与空间信息 |
| `PRTS/Spatial/Diagnostics/`、`DevCapture/` | 自动诊断、手动样本和开发录像 |
| `PRTS/Spatial/Models/` | 深度模型、来源与许可证 |
| `Packages/SpatialCore/` | 自有几何分析、障碍建模、路线规划与反馈策略 |
| `Packages/LocalVLM/` | 自有本地视觉模型封装及依赖准备 |
| `Vendor/PRTSCore/` | 保留来源与原有风格的上游契约和可选实现 |
| `Experiments/`、`scripts/` | 独立实验、回放、验证与维护工具 |

App 链接 `SpatialCore`、`LocalVLM` 和 `PRTSContracts`。`PRTSAppleModels`、`PRTSAppleModelsLite` 及实验工程不参与 App 编译。


## 替换组件

`ContentView` 负责组合首页和协调功能生命周期，展示部件分别位于首页、避障、照片和文字识别目录。替换控件时保留输入、回调和无障碍标识，避免同时改动业务流程。

照片交互通过 `PhotoDescriptionServices`、`PhotoRecognizing` 和 `PhotoAnswerAudio` 获取能力。`PhotoDescriptionBackend` 集中选择本地或云端模型；请求、服务配置和流式解析分别维护。替换模型实现时保留异步返回与取消约定，协调器无需了解网络或推理细节。文字识别复用照片服务中的模型与凭据实现，不复制一套连接逻辑。

`SpatialCore/Sources/SpatialCore/` 按 `Perception`、`Routing`、`Presentation`、`Feedback`、`Diagnostics` 和 `Contracts` 分组。`Routing` 再区分前向规划、目标点规划、几何检查、时序连续性和预测入口。对外继续使用 `PathPredictor`、`PathUpdate` 与发布结果；替换搜索策略时保留这些契约，采集、渲染和播报不应跟随算法内部结构变化。

文件按职责拆分，相关的小型数据类型可以放在一起。状态所有者及其私有状态保留在同一文件，避免为了缩短文件而扩大访问权限。

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

`SpatialCore` 不依赖 SwiftUI、ARKit、Metal、AVFoundation、Core ML 或 UIKit。包内 `AppendFile.swift` 仅兼容旧测试，App 不调用。源码一致性检查忽略排版和注释，保留算法表达式与字符串比较。`SpatialAnalyzer` 与冻结的 SpatialProbe 实现保持一致；`AnalysisResult` 仅排除额外的 `planningObstacles` 字段。产品触觉策略既有的进入阈值差异单独检查，不将整个文件排除。

## 依赖来源

`Vendor/PRTSCore` 来自 `https://github.com/Oldcucumber/PRTS_Core.git`，固定提交为 `0469479b0d6775940b7e50d95b2095fb7d7fedeb`，核对日期为 2026-09-24。App 仅链接其中的 `PRTSContracts`，现有业务代码没有调用该契约，主要功能不依赖它。

保留内容包括契约与测试、部分 Apple 端实现、BGRA 适配和提示音；未引入网页端、Python 运行时、视频、模型权重或 XCFramework。缺少 `Artifacts/prts_vlm.xcframework` 时，可选实现使用 `PRTSAppleModelsLite` 并返回模型不可用。

更新依赖前审查候选版本，再同步修改 `scripts/sync-prts-core.sh` 的固定提交和本文记录，运行相关测试。脚本只同步选定源码和测试，不复制模型。本地视觉模型依赖见[本地视觉模型](features/local-vlm.md)。

几何细节见[空间几何](architecture/spatial-geometry.md)，设备差异见[无 LiDAR 模式](features/no-lidar.md)，日志字段见[诊断与采集](diagnostics.md)。
