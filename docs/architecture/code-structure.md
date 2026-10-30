# 代码结构

App 代码在 `PRTS/`，按职责分目录，不按页面分。空间算法在独立的 Swift 包 `Vendor/SpatialCore` 里，它不依赖 UI、ARKit 和 Metal，可以单独测试。

## 目录

```text
PRTS/
├── App/              启动、App Intents（Siri/快捷指令）、运行配置 RuntimeProfile
├── UI/               主页、设置页、拍照按钮、液态玻璃样式、开发版叠加层
├── Capture/          CameraManager（主线程适配层）和 Metal 相机画面
├── Feedback/         语音、震动，以及"分析结果 → 播报/震动"的规则
├── PhotoDescription/ 拍照描述：按键判断、编码、录音识别、请求、钥匙串、朗读
├── TextReading/      文字识别：三指手势、主摄、本机模型的提示词、朗读
├── Integration/      预留给以后的物体检测接口，避障不依赖它
└── Spatial/
    ├── Runtime/      唯一的 ARSession、帧邮箱、分析调度、状态快照、无 LiDAR 深度
    ├── Rendering/    Metal 渲染，只读快照
    ├── Diagnostics/  DIAG 自动记录和手动采样
    ├── DevCapture/   开发版录像，只在 PRTS_DEV_CAPTURE 下编译
    └── Models/       Depth Anything V2 模型及许可、来源说明

Vendor/
├── SpatialCore/      纯 Swift 几何和路线算法，见 spatial-core.md
└── PRTSCore/         旧后端的契约包，见 prts-core-package.md

Experiments/          独立实验：SpatialProbe 验证 App、astra 重放、photo-prompt 评测
scripts/              校验、读 DIAG、重放路线等脚本，见 ../guides/scripts.md
```

几个关键文件：

| 文件 | 做什么 |
|---|---|
| `Spatial/Runtime/ProbeEngine.swift` | 持有唯一的 `ARSession`，限长的处理管线 |
| `Spatial/Runtime/ProbeViewModel.swift` | 给界面用的运行状态，设置项的读写 |
| `Spatial/Runtime/Snapshots.swift` | 帧、分析结果、渲染状态的数据结构 |
| `Spatial/Runtime/MonocularDepthProvider.swift` | 没有 LiDAR 时用 Core ML 估深度 |
| `Feedback/ObstacleRouteAnnouncementPolicy.swift` | 正式版的避障播报：空旷、远障、近障 |
| `Feedback/PathHaptics.swift` | 方向震动 |
| `SpatialCore/PathPrediction.swift` | 路线的对外接口 |
| `SpatialCore/ObstacleWaypointPlanner.swift` | 正式版的三态避障规划 |
| `SpatialCore/ObstacleWaypointSearch.swift` | 停靠点和绕行路线搜索 |
| `SpatialCore/TemporalOccupancyGrid.swift` | 障碍在世界坐标里持续 300 ms 才确认 |

## 规矩

1. 只有 `ProbeEngine` 持有 `ARSession`。别的功能要用相机画面，就读它的当前帧；要换相机（比如文字识别要用主摄单独拍照），先停掉它。
2. 几何判断只放在 `SpatialCore`，并且先写确定性测试。渲染和 UI 里不做几何判断。
3. 渲染只读快照，不决定哪里能走。
4. 语音和震动只读分析结果，不直接读相机数据。
5. 诊断只记录数值和压缩后的空间数据，默认不存画面。
6. 主页隐藏画面或叠加层只影响显示，不能顺带停掉采集和分析。

`scripts/test_spatial_integration.py` 会检查这套目录结构，也会检查叠加层没有另开 `ARSession` 或定时器。

## Xcode 实际链接了什么

App 链接 `SpatialCore` 和 `PRTSContracts`。`PRTSAppleModels`、`PRTSAppleModelsLite` 和 `Experiments/` 都不进 App。所以算代码量时，不能把全部源码行数当成 App 的编译量。各目录的行数见 [代码清单](code-inventory.md)。
