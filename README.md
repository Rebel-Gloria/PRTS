# PRTS

PRTS 是一款面向视障和低视力用户的 iPhone 应用，提供障碍提示、画面描述和文字朗读。项目优先使用手机本地计算，减少对额外设备和网络的依赖。

## 主要功能

| 功能 | 使用方式 |
|---|---|
| 避障引导 | 点击“开始”，通过语音和振动接收障碍与方向提示 |
| 画面描述 | 短按拍照按键，听取眼前画面的简短描述 |
| 语音提问 | 按住拍照按键说话，松开后听取回答 |
| 文字朗读 | 三指按住屏幕 0.8 秒，拍摄并朗读面前的文字 |

拍照按键根据设备和设置使用相机控制按钮、音量键或屏幕按钮。App 也支持旁白、大字体、辅助触控、切换控制，以及 Siri 和快捷指令，详见[使用与无障碍](docs/features/usage.md)。

## 使用条件

需要 iOS 17 及以上。仓库记录的应用版本为 1.0，构建编号为 25。

避障引导使用 LiDAR。没有 LiDAR 的设备可通过模型估算深度，但目前只用于深度显示和路线示意，不能提供可靠的障碍距离或通行判断。项目尚未实现台阶与落差检测、目的地导航、等公交或红绿灯主动提醒。

拍照描述和文字识别默认使用本地 MiniCPM-V 4.7，照片留在手机上。选择远端模型时，需要联网并允许上传照片。语音提问使用系统语音识别，可能调用 Apple 的服务。

现有验证仍以少量设备和场景为主，尚未完成视障用户长期实测。具体数据和适用范围见[验证结果与已知问题](docs/validation.md)。

## 开发入门

在安装 Xcode 的 macOS 上准备本地模型与推理库，再打开 `PRTS.xcodeproj`，选择 PRTS scheme 构建。模型权重约 1.9 GB，不随 Git 仓库分发。

```sh
bash Packages/LocalVLM/prepare.sh
```

构建命令、开发版配置和验证入口见[开发指南](docs/development.md)。修改代码前请阅读[仓库规范](AGENTS.md)。

## 文档

| 主题 | 文档 |
|---|---|
| 使用与设置 | [使用与无障碍](docs/features/usage.md) |
| 图像与文字 | [拍照描述与提问](docs/features/photo-description.md) · [文字识别](docs/features/text-reading.md) |
| 本地模型 | [本地视觉模型](docs/features/local-vlm.md) |
| 空间感知 | [空间几何](docs/architecture/spatial-geometry.md) · [无 LiDAR 模式](docs/features/no-lidar.md) |
| 工程维护 | [工程架构](docs/architecture.md) · [开发指南](docs/development.md) · [诊断与采集](docs/diagnostics.md) |
| 验证与约束 | [验证结果与已知问题](docs/validation.md) · [仓库规范](AGENTS.md) |

PPT、宣传视频和比赛讲稿单独维护在 `marketing` 分支。

## 开源许可

仓库代码使用 [MIT 许可证](LICENSE)。Depth Anything V2 Small 使用 [Apache 2.0 许可证](PRTS/Spatial/Models/LICENSE-DepthAnythingV2.txt)；llama.cpp 使用 MIT；MiniCPM-V 4.7 1B 权重按 openbmb 发布的 Apache 2.0 许可使用。第三方组件以各自附带的许可和来源记录为准。
