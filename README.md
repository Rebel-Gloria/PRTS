# PRTS

PRTS 是一款面向视障和低视力用户的 iPhone / iPad 应用，集成了实时避障引导、画面描述、语音提问和文字朗读。其中避障、常规画面描述和读文字都可以完全离线在设备上运行，不依赖额外硬件或网络连接。

## 主要功能

| 功能 | 用途 | 运行位置 |
|---|---|---|
| 避障引导 | 基于 LiDAR 识别地面与前方障碍，通过语音和节奏振动提示绕行方向 | 本机（离线） |
| 画面描述 | 按一下拍照按钮或实体按键，听取眼前画面的简短口述 | 本机（默认）或联网模型 |
| 语音提问 | 长按提问、松手发送，针对当前画面追问细节 | 本机（默认）或联网模型 |
| 流式字幕 | 连按三下开启，持续播报镜头前正在发生的动作 | 联网（目前仅支持通义千问） |
| 读文字 | 三指长按屏幕，拍下并朗读面前的路牌、告示或纸面文字 | 本机（默认）、联网或 Apple Vision |

应用完整支持旁白（VoiceOver）、动态字体、辅助触控、切换控制，以及 iOS 操作按钮、相机控制按钮、轻点背面和 Siri 快捷指令。针对低视力用户，设置中提供**低视力模式**，可保留相机预览、画面描述和读文字，同时关闭深度感知与避障提示。

## 环境与当前能力边界

- **系统与硬件**：要求 iOS 17 或更高版本。精确避障依赖带 LiDAR 的 Pro 机型；无 LiDAR 设备可运行单目深度估计以显示相对深度和路线示意，但不具备同等的障碍测距精度。
- **物理形态识别**：尚不支持台阶、下沉落差、透明玻璃和低矮细小障碍的专门检测，也不包含目的地导航或红绿灯识别。
- **视觉与语音服务**：默认离线包内嵌 MiniCPM-V 4.7 1B。切换到联网模型或使用流式字幕时需开启上传许可并配置 API Key；语音提问调用 iOS 系统语音识别，部分系统环境下会经过 Apple 服务器。
- **验证状态**：当前实测主要基于单人单机短时采集与公开数据集抽样，尚未完成视障用户的长期实地盲测；详见[验证结果](docs/validation.md)。

## 构建运行

构建需要一台安装 Xcode 26+ 的 Mac，并预先安装 `cmake` 和 `ninja`。

1. 拉取并编译本地推理库与视觉模型（约下载 1.9 GB 公开权重，模型文件不纳入 Git 仓库）：

   ```sh
   bash Packages/LocalVLM/prepare.sh
   ```

2. 用 Xcode 打开 `PRTS.xcodeproj`，选择 `PRTS` scheme 直接编译或运行。

命令行构建参数、Dev 调试录制模式、代码格式校验与测试命令见[开发指南](docs/development.md)。

## 文档导航

工程文档全部位于 `docs/`，应用内面向最终用户的简明操作指南位于 `PRTS/Features/Settings/UserGuide/`。如果是第一次接触源码，建议按以下顺序阅读：

1. [工程架构](docs/architecture.md)：目录职责、协调器装配关系、线程模型与相机交接。
2. `PRTS/Features/Home/ContentView.swift`：首页视图与各功能协调器的总入口。
3. 按修改范围深入专题：[空间感知](docs/spatial.md)（地面、栅格与无 LiDAR 校准）、[图像与文字识别](docs/vision.md)（提示词、流式字幕、OCR 与本地 VLM）或[交互与设置规格](docs/usage.md)。
4. 动手改代码前阅读[开发指南](docs/development.md)与[仓库规范](AGENTS.md)。

| 文档 | 内容范围 |
|---|---|
| [交互与设置规格](docs/usage.md) | 按键仲裁、音频与前后台策略、无障碍适配及设置项键值 |
| [工程架构](docs/architecture.md) | 模块分层、数据流、路径发布、播报冷却与架构约束 |
| [空间感知](docs/spatial.md) | 坐标投影、RANSAC 地面拟合、通行检查、有效期与单目校准 |
| [图像与文字识别](docs/vision.md) | 模型路由、提示词约束、帧采样调度、OCR 回退与隐私边界 |
| [开发指南](docs/development.md) | 编译配置、单元测试与 CI、Dev 自动录制、数据提取和回放脚本 |
| [验证结果](docs/validation.md) | 实测指标、提示词与模型选型对比、撤回决定及已知问题 |
| [开发与仓库规范](AGENTS.md) | 编码风格、分层边界、文档与文案规范及提交要求 |

## 参与贡献与许可证

欢迎提交 Issue 或 Pull Request。提交前请先阅读 [AGENTS.md](AGENTS.md)，并按[开发指南](docs/development.md#测试)运行格式与边界检查。

本项目源码采用 [MIT 许可证](LICENSE)。内嵌或依赖的第三方组件遵循各自原许可证：

| 组件 | 许可证 | 说明 |
|---|---|---|
| Depth Anything V2 Small | [Apache 2.0](PRTS/Spatial/Models/LICENSE-DepthAnythingV2.txt) | 模型卡与校验信息见 `PRTS/Spatial/Models/` |
| llama.cpp | MIT | 通过 `Packages/LocalVLM/prepare.sh` 拉取编译 |
| MiniCPM-V 4.7 1B 权重 | Apache 2.0 | 来自 `openbmb/MiniCPM-V-4.7-1B-gguf` |
