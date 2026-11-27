# PRTS

PRTS 是一款面向视障和低视力用户的 iPhone 与 iPad 应用，提供避障引导、画面描述、语音提问和读文字功能。避障计算、常规画面描述和读文字均可在设备上离线完成，无需额外硬件或网络连接。

## 功能概览

| 功能 | 说明 | 运行方式 |
|---|---|---|
| 避障引导 | 基于 LiDAR 识别地面与前方障碍，通过语音和节奏振动提示绕行方向 | 本机（离线） |
| 画面描述 | 轻点拍照按钮或按下实体按键，听取眼前画面的简短描述 | 本机（默认）或联网服务 |
| 语音提问 | 按住拍照按键提问、松手发送，针对当前画面追问细节 | 本机（默认）或联网服务 |
| 流式字幕 | 连按三下开启，持续播报画面中发生的动作 | 联网（目前仅支持通义千问） |
| 读文字 | 三指按住屏幕，拍摄并朗读面前的路牌、告示或纸面文字 | 本机（默认）、联网或 Apple Vision |

应用支持旁白（VoiceOver）、动态字体、辅助触控、切换控制，以及 iOS 操作按钮、相机控制按钮、轻点背面和 Siri 快捷指令。面向低视力用户，设置中提供“低视力模式”，可保留相机预览、画面描述和读文字，同时暂停深度感知与避障提示。

## 系统要求与能力边界

- **系统与设备**：需要 iOS 17 或更高版本。精确避障需要带 LiDAR 的 Pro 机型；`Release` 和 `Dev` 两种构建首页均采用 RGB 画面，不显示深度热图或路线，无 LiDAR 设备可运行单目深度估计计算相对深度供内部诊断，但不触发避障语音和方向振动，也不具备同等障碍测距能力。
- **尚未支持场景**：暂不支持台阶、下沉落差、玻璃及低矮细小障碍的专门检测，也不包含目的地导航、公交或信号灯识别。
- **模型与隐私**：默认内置离线模型 MiniCPM-V 4.7 1B。使用联网服务或流式字幕需开启上传开关并配置 API Key，应用会在发起时检查。用户主动选择本机提问时强制使用本机语音识别，不可用则无法发起；联网提问调用系统语音识别，可能会使用 Apple 服务。`Release` 构建不自动录制图像、音视频或模型请求正文。
- **验证状态**：当前实测主要来自少量设备与短时样本，尚未完成视障用户的长期实地盲测。详情请参阅[验证结果](docs/validation.md)。

## 快速构建

构建应用需要安装了 Xcode 26 或更高版本的 Mac，以及 `cmake` 和 `ninja`。

1. 准备本地视觉模型和推理库（约下载 1.9 GB 公开权重，模型文件不纳入仓库）：

   ```sh
   bash Packages/LocalVLM/prepare.sh
   ```

2. 打开 `PRTS.xcodeproj`，选择 `PRTS` scheme 进行构建或运行。

命令行编译参数、Dev 自动录制与离线回放工具请参阅[开发指南](docs/development.md)。

你也可以从 GitHub Releases 的预发布（Pre-release）页面获取未签名的 `Release` 与 `Dev` 预构建 IPA 包，使用自己的 Apple 开发者签名或侧载工具安装到 iOS 设备。

> [!IMPORTANT]
> `Dev` 构建会在本机自动录制现场画面、空间数据与提问音频用于离线回放。录制数据仅保存在设备本地，不会主动上传，请仅在受控测试环境中使用。

## 文档阅读顺序

工程文档位于 `docs/`，应用内面向最终用户的操作指南位于 `PRTS/Features/Settings/UserGuide/`。首次阅读源码时，可按以下顺序了解项目：

1. 阅读[工程架构](docs/architecture.md)，了解模块分层、应用装配与架构约束。
2. 阅读 `PRTS/Features/Home/ContentView.swift`，了解首页如何协调相机与各项功能。
3. 按修改范围深入专题文档：避障算法参阅[空间感知](docs/spatial.md)，视觉服务与模型参阅[图像与文字识别](docs/vision.md)，按键与设置参阅[交互与设置规格](docs/usage.md)。
4. 修改前参阅[开发指南](docs/development.md)与[仓库规范](AGENTS.md)。

| 文档 | 内容 |
|---|---|
| [交互与设置规格](docs/usage.md) | 操作方式、按键仲裁时序、无障碍适配与设置项说明 |
| [工程架构](docs/architecture.md) | 目录结构、装配关系、避障数据流、相机交接与设计约束 |
| [空间感知](docs/spatial.md) | 坐标投影、地面拟合、占用栅格、有效期与无 LiDAR 校准 |
| [图像与文字识别](docs/vision.md) | 服务路由、提示词、流式字幕采样、文字识别与本地模型封装 |
| [开发指南](docs/development.md) | 构建模式、测试、持续集成、Dev 自动录制与离线回放工具 |
| [验证结果](docs/validation.md) | 测试指标、方案采用或撤回决定及已知问题 |
| [开发与仓库规范](AGENTS.md) | 编码风格、分层边界、文档与文案规范及提交要求 |

## 参与贡献与许可证

欢迎提交 Issue 和 Pull Request。提交代码前，请先阅读 [AGENTS.md](AGENTS.md)，并运行[开发指南](docs/development.md#测试)中的检查命令。

本项目代码采用 [MIT 许可证](LICENSE)。第三方组件沿用各自原许可证：

| 组件 | 许可证 | 说明 |
|---|---|---|
| Depth Anything V2 Small | [Apache 2.0](PRTS/Spatial/Models/LICENSE-DepthAnythingV2.txt) | 模型卡与校验信息位于 `PRTS/Spatial/Models/` |
| llama.cpp | MIT | 通过 `Packages/LocalVLM/prepare.sh` 获取与编译 |
| MiniCPM-V 4.7 1B 权重 | Apache 2.0 | 来自 `openbmb/MiniCPM-V-4.7-1B-gguf` |

> [!NOTE]
> 应用内暂未提供第三方许可证展示入口，相关界面正在规划中。如组件权利人对当前署名方式有疑问，请通过 [GitHub Issues](https://github.com/Rebel-Gloria/PRTS/issues) 反馈。
