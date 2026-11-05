# 工程架构

本文介绍 PRTS 的代码组织、避障数据流、路线与反馈规则，以及修改代码时需要遵守的约束。

PRTS 由一个 SwiftUI 应用和两个本地 Swift 包组成。避障算法位于 `Packages/SpatialCore`，该包不依赖 ARKit、UIKit 或 SwiftUI，可在 macOS 上独立测试和回放。应用层负责数据采集、画面渲染和语音振动反馈。

## 目录结构

| 路径 | 职责 | 入口类型 |
|---|---|---|
| `PRTS/App/` | 应用入口和快捷指令 | `PRTSApp`、`ToggleGuidanceIntent`、`HomeCommandCenter` |
| `PRTS/Features/Home/` | 首页界面；同时协调各功能的生命周期，并轮询避障反馈 | `ContentView` |
| `PRTS/Features/Guidance/` | 避障相机的运行意图，语音和振动反馈 | `CameraManager`、`FeedbackCoordinator`、`SpeechManager`、`PathHaptics` |
| `PRTS/Spatial/` | ARKit 会话、帧快照、渲染和诊断记录 | `ProbeEngine`、`ProbeViewModel`、`ProbeRenderer` |
| `PRTS/Features/PhotoDescription/` | 拍照描述和语音提问。模型后端在 `Services/PhotoDescriptionBackend.swift` 中选择，提示词在 `Services/PhotoPrompts.swift` 中 | `PhotoDescriptionCoordinator` |
| `PRTS/Features/LiveCaption/` | 流式字幕：采样、请求和朗读；同时负责拍照按键的连按判定 | `LiveCaptionSession` |
| `PRTS/Features/TextReading/` | 读文字：主摄拍照、识别和朗读 | `TextReadingSession` |
| `PRTS/Features/Settings/` | 设置、智能服务设置和使用说明 | `SettingsView`、`IntelligenceSettingsView` |
| `PRTS/Features/Developer/` | 开发版专用界面 | `ProbeSettingsView` |
| `PRTS/Shared/Intelligence/` | 模型服务的公共实现：请求协议、流式解析、服务配置、钥匙串凭据和本机模型路径 | `PhotoChatService`、`IntelligenceFeature` |
| `PRTS/Shared/Imaging/` | 照片缩放与 JPEG 编码 | `PhotoImageEncoder` |
| `PRTS/Shared/Audio/` | 音频会话、回答朗读、提示音和语音识别 | `AudioSessionCoordinator`、`AnswerAudioOutput`、`PhotoSpeechRecognizer` |
| `PRTS/Shared/Input/` | 拍照按键的状态判定、实体按键和交互偏好 | `PhotoPressState`、`PhotoHardwareButtons`、`InteractionPreferences` |
| `PRTS/Shared/Diagnostics/` | 产品错误日志 | `ErrorLog`、`ErrorReporter` |
| `Packages/SpatialCore/` | 地面与障碍分析（`Perception/`）、路线规划（`Routing/`）、播报与振动策略（`Feedback/`） | `SpatialAnalyzer`、`PathPredictor` |
| `Packages/LocalVLM/` | llama.cpp 封装，在设备上运行 MiniCPM-V | `LocalVLM` |
| `Vendor/PRTSCore/` | 上游契约代码。应用不链接此包，只运行其契约测试 | — |
| `Experiments/` | 实验工程和回放工具，不参与应用编译 | — |

`PRTS/Spatial/` 中以 `Probe` 开头的类型是应用实际运行的代码。`Experiments/SpatialProbe/` 中有同名类型，它们是冻结的对照实现，只用于一致性检查和回放。

## 应用装配

```text
PRTSApp
  ├─ SpeechManager、HapticManager（环境对象）
  └─ ContentView
       ├─ CameraManager → ProbeViewModel → ProbeEngine → ARSession
       ├─ PhotoDescriptionCoordinator
       ├─ LiveCaptionSession
       ├─ TextReadingSession → TextCamera（AVCaptureSession）
       └─ FeedbackCoordinator

ToggleGuidanceIntent → HomeCommandCenter.startRequested → ContentView.runPendingCommand
```

