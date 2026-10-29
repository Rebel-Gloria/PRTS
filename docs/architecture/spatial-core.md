# SpatialCore

`Vendor/SpatialCore` 是纯 Swift 的空间算法包：从深度数据里找地面、建障碍栅格、规划避障路线，输出给 App 播报和震动用的结果。App 和 `Experiments/SpatialProbe` 共用它。

## 管什么，不管什么

管：

- 检查深度观测，投影到三维；
- 估计局部地面；
- 三态栅格（地面、障碍、未知）和身体宽度的通行检查；
- 地面和障碍的表面模型；
- 避障路线规划，以及播报和震动策略的输入；
- 诊断和重放测试要用的 Codable 数据结构。

不管：不 import SwiftUI、ARKit、Metal、AVFoundation、Core ML 或 UIKit；不开相机、不画图、不出声、不震动、不写文件。

包测试用的是合成数据，测试通过不等于真机上 LiDAR 表现没问题。

## 来源

2026-09-25 从当时的验证工程（`PRTSTEST/Core`）复制了 `Analysis`、`Depth`、`Geometry`、`Grid`、`Ground` 几个算法文件和它的 25 个测试。录制、导出、诊断 UI 和渲染没有复制。`AppendFile.swift` 只是为了让原测试能跑，App 不调用它。PRTS 自己加了 `SceneContracts.swift` 和 `FeedbackPolicy.swift`。

之后的主要演变：

| 时间 | 加了什么 |
|---|---|
| 2026-09-29 | 正前方优先的路线规划（`ForwardRoutePlanner` 和 `Forward*` 系列）；`PathObstacleCheck` 用当前深度否决路线 |
| 2026-09-29 | `RoutePlanningGrid`：规划用当前测到的地面，不依赖渲染出的三角面 |
| 2026-09-29 | `RouteProjection`：只用于显示的平面延长线 |
| build 14 | `TemporalOccupancyGrid`：障碍在世界坐标里持续 300 ms 才确认；`GreedyDetourSearch` |
| build 17 | 路线只被确认的障碍否决，未知区域不再挡路 |
| build 24 | `ObstacleWaypointPlanner`：三态避障（空旷、远障、近障）和逐点交接 |
| build 25 | `OccupancyFootprint` 把当前测到的障碍格和时间关联点分开；`WaypointTransitionState` 给状态切换加迟滞 |
| 2026-10-29 | 第三轮审查的改动（地面更新、反馈新鲜度门、震动 12° 门、路线圆角、身体宽度硬约束）和障碍地图记忆合进来后误报严重，当天全部撤回，算法回到 build 25 |

`SpatialAnalyzer` 和冻结的实验版保持逐字节一致，有一致性测试保证；`AnalysisResult` 里只多了一个规划用的 `planningObstacles` 字段，对比时去掉这个字段。原来复制时记录的 SHA-256 只对应 2026-09-25 的版本，需要时翻 git 历史。
