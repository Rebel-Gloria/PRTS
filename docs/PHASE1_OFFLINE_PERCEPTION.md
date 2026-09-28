> 历史阶段记录：2026-09-28已由Spatial Probe完整链路替换。当前状态以SPATIAL_INTEGRATION_2026-09-28.md为准。

# PRTS 第一阶段：完全离线基础感知与实时避障闭环

状态日期：2026-09-25

> 工程用途是受控环境中的感知验证，不是目的地导航或已验证的安全辅助产品。候选通道只表示当前观测中满足保守几何条件的短段，不表示安全或保证可通过。

## 已实现架构

### 单一 ARSession 与同帧关联

`PRTS/Capture/CameraManager.swift` 中只有一个 `ARSession`。它使用 `ARWorldTrackingConfiguration`、重力对齐，并在设备支持时启用：

- 原始 `sceneDepth`；
- `meshWithClassification`；
- 同一 `ARFrame` 的 `capturedImage`、原始深度、置信度、相机内参、世界位姿、追踪状态和 `ARFrame.timestamp`。

应用不再创建 `AVCaptureSession`。用于分析的 RGB/深度身份由 `sessionEpoch + frameID + ARFrame.timestamp` 绑定；短生命周期 RGB provider 只在当前保留帧与请求的 epoch/frameID 完全一致时返回像素缓冲。

### 有界处理与失效规则

- ARSession delegate：串行队列。
- 几何分析：独立串行队列。
- `LatestMailbox`：最多一个正在处理的帧和一个可被新帧替换的 pending 帧。
- 默认分析目标：10 Hz；thermal serious：不高于 5 Hz；critical：暂停分析并撤销旧结果。
- MetalKit/Core Image 相机显示：30 FPS 目标，只读取同一 ARSession 的最新 `capturedImage`。
- mesh floor prior：按 anchor 合并，pending anchor 上限 24，保留 anchor 上限 32，每个 anchor 最多抽样约 128 个 floor triangle prior。
- 最大结果年龄：250 ms。追踪受限、方向不稳定、深度或置信度缺失、mesh floor 分类不支持、后台、内存警告、中断、停止、epoch 变化或结果过期都会清空候选输出。

没有障碍距离只显示为“未知”，不解释为前方畅通。

### 几何语义

`Vendor/SpatialCore` 从相邻 PRTSTEST 选择性移植，来源哈希见 `Vendor/SpatialCore/PROVENANCE.md`。默认参数：

- 4 m 前向范围 × 3 m 横向范围；
- 10 cm 栅格；
- 身体宽 0.60 m，加左右各 0.15 m margin；
- 高置信度深度（confidence = 2）才作为证据；
- 重力约束地面估计、mesh floor prior、连续三帧地面确认；
- unknown / obstacle / candidate 三态栅格；
- 整个人体足迹区域必须已观测且有净空；
- unknown gap 不连接，近身盲区不补齐，悬空障碍保留为 obstacle。

坐标约定：

1. 世界坐标为 ARKit 重力对齐世界坐标；
2. 候选中心线为相机地面投影局部坐标，X 向右、Z 向前，单位米；
3. RGB/深度尺寸与缩放后深度内参均记录在 `SceneFrameReference`，不得靠尺寸猜测对齐。

## 阶段接口

### `SceneFrameReference`

位置：`Vendor/SpatialCore/Sources/SpatialCore/SceneContracts.swift`

包含 epoch、frameID、ARKit 单调时间戳、生成时间、失效时间、RGB/深度尺寸、深度内参和相机世界位姿。

### `SceneResult`

同一份结果同时供 SwiftUI 和反馈门控消费，包含：

- tracking / availability / status；
- 深度有效覆盖率与分析耗时；
- 左／中／右障碍观测；
- 三态栅格摘要；
- 当前观测候选中心线、起点距离、长度、最小观测宽度；
- `semanticStatus` 和同帧 `ObjectDetection`。

无模型时固定为 `unavailable(.modelNotBundled)` 且 detections 为空；空数组不表示“没有目标”。

### `SceneResultConsumer`

轻量同步消费协议，后续演示可视化可直接订阅 `SceneResult`，不需要重新解释算法内部类型。