`ContentView` 持有各功能的协调对象，并负责它们之间的交接：打开设置、进入后台、音频中断和离开首页时停止字幕、描述和读文字；读文字开始和结束时交出、收回相机。快捷指令只设置 `HomeCommandCenter` 中的请求标志，应用回到前台后由 `ContentView` 启动避障。

## 避障数据流

进入分析的帧按以下顺序处理：

```text
ARSession
  → ProbeEngine：生成 FrameSnapshot
  → SpatialAnalyzer：生成地面、障碍、未知三态栅格
  → PathPredictor
      → TemporalOccupancyGrid：确认持续 300 ms 以上的障碍
      → ObstacleWaypointPlanner：选择目标点并搜索路线
  → RoutePublicationPolicy：确定发布的路线状态
  → SharedStore
```

`FrameSnapshot` 持有该帧的 `ARFrame`，以及时间戳、epoch、frameID、相机位姿和内参；LiDAR 设备的深度图和置信度从 `ARFrame` 读取，无 LiDAR 设备由深度模型估计。

路线规划仅将已确认的障碍视为阻挡，未知栅格允许通过。

> [!NOTE]
> “没有已确认障碍”不等同于“已确认安全”。地面或深度短暂缺失时，系统保留现有路线，而不是立即撤销。

### 运行调度

采集、分析、反馈和渲染分别在不同的队列或时钟上运行，通过 `SharedStore` 交换数据：

| 位置 | 触发 | 工作 |
|---|---|---|
| `probe.session` 队列 | ARKit 帧回调 | 生成 `FrameSnapshot`，放入 `LatestMailbox`。会话的启动和停止也在此队列上按请求顺序执行 |
| `probe.analysis` 队列 | 信箱中有新帧 | `drainAnalysis` 运行上图的分析和规划，将每个候选结果写入 DIAG 日志，只把通过时效检查的结果写入 `SharedStore` |
| `probe.mesh` 队列 | ARKit 网格锚点更新 | 经 `MeshInbox` 合并后写入 `SharedStore.meshes`，分析时作为先验读取 |
| 主线程，每 0.1 s | `ContentView` 中的定时器 | `CameraManager.poll` → `ProbeViewModel.poll` 读取快照，由 `PathHaptics` 输出方向振动，每 1 s 写一次 DIAG 心跳；随后 `ContentView` 把结果交给 `FeedbackCoordinator`，由 `SpeechManager` 播报 |
| 主线程，每秒 30 次 | `MTKView` 绘制回调 | `ProbeRenderer` 读取 `SharedStore` 绘制画面 |

`LatestMailbox` 只保留最新一帧，分析未完成时到达的旧帧会被丢弃，丢弃数量记录在 DIAG 中。语音和振动在同一次轮询中使用同一个暂停条件：拍照操作、读文字、流式字幕、设置页、停止手势、低视力模式或使用说明、应用不在前台，任一成立时两者都暂停。

## 路线状态

系统根据前方最近的已确认障碍，将路线分为三种状态：

| 状态 | 路线行为 | 语音播报 |
|---|---|---|
| 前方无已确认障碍 | 不绘制路线 | 进入该状态时播报“前方畅通” |
| 障碍距离大于 2 m | 在障碍前 0.55 m 处设置接近目标 | “有障碍” |
| 障碍距离在 2 m 以内 | 逐点绕行 | 障碍状态和转向；距离很近时播报“障碍很近” |

状态切换设有迟滞，以避免在阈值附近反复切换：

- 进入近距离状态后，障碍距离超过 2.15 m 才会返回远距离状态。
- 从近距离状态切换到远距离状态需持续 0.75 s；切换到无障碍状态需持续 0.6 s。

## 目标点与路线更新

同一时刻只有一个当前目标点用于显示、播报和振动。

1. 与当前目标点的距离小于 1.2 m 时，系统开始准备下一段路线，每 0.25 s 更新一次。
2. 与当前目标点的距离小于 0.35 m 时，系统复核下一段路线。复核通过则整体切换，否则重新搜索。
3. 目标点超出画面边缘 4% 以内时保留；超出 25% 或位于用户身后时立即重新选择。

