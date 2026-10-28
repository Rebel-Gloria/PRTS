# 运行时数据流

一帧画面从 ARKit 进来，到用户听到播报、感到震动，中间经过这几步：

```text
ARSession
  → ProbeEngine：生成 FrameSnapshot，限长邮箱
  → SpatialAnalyzer：三态栅格（地面 / 障碍 / 未知）
  → PathPredictor：检查 epoch 和帧顺序，记录障碍水位
    → TemporalOccupancyGrid：障碍持续 300 ms 才确认，消失后移出
    → ObstacleWaypointPlanner：判断场景，选当前目标点，准备下一个点
      → ObstacleWaypointSearch → ForwardObstacleTrigger、GreedyDetourSearch / ForwardPathSearch / FanPathSearch
  → RoutePublicationPolicy：整体提交，区分"空旷"和"候选还没算好"
  → SharedSnapshot
    ├─ ProbeRenderer：只画当前这一段
    ├─ FeedbackCoordinator → ObstacleRouteAnnouncementPolicy（语音）、PathHaptics（方向震动）
    └─ DiagnosticRecorder：DIAG 记录
```

## 采集

`ProbeEngine` 从每个 `ARFrame` 生成 `FrameSnapshot`：帧号、epoch、时间戳、跟踪状态、相机位姿、内参、是否有深度和置信度、网格。邮箱只保留一帧正在处理的和一帧最新的，旧的直接丢掉，所以分析永远不会越积越多。

## 分析和规划

分析得到三态栅格。规划不直接用它，而是用一份私有副本：只有持续 300 ms 的确认障碍会挡路，其余格子（包括未知）都可以走。地面或深度短暂缺失不会撤掉路线。

`ObstacleWaypointPlanner` 把情况分成三种：

| 情况 | 路线 | 播报 |
|---|---|---|
| 前方通行带里没有确认障碍 | 不画线 | 进入时说一次"前方畅通" |
| 障碍在 2 m 以外 | 在障碍前 0.55 m 设一个停靠点 | "有障碍" |
| 障碍在 2 m 以内 | 逐点绕行 | "有障碍"或"障碍很近"，加转向 |

- "前方"指沿当前方向、和身体一样宽（默认 0.5 m）的一条带子。距离是沿这条带子量到障碍近边的地面距离。
- 进入近障后，距离回到 2.15 m 以上才算远障，避免在 2 m 附近来回切换。
- 只有当前目标点和它的路线会被画出来、播报和震动；下一个点只用来提前准备（离当前点 1.2 m 内开始），到达当前点（0.35 m 内）时复核一遍再整体换上。
- 三种情况会重新规划：用户原地转向 45° 以上并稳定 3 秒；当前目标离开画面；当前路线被确认障碍挡住。
- 跟踪丢失、epoch 变化、参数变化时作废旧结果，迟到的异步结果不会覆盖新的。

具体参数在 `ObstacleWaypointState.swift` 的 `ObstacleWaypointOptions` 里。

## 显示和反馈

主线程读 `SharedSnapshot`。渲染器把画面、深度和世界坐标里的叠加层投到同一个矩形里；开发版的 `HomeDemoOverlay` 只显示快照里已有的数值，不触发分析，不开定时器。

`FeedbackCoordinator` 给播报和震动限频。避障播报规则见 [文案规范](../features/copy-guidelines.md)。拍照回答和设置页播报各自管理取消，互不打断。

## 诊断

自动记录启动信息，采集、分析、渲染、路线、网格事件，以及压缩后的深度、置信度和网格。默认不存画面、视频、音频和位置。丢帧数、队列高水位、结果延迟、发热状态和各阶段耗时都会记下来。格式见 [开发采集](../guides/dev-capture.md)。
