# 设置项

正式版用户能看到的设置不多；调参和取证用的选项只在开发版里有。两者靠一个编译开关区分。

## 正式版和开发版

只有一个开关：`PRTS_DEV_CAPTURE`。构建时加上 `-xcconfig configs/DevCapture.xcconfig` 才会打开；工程自带的 Debug 和 Release 都不带它。

- **正式版**：普通 Release 构建。
- **开发版**：Release 加 `DevCapture.xcconfig`，测试机上装的就是这种。

开关挡住的代码：`ProbeSettingsView`、`DemoOptionsView`、`HomeDemoOverlay`、`DevCaptureRecorder` 整个文件，以及 `SettingsView`、`ContentView`、`ProbeEngine`、`ProbeViewModel`、`DiagnosticRecorder` 里的一部分。

## 正式版的设置

| 位置 | 选项 | 默认 | 存在哪 |
|---|---|---|---|
| PRTS intelligence | 服务商（本机离线、通义千问、DeepSeek、自定义）、API Key、是否允许上传、麦克风和语音识别授权。选本机时不显示 Key 和上传开关 | 本机（离线），不允许上传 | 钥匙串、UserDefaults |
| PRTS intelligence | 音量键快捷操作：音量键当拍照键，屏幕上不再显示拍照按钮。有相机控制按钮的机型不显示这一项，相机控制按钮一直可用 | 开 | `photo.hardwareButtons` |
| （PRTS intelligence 下方） | 三指快速朗读面前文字。小字：使用时会暂停语音播报，请在确认环境安全时使用 | 开 | `ocr.threeFinger` |
| 语音 | 语音播报、语速 | 开、正常 | `SpeechManager` |
| 语言 | 跟随系统、选择语言（中文 / English） | 跟随系统 | `SpeechManager` |
| 显示 | 无画面模式 | 关 | `display.noPreview` |
| 显示 | 扫描网格，连同规划的路线一起画（没有 LiDAR 的机型不显示这一项） | 关 | `display.scanMesh` |
| 振动 | 振动提示 | 开 | `HapticManager` |

另外可以用 Siri、快捷指令和操作按钮开始、停止避障和描述画面（App Intents）。

## 开发版多出的

| 位置 | 选项 | 用途 |
|---|---|---|
| 主页 | 参数指标栏、图例（`HomeDemoOverlay`） | 叠在画面上；辅助功能字号下自动隐藏 |
| 主页 | 测试指令栏：开始、停止、状态、读文字 | 打字代替语音指令，UI 测试也靠它 |
| 设置 → 开发者选项 | 上面两项的显示开关 | |
| 设置 → 开发者选项 | 保存相机视频与分析数据 | 每次启动都是关的，见 [开发采集](../guides/dev-capture.md) |
| 设置 → 开发者选项 → 演示模式选项 | 相机画面、传感器底图、深度热图、几何叠加、信息栏 | 只影响显示 |
| 设置 → 开发者选项 → `ProbeSettingsView` | 深度来源（模拟无 LiDAR）、避障引导、方向振动、各种距离和角度、几何参数、DIAG 和会话导出 | 调参和取证 |

## 需要知道的几点

- **正式版没有"避障引导"和"方向振动"的单独开关**，两者默认都开。关掉"振动提示"会停掉所有振动，包括方向振动。要不要单独开放方向振动，还没定。
- **正式版画面上只有相机画面**，铺满屏幕。地面、障碍、栅格这些着色只在开发版里画。唯一能加的是"扫描网格"：ARKit 一边扫描一边长出来的环境网格，统一用主题绿色，同时画出规划的路线，方便看出往哪走。它只影响显示，不影响避障。
- **正式版也记录 DIAG**（不含画面和视频），但没有导出入口，数据只留在手机上。
- **开发版的"显示相机画面"和"无画面模式"不是一回事**：前者只把底图换成黑色，叠加层照样每秒画 30 帧，基本不省电；后者根本不创建渲染视图。

## 无画面模式

打开后，避障时主页不创建 `CameraMetalView`，只显示"无画面模式 · 避障照常运行"，GPU 不再绘制。

分析、避障提示、方向振动、拍照描述和 DIAG 都直接读 `SharedStore` 里的快照，不依赖渲染，所以功能不受影响。代价是 DIAG 里的"绘制 FPS"和 `displayedFrameID` 一直是 0。

再打开旁白的"屏幕幕帘"（三指三击），屏幕也可以完全黑掉，更省电。
