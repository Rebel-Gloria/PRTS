# PRTS Spatial Probe

独立原生 iPhone 空间感知验证应用：SwiftUI + 一个 ARSession + MetalKit；iOS 17+，无第三方运行库、无目的地导航。build 6 增加 Apple 官方 Core ML 深度模型的无 LiDAR 分支。

> **实验验证，候选通道不等于安全路线。**
>
> 本工程已实现 M1–M5 的首版代码和离线测试工具。**真机 RGB／深度／置信度对齐仍是第一个验收门槛，尚未通过现场验收。** 可编译、模拟器截图、合成数据测试都不构成 LiDAR 功能验收。

## build 10：固定最远目标、左右节奏振动

扇形内只取沿地面径向距离最远的可达位置，不再偏好正前方；选中后固定世界坐标，新出现更远点也不自动延长目标。到达（默认0.35m）或持续越界才换点，障碍/追踪/地面冲突仍优先撤销。目标意图与路线证据分开：证据过期可暂停连线/振动，但不会因此不停换目标。

连线偏左重复双短振、偏右重复长振；进入±5°稳定0.3秒强振一次，然后静默，直到偏离12°持续0.25秒。阈值可调，强振仅确认角度、非位置或安全。详见`Docs/PATH_PREDICTION.md`和`Reports/FIXED_TARGET_HAPTICS_2026-09-27.md`。

## build 9：扇形远目标与脚下连线

在正前方左右各45°内，选取更远且接近正前方的可达目标；8邻域搜索允许绕障，简化后的实线仍检查全宽足迹。路径默认最小总宽度改为0.50m，设置可调；不影响原有严格净空候选栅格。估计脚下到已观测入口画青虚线（盲区未验证），当前段黄实线、目标黄环，短时历史橙虚线。范围仍受当前蓝面/深度支持约束，默认前方4m、左右各1.5m。不是目的地导航或安全保证。详见`Docs/PATH_PREDICTION.md`与`Reports/FAN_PATH_2026-09-27.md`。

## build 6：无 LiDAR 适配

设置新增 **模拟无LiDAR设备**：有 `sceneDepth` 的设备可切换，没有则强制开启且无法关闭。切换会重建会话并清空旧证据。

使用用户指定的 `apple/coreml-depth-anything-v2-small` 官方 FP16 模型，结合 ARKit 原生平面、可用的平面分类、位姿和稀疏特征。该包输出**相对逆深度，不是 Metric**；尺度不足时显示相对图，校验后才显示带“预测”标识的米制几何。原生平面只画边界，不填成已观测可通行区。预测分支目前不授权通道。

模型离线打包，RGB 仅在内存推理、不保存。诊断新增 `prediction.jsonl` 及空间数据附件。详见 `Docs/NO_LIDAR.md` 和 `Reports/NO_LIDAR_2026-09-27.md`。

## 打开、构建和测试

工程：`/Users/yuanyuan/Desktop/Prts/PRTSTEST/PRTSSpatialProbe.xcodeproj`。

1. 用 Xcode 打开工程，选择 `PRTSSpatialProbe` scheme。
2. 在 Target → Signing & Capabilities 选择你有权使用的 **Team**，确认独立 Bundle ID。当前独立应用标识为 `org.prts.SpatialProbe`，工程保留已使用的本机开发 Team；换机器时选择你有权使用的团队，不提交证书私钥或购买服务。不要沿用旧应用标识覆盖旧应用。
3. 选择已连接、解锁且支持 ARKit 世界追踪的 iPhone；运行时按需处理设备信任、开发者授权和钥匙串提示。
4. 首次进入应用，点击“开始”并批准**相机**权限。没有麦克风、定位、相册权限要求。
5. 静止胸前持机，等待追踪正常和方向稳定。M1 先关闭网格／栅格／通道，逐一检查 RGB、深度、置信度和叠加模式。

命令行（在工程根目录执行）：

