# 工程架构

本文介绍 PRTS 的代码组织、避障数据流、路线与反馈规则，以及修改代码时需要遵守的约束。

PRTS 由一个 SwiftUI 应用和两个本地 Swift 包组成。避障算法位于 `Packages/SpatialCore`，该包不依赖 ARKit、UIKit 或 SwiftUI，可在 macOS 上独立测试和回放。应用层负责数据采集、画面渲染和语音振动反馈。

## 目录结构

| 路径 | 说明 |
|---|---|
| `PRTS/Spatial/` | ARKit 会话（`ProbeEngine`）、帧快照、渲染和诊断记录 |
| `PRTS/Features/Guidance/` | 避障入口、语音和振动反馈 |
| `PRTS/Features/PhotoDescription/` | 拍照描述和语音提问。模型后端在 `Services/PhotoDescriptionBackend.swift` 中选择，提示词定义在 `Services/PhotoPrompts.swift` 中 |
| `PRTS/Features/TextReading/` | 文字识别：主摄拍照、识别和朗读 |
| `PRTS/Features/Home/`、`Settings/`、`Developer/` | 首页、设置和开发版专用界面 |
| `Packages/SpatialCore/` | 地面与障碍分析（`Perception/`）、路线规划（`Routing/`）、播报与振动策略（`Feedback/`） |
| `Packages/LocalVLM/` | llama.cpp 封装，用于在设备上运行 MiniCPM-V |
| `Vendor/PRTSCore/` | 上游契约代码。应用链接此包，但当前未调用 |
| `Experiments/` | 实验工程和回放工具，不参与应用编译 |

## 避障数据流

每一帧 ARKit 数据按以下顺序处理：

```text
ARSession
  → ProbeEngine：生成 FrameSnapshot
  → SpatialAnalyzer：生成地面、障碍、未知三态栅格
  → PathPredictor
      → TemporalOccupancyGrid：确认持续 300 ms 以上的障碍
      → ObstacleWaypointPlanner：选择目标点并搜索路线
  → RoutePublicationPolicy：确定发布的路线状态
  → SharedSnapshot
      ├─ ProbeRenderer：渲染画面
      ├─ FeedbackCoordinator：输出语音和振动
      └─ DiagnosticRecorder：写入 DIAG 日志
```

`FrameSnapshot` 包含时间戳、epoch、frameID、相机位姿和内参，以及该帧的深度图、置信度和网格。分析在串行队列中执行，待处理队列通过 `LatestMailbox` 仅保留最新一帧；分析未完成时到达的旧帧会被丢弃，丢弃数量记录在 DIAG 中。

路线规划仅将已确认的障碍视为阻挡，未知栅格允许通过。

> [!NOTE]
> “没有已确认障碍”不等同于“已确认安全”。地面或深度短暂缺失时，系统保留现有路线，而不是立即撤销。

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

## 设计约束

修改代码时，请遵守以下约束。标注了测试的约束由 `scripts/test_repository_layout.py` 或 `scripts/test_spatial_integration.py` 自动检查。

| 约束 | 自动检查 |
|---|---|
| 仅 `ProbeEngine` 创建 `ARSession`。拍照描述读取当前帧；文字识别先停止 ARKit 会话、切换到主摄，退出后恢复之前的状态 | 是 |
| `SpatialCore` 不得导入 ARKit、UIKit、SwiftUI、AVFoundation、Metal 或 Core ML | 是 |
| `SpatialAnalyzer` 与 `Experiments/SpatialProbe` 中冻结的对照实现保持一致，比较时忽略格式和注释 | 是 |
| 渲染器仅读取 `SharedSnapshot`，语音和振动仅读取分析结果。隐藏画面不影响分析；如需停止绘制，请使用无画面模式 | 部分 |
| 所有异步请求必须处理取消。停止避障、进入后台或来电后，较晚返回的结果不得更新界面或触发播报 | 否 |

`Diagnostics/AppendFile.swift` 仅供旧测试使用，应用不调用该文件。

## 第三方代码

`Vendor/PRTSCore` 来自 [Oldcucumber/PRTS_Core](https://github.com/Oldcucumber/PRTS_Core)，固定在提交 `0469479b`（2026-09-24 核对）。应用仅链接其中的 `PRTSContracts`。同步范围包括契约、测试、部分 Apple 平台实现和提示音，不包括网页端、Python 运行时和模型文件。

如需升级 `Vendor/PRTSCore`，请执行以下步骤：

1. 审查上游候选版本，然后将 `scripts/sync-prts-core.sh` 中的 `revision` 改为该版本的完整提交哈希。
2. 运行该脚本同步源码。
3. 运行契约测试：`PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore`。
4. 更新本节记录的提交和核对日期。

llama.cpp 和 MiniCPM-V 由 `Packages/LocalVLM/prepare.sh` 下载并编译，不纳入版本控制。版本信息请参阅[图像与文字识别](vision.md#本地视觉模型)。

## 相关文档

- [空间感知](spatial.md)：坐标约定、地面确认、栅格和无 LiDAR 模式
- [图像与文字识别](vision.md)：拍照描述、语音提问和文字识别
- [开发指南](development.md)：构建、测试、诊断记录和回放工具