### `SceneRGBFrameProviding`

位置：`PRTS/PRTSBackendBridge.swift`。只返回当前仍保留且 epoch/frameID 完全匹配的 RGB 帧，不持久化图像、不回退到其他帧。这是下一阶段演示或可选模型 provider 获取同帧 RGB 的边界。

### `ObstacleDetector`

包含 capability 和异步 `detect(frame:)`。本阶段实现 `UnavailableObstacleDetector`。未来 detector 返回值必须保留输入 `SceneFrameReference`、推理延迟和有效期；融合前必须严格比较 epoch、frameID、时间戳与有效期。

## 本地目标模型状态

仓库中未发现可接入的 `.mlmodel`、`.mlpackage`、`.onnx` 或 `.pt` 文件，也没有完整类别表、预处理/输出/NMS 约定及再分发许可。因此本阶段没有下载、转换或伪造检测结果。

已核查的候选渠道包括 Apple 的模型目录/Core ML 部署资料，以及 Ultralytics 的许可说明。Apple 目录中的预转换模型仍需为本项目记录具体版本、来源与许可；Ultralytics 同时说明 AGPL-3.0 与 Enterprise 许可选项，项目在选择权重和分发方式前必须做明确许可决定。

参考：

- Apple 模型目录：`https://developer.apple.com/machine-learning/models/`
- Apple Core ML：`https://developer.apple.com/documentation/coreml`
- Ultralytics 许可：`https://docs.ultralytics.com/#yolo-license`
- Ultralytics 仓库许可证：`https://github.com/ultralytics/ultralytics/blob/main/LICENSE`

后续模型必须随附 manifest，至少记录：来源 URL、模型名/版本、SHA-256、许可和再分发决定、输入尺寸、颜色顺序、归一化、输出 tensor/Vision feature 名、类别表、NMS 规则、转换工具和版本、最低 iOS、精度基线及真机延迟/峰值内存。模板见 `docs/OBJECT_DETECTOR_MANIFEST_TEMPLATE.md`。

## 自动验证

本机已执行：

```sh
swift test --package-path Vendor/SpatialCore --scratch-path /tmp/prts-phase1-spatial
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore --scratch-path /tmp/prts-phase1-contracts

xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/prts-phase1-derived \
  -clonedSourcePackagesDirPath /tmp/prts-phase1-packages \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/prts-phase1-release \
  -clonedSourcePackagesDirPath /tmp/prts-phase1-packages \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -derivedDataPath /tmp/prts-phase1-simulator \
  -clonedSourcePackagesDirPath /tmp/prts-phase1-packages \
  CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
```

结果：

- SpatialCore：原有 25/25 + 新增 6/6，共 31/31 通过；
- PRTSContracts：8/8 通过；
- unsigned generic iPhone Debug：通过；
- unsigned generic iPhone Release：通过；
- Simulator app unit tests：3/3 通过；
- generic Simulator `build-for-testing`：通过。

## 必须在 iPhone 15 Pro 验证

自动化构建不能替代以下真机验收：

1. RGB、原始 sceneDepth、confidence、内参及位姿的真实同帧关系；
2. portrait Metal aspect-fit 映射和后续检测框对齐；
3. LiDAR/mesh floor classification 的实际可用性和回调时序；
4. 障碍距离误差、false candidate、unknown gap 和动态撤销；
5. 语音/触觉是否与屏幕显示引用同一个结果 ID；
6. 后台、中断、快速转身、低纹理、遮挡和热状态下是否在 250 ms 内撤销；
7. 30 分钟持续运行的峰值内存、温度、分析 FPS、掉帧和延迟。

不得把 Simulator 相机状态或纯合成测试描述为真机传感器验证。

## Personal Team 真机安装

1. 用 Xcode 打开 `PRTS.xcodeproj`；
2. 连接并选择 iPhone 15 Pro；
3. 在 Signing & Capabilities 中手工选择自己的 Personal Team；
4. 如果 bundle identifier 冲突，手工改为自己的唯一 identifier；
5. 允许 Xcode 管理 provisioning，在设备上信任开发者并授予相机权限；
6. 不需要付费 capability。本实现没有写入新的 Team ID，也没有把签名问题作为代码失败。