```bash
bash scripts/validate.sh
# 仅核心几何测试
swift test --package-path Core --scratch-path build/CoreTests
# 仅 unsigned 真机构建，不安装、不签名
xcodebuild -project PRTSSpatialProbe.xcodeproj -scheme PRTSSpatialProbe \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

本地 Swift Package 测试通过 `swift test` 执行，工程 scheme 的 Test Action 没有额外的 iOS XCTest target。测试是 macOS 上的合成数据／确定性测试，不是假冒的传感器结果。构建日志在 `build/`。

### 本机 Metal 工具链适配

检查到 Xcode 未安装可选的 **Metal 离线编译工具链**。工程将 shader 保存为 `App/ProbeShaders.metal.txt` 资源，使用 `MTLDevice.makeLibrary(source:options:)` 在启动时后台编译一次；没有下载组件或修改系统设置。未启用 fast-math，以保留无效深度／NaN 检查。HUD 显示 Metal 初始化状态；失败时不得视作显示验证通过。后续若主动安装完整工具链，可改回构建时编译，非本版运行前置条件。

## 已实现

- 单 ARSession：RGB、原始深度、可选置信度、相机参数、追踪状态、网格分类。
- 完整视野等比留边；RGB、米制热图、置信度共用显示映射；冻结检查。
- 网格增量缓存、分类线框、ARKit floor 填色；不把分类当真值。
- 高置信度反投影、重力约束 RANSAC、floor 先验验证、当前帧地面支持及身体净空测试。
- 未知／障碍／候选三态、人体足迹膨胀、左中右稳健障碍距离及短候选段；严格候选段不跨未知，新预测图仅用明确的青虚线连接近身盲区。
- 方向、追踪、参数代次、会话代次、结果年龄门控；后台／停止／中断撤销结果。
- 有界后台处理、指标 JSONL／CSV、热状态、手动同帧采样与系统文件夹导出。
- 独立人工测量 CSV 模板、离线统计与错误候选事件报告工具。

## 地面突起建模（2026-09-27更新）

新增默认开启的“表面建模：蓝地面／红突起”：当前深度观测到的地面为蓝色，高出确认地面默认5 cm且有空间支持的突出地形／物品表面为红色，保留实际三维高度。有至少2个相邻障碍格、6个有效点和1 L几何包络支持时，再将其占地向上标为半透明红色阻挡柱，默认至身体检查高度1.8 m；上方禁入区不是实测实体。低置信度、未确认地面和遮挡区域不补模型。蓝色不是可通行保证。详情见 `Docs/SURFACE_MODEL.md`；新增功能的构建／合成测试结果见 `Reports/SURFACE_MODEL_2026-09-27.md`，尚未完成真机验证。

## 使用说明

- 顶部：采集／分析／绘制 FPS，各阶段 CPU/GPU 时间，覆盖率、未知率、追踪、热状态和源帧年龄。
- 设置：基础图层、深度透明叠加、网格／floor／栅格／通道、处理 Hz、像素采样步长、人体宽度／余量／身高。平滑深度只用于显示，须停止后切换配置。
- 冻结：只检查静态传感器图像，明确标为非实时，撤销通道。
- 手动采样：确认环境允许拍摄后保存冻结帧；未冻结则优先保存最近完成分析的帧，元数据记录真实源时间。只保存空间数据及元数据，不保存RGB或视频。
- 停止后：设置 → 导出会话 → 系统文件选择器，导出完整目录。也可在 Files 的应用 Documents 下查看 Sessions。无自动上传。
- 追踪丢失、快速转向、看不到头部净空或缺地面先验时，输出“未知／无候选通道”是预期行为。

## 文档与结果

- `Docs/ARCHITECTURE.md`：坐标、算法、距离、参数、并发、限制。
- `Docs/LOG_FORMAT.md`：数据格式、来源、导出与统计。
- `Docs/DEVICE_VALIDATION.md`：逐里程碑真机步骤和重复测试。
- `Reports/VALIDATION.md`：本次实际验证结果和未验证项。
- `Reports/ground-truth-template.csv`：独立卷尺／人工标注模板（空模板，不含编造数据）。

## 仍需你处理

确认 Team／独立 Bundle ID；保持设备连接并按需解锁、批准相机权限。实测前填写测试人员宽度、身高、持机高度及余量，准备卷尺、可控场地、障碍物和协助人员，确认现场影像记录许可。**这些事项没有阻碍本次代码、测试与文档编写。**

所有行走测试由视力正常的人员在受控环境中完成。不要进行无保护盲行；不宣称可靠台阶、落差或玻璃检测。旧原生工程和网页原型均未修改。


## 地面短暂离开视野（build 4，2026-09-27）

将当前地面确认与AR世界参考分离：正常追踪下最多沿用2秒近期世界地面参考，继续以当前深度显示蓝地面/红突起；俯仰过大不再直接清空几何。测量不足时最多显示1秒、明确标记的历史线框，绝不复用旧通道或净空。初次地面确认、未知状态和通道安全门控保留。具体上限与失效规则见Docs/ARCHITECTURE.md，诊断与回放格式见Docs/DIAGNOSTICS.md，本轮证据见Reports/GROUND_CONTINUITY_2026-09-27.md。


## 参数与记录微调（build 5，2026-09-27）

根据build 4真机DIAG修正地面确认比较位置，保持4cm/3°/3次门限；表面预算24,576面，使常见深度分辨率保留步长2细节。DIAG完整网格改为二进制编码，降低记录开销，依然不保存RGB。92项Swift及19项Python测试通过。离线对比不代表新版现场精度/安全已通过，详见Reports/PARAMETER_TUNING_2026-09-27.md。下一阶段台阶/深度模型方案见Docs/STEP_DETECTION_PROPOSAL.md（未实现）。

## build 8：预测路径线与方向振动

默认在连续蓝地面内绘制一条黄色世界路径，避开膨胀后的已观测障碍与未知空洞；短时测不到地面时保留为橙虚线，默认2秒，新障碍立即撤销/重规划。偏航超过12°逐渐增强振动，对准稳定后仅强振一次。支持LiDAR和经尺度校验的无LiDAR预测几何；不改变严格候选栅格，不保证身体净空。设置可关闭/调整。**強振只表示方向对准，非安全通行确认。** 详见Docs/PATH_PREDICTION.md，代码和验证结果见Reports/PATH_PREDICTION_2026-09-27.md。
