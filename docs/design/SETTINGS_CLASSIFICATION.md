# 设置项分类：Release 用户可见 / 只给开发者

日期：2026-10-28。

## 编译开关怎么区分

只有一个开关：`PRTS_DEV_CAPTURE`。它只在构建时加上 `-xcconfig configs/DevCapture.xcconfig` 才会打开，工程自带的 Debug 和 Release 配置都不带它。

- **Release（给用户）**：普通的 Release 构建，没有 `PRTS_DEV_CAPTURE`。
- **Dev（给开发者和测试员）**：Release 加上 `DevCapture.xcconfig`。目前装到测试机的就是这种。

被这个开关挡住的文件：`ProbeSettingsView`、`DemoOptionsView`、`HomeDemoOverlay`、`DevCaptureRecorder` 整个文件；`SettingsView`、`ContentView`、`ProbeEngine`、`ProbeViewModel`、`DiagnosticRecorder` 里的部分代码。

## Release 用户能看到的

| 位置 | 选项 | 默认 | 存储 |
|---|---|---|---|
| 主页 | 设置按钮、开始/停止按钮、状态、拍照描述按钮 | — | — |
| 设置 → 拍照描述 | 服务与 API Key（允许上传图片、保存/删除 Key、麦克风和语音识别授权、用量说明） | 不允许上传 | Keychain / UserDefaults |
| 设置 → 拍照描述 | 音量键和相机控制按钮 | 开 | `photo.hardwareButtons` |
| 设置 → 语音 | 语音播报、语速 | 开、正常 | `SpeechManager` |
| 设置 → 语言 | 跟随系统、语言（中文 / English） | 跟随系统 | `SpeechManager` |
| 设置 → 显示 | **无画面模式**（本轮新增） | 关 | `display.noPreview` |
| 设置 → 避障 | 通行宽度（更灵活 ← 平衡 → 更舒适，0.40–0.60 m） | 0.50 m（平衡） | `guidance.bodyWidth` |
| 设置 → 振动 | 振动提示 | 开 | `HapticManager` |
| 系统入口 | Siri / 快捷指令 / 操作按钮：开始、停止、描述画面 | — | App Intents |

## 只有开发者能看到的（Dev 构建）

| 位置 | 选项 | 说明 |
|---|---|---|
| 主页 | 参数指标栏、图例与来源说明（`HomeDemoOverlay`） | 叠在画面上方；辅助功能字号下自动隐藏 |
| 主页 | 测试指令栏（开始 / 停止 / 状态） | 用打字模拟语音指令 |
| 设置 → 开发者选项 | 主页参数指标与图例、主页测试指令栏 | 只控制显示 |
| 设置 → 开发者选项 | 保存相机视频与分析数据（DevCapture） | 每次启动都默认关闭 |
| 设置 → 开发者选项 → 演示模式选项 | 显示相机画面、传感器底图、深度热图、几何叠加（地面、阻挡柱、网格、栅格、路径）、信息栏 | 只影响显示 |
| 设置 → 开发者选项 → 图层、路径、触觉与 DIAG 日志（`ProbeSettingsView`） | 深度来源（模拟无 LiDAR）、**避障引导**、**方向振动**、接近距离、预备距离、路径宽度、偏差角、几何参数（人体宽度，与用户的"通行宽度"是同一个值；舒适余量、分析频率、采样步长）、DIAG 导出、会话导出 | 调参和取证用 |

## 值得注意的几点

1. **"避障引导"和"方向振动"在 Release 里没有开关。** 它们都默认开启（`PathOptions.enabled` / `haptics`），Release 用户改不了。"设置 → 振动 → 振动提示"关掉后，所有振动都会停，包括方向振动，所以用户想安静时已经有办法。是否单独开放"方向振动"，需要产品决定。
2. **几何叠加在 Release 里也会画。** `RenderOptions` 的默认值是显示叠加层和路径，Release 用户看到的画面上会有地面和路径的着色，但没有图例。这是现有行为，本轮没改。
3. **Release 也会记录 DIAG**（不含画面和视频），但没有导出入口，数据只留在手机上。隐私说明里写的是 "No RGB or video saved."。
4. **开发者的"显示相机画面"和用户的"无画面模式"不是一回事。** 前者只把底图换成黑色，Metal 还在每秒渲染 30 帧叠加层，几乎不省电。后者完全不创建渲染视图，GPU 不再绘制，见下一节。

## 无画面模式

- 开关：设置 → 显示 → 无画面模式（`display.noPreview`，默认关闭），Release 可见。
- 开启后，相机运行时主页不创建 `CameraMetalView`，显示"无画面模式 · 避障照常运行"。
- 分析、避障提示、方向振动、拍照描述和 DIAG 都直接读共享快照（`SharedStore`），不依赖渲染器，所以功能不变。
- 副作用：DIAG 里的"绘制 FPS"和 `displayedFrameID` 会停在 0，因为根本没有绘制。
- 再配合旁白的"屏幕幕帘"（三指三击），屏幕也可以完全关掉，进一步省电。