绕行时优先在两侧各增加 8 cm 余量；无法满足时，使用 0.50 m 的规划总宽。

已确认障碍以世界坐标中的完整栅格方块保存（`OccupancyFootprint`）。路线搜索、路线扫掠和已提交路线的复核使用同一组障碍，包括规划窗口以外的障碍，因此栅格旋转或裁切不会丢失障碍面积。

发生跟踪丢失、epoch 变化或参数变化时，之前的结果全部失效，较晚返回的旧结果不会覆盖新结果。规划参数定义在 `ObstacleWaypointState.swift` 和 `PathOptions.swift` 中。

> [!NOTE]
> 规划总宽为 0.50 m，而身体宽度参数为 0.60 m，二者目前不一致。相关回放数据请参阅[验证结果](validation.md)。

## 播报频率

`ObstacleRouteAnnouncementPolicy` 按以下规则控制播报频率：

| 规则 | 取值 |
|---|---|
| 两次播报的最短间隔 | 2.5 s |
| 场景变化后的稳定时间 | 0.6 s |
| 远近等级变化的最短重播间隔 | 4 s |
| 同侧目标点变化 | 不重复播报 |

无法绕行时播报“有障碍，无法绕行”；没有可用深度时播报“暂时看不清”。

### 启动播报

用户开始避障后，第一句播报“初始化中”，0.5 s 后再按当前状态播报第一条路线提示。该等待用于避免障碍确认完成前播报“前方畅通”，且不占用 2.5 s 的播报间隔。

拍照描述、读文字、流式字幕或设置结束后恢复反馈时，以及会话重新建立时，应用同样等待 0.5 s，但不再播报“初始化中”。

## 相机交接

避障使用 `ProbeEngine` 中的 `ARSession`，读文字使用 `TextCamera` 中独立的 `AVCaptureSession`，两者不同时运行。`CameraManager` 保存用户是否要运行避障（运行意图），交接规则如下：

| 事件 | 处理 | 负责类型 |
|---|---|---|
| 点按开始 | 设置运行意图，请求相机权限后启动会话 | `CameraManager` |
| 停止避障 | 清除运行意图，取消尚未完成的权限请求，立即暂停反馈 | `CameraManager` |
| 开始读文字 | 停止字幕和描述；`pauseForTextReading(completion:)` 暂停会话但保留运行意图，会话停止后 `TextReadingSession` 才打开主摄 | `ContentView`、`CameraManager` |
| 读文字结束、失败或取消 | 主摄停止后，`finishTextReading(isActive:)` 解除占用；在前台时立即恢复已启动的避障，在后台时等到回到前台 | `TextReadingSession`、`CameraManager` |
| 用户取消读文字 | 播报取消提示，读完后释放音频会话 | `TextReadingSession` |
| 进入后台、音频中断、打开设置、离开首页 | 字幕、描述和读文字静默结束；进入后台时暂停会话并取消尚未完成的权限请求，保留运行意图 | `ContentView`、`CameraManager` |
| 回到前台 | 仅恢复用户已启动、且未被读文字占用的会话 | `CameraManager` |
| 快捷指令开始 | 不停止正在运行的相机；读文字期间退出读文字，并恢复之前的相机状态 | `ContentView` |
| 低视力模式、首次使用说明 | 暂停避障反馈，不关闭相机，不禁用描述、提问或读文字 | `ContentView` |

停止之后，较晚到达的权限结果和读文字结束回调都不会重新启动相机。

设置中开启“点按停止”，或系统已识别到辅助触控、切换控制时，主按钮改为点按停止，不使用长按停止手势。

> [!NOTE]
> `UIAccessibility.isAssistiveTouchRunning` 仅在启用引导式访问时保证返回正确状态，因此普通辅助触控用户需要在设置中开启“点按停止”。

## 拍照按键

屏幕拍照按钮和音量键都先经过流式字幕的连按判定，再交给对应功能：

