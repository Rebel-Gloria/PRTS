# SpatialProbe 验证 App

`Experiments/SpatialProbe` 是一个独立的 iPhone App，用来先单独验证空间感知：一个 ARSession 加 MetalKit，没有导航，iOS 17 以上。它的算法在 2026-09-28（build 11）合进了主 App，之后作为冻结的对照版本保留：主 App 的 `SpatialAnalyzer` 必须和它逐字节一致。

## 它做过什么

| build | 加了什么 |
|---|---|
| 1–2 | 单 ARSession 读 RGB、深度、置信度、网格；地面拟合、三态栅格、身体净空、左中右障碍距离；修复移动时模型消失 |
| 3 | 每次启动自动记录 DIAG（格式见 [DIAG 记录格式](../guides/diag-format.md)），不再存 RGB |
| 4 | 地面暂时看不到时沿用最近的地面参考（≤2 s）和历史线框（≤1 s） |
| 5 | 按真机日志微调地面确认，网格改为二进制编码 |
| 6–7 | 无 LiDAR 分支，见 [没有 LiDAR 的机型](../features/no-lidar.md) |
| 8–10 | 路线预测和方向震动：扇形里选最远的可达目标，固定目标，偏左双短振、偏右长振，对准后强振一次 |
| — | 表面建模：蓝色地面、红色凸起（高出地面 5 cm），有足够支持时向上画红色阻挡柱到 1.8 m |
| 11 | 修复真机上地面画不出来的问题 |

坐标、地面和栅格的算法见 [空间几何](../architecture/spatial-geometry.md)。路线后来在主 App 里换成了三态避障，见 [运行时数据流](../architecture/runtime-data-flow.md)。

## 构建和测试

在 `Experiments/SpatialProbe` 下：

```sh
bash scripts/validate.sh
swift test --package-path Core --scratch-path build/CoreTests
xcodebuild -project PRTSSpatialProbe.xcodeproj -scheme PRTSSpatialProbe \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

Bundle ID 是 `org.prts.SpatialProbe`，签名时选自己的 Team。测试都是 macOS 上的合成数据。着色器以源码形式（`App/ProbeShaders.metal.txt`）在启动时编译，不需要安装 Metal 离线工具链。

`scripts/` 里还有它自己的 `read_diag.py`、`replay_diag.swift`（重放已存的深度）、`replay_monocular.swift`（重放无 LiDAR 尺度确认）和几个冒烟测试。