```text
ContentView.photoDown
  → LiveCaptionSession.down → LiveCaptionPressState
      ├─ .photo：PhotoDescriptionCoordinator.perform（短按描述，按住提问）
      ├─ .start：连按三下，停止描述并开启流式字幕
      └─ .stop：字幕运行中按下，退出流式字幕
```

时间阈值和提示音请参阅[功能与操作](usage.md)。

## 设计约束

修改代码时，请遵守以下约束。“自动检查”列中的脚本位于 `scripts/`，Swift 测试位于 `PRTSTests/`。

| 约束 | 自动检查 |
|---|---|
| 仅 `ProbeEngine` 创建 `ARSession` | `test_repository_layout.py` |
| 拍照描述和流式字幕读取当前帧；读文字先停止 ARKit 会话、切换到主摄，退出后恢复之前的状态 | `CameraRecoveryTests` 覆盖启停顺序、迟到的相机授权、读文字结束、中断、显式停止和从空闲状态开始的恢复 |
| `SpatialCore` 不得导入 ARKit、UIKit、SwiftUI、AVFoundation、Metal 或 Core ML | `test_repository_layout.py` |
| `SpatialAnalyzer` 与 `Experiments/SpatialProbe` 中冻结的对照实现保持一致，比较时忽略格式和注释 | `test_spatial_integration.py` |
| 渲染器仅读取 `SharedSnapshot`，语音和振动仅读取分析结果。隐藏画面不影响分析；如需停止绘制，请使用无画面模式 | `test_spatial_integration.py`，部分覆盖 |
| 所有异步请求必须处理取消。停止避障、进入后台或来电后，较晚返回的结果不得更新界面或触发播报 | `TextReadingSessionTests`、`LiveCaptionSessionTests`、`test_stability_boundaries.py`，部分覆盖 |

应用内的语音和录音通过 `AudioSessionCoordinator` 激活音频会话。每次激活返回一个租约，只有持有最新租约的一方才能关闭会话，因此旧朗读结束时不会打断新的输出。

相机画面和避障反馈轮询都在主线程上运行，耗时的音频操作不得在主线程上等待：

| 操作 | 执行位置 | 说明 |
|---|---|---|
| 关闭音频会话 | 独立串行队列，延迟 0.25 s | 下一次激活会取消等待中的关闭 |
| 提示音和开始录音 | `activateAsync`，在独立队列上激活 | 调用方在等待后检查是否已取消；松手时先等麦克风启动完成，再停止录音 |
| 朗读 | 同一队列，主线程同步等待 | 通常约 15 ms；如果关闭操作正在执行，需要等它结束 |

`Packages/SpatialCore/Sources/SpatialCore/Diagnostics/AppendFile.swift` 为 `SessionRecorder` 和 `DiagnosticJournal` 提供追加写入接口，重新打开文件时保留已有记录。

## 第三方代码

`Vendor/PRTSCore` 来自 [Oldcucumber/PRTS_Core](https://github.com/Oldcucumber/PRTS_Core)，固定在提交 `0469479b`（2026-09-24 核对）。应用不链接此包。同步范围包括契约、测试、部分 Apple 平台实现和提示音，不包括网页端、Python 运行时和模型文件。

如需升级 `Vendor/PRTSCore`，请执行以下步骤：

1. 审查上游候选版本，然后将 `scripts/sync-prts-core.sh` 中的 `revision` 改为该版本的完整提交哈希。
2. 运行该脚本同步源码。
3. 运行契约测试：`PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore`。
4. 更新本节记录的提交和核对日期。

llama.cpp 和 MiniCPM-V 由 `Packages/LocalVLM/prepare.sh` 下载并编译，不纳入版本控制。版本信息请参阅[图像与文字识别](vision.md#本地视觉模型)。

## 相关文档

- [空间感知](spatial.md)：坐标约定、地面确认、栅格和无 LiDAR 模式
- [图像与文字识别](vision.md)：拍照描述、语音提问、流式字幕和文字识别
- [开发指南](development.md)：构建、测试、诊断记录和回放工具
