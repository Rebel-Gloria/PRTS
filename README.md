# PRTS

PRTS 是给视障和低视力用户用的 iPhone App：用 LiDAR 看路、用语音和震动带路，拍张照就能听到眼前是什么，三指按住屏幕就能读出纸上的字。

## 为什么做

视障用户手里最常见的工具仍然是导盲杖，能告诉人的东西很少。导盲犬贵，也不好找。

现有的电子方案各有短板：

- **专用硬件**（OrCam、MyEye 等）效果好，但贵，后续升级也靠厂商；
- **纯云端 App**（Seeing AI、Be My Eyes 等）识别强，但要联网，有延迟，图片要传出去。

我们想要的是：一部 iPhone 就够，主要功能不联网也能用，图片尽量不出手机。

最初的想法来自团队成员何梓仪的毕业设计。那个原型基于 MiniCPM-O，已经在 M 系列芯片、骁龙、Meta Quest 和 iOS（wasm）上跑过，能靠对话完成读文字、室内语音导航这类任务。

## 现在能做什么

| 功能 | 怎么用 | 联网吗 | 说明 |
|---|---|---|---|
| 避障引导 | 点"开始" | 不联网 | LiDAR 测出地面和障碍，规划一条能走的路线，用语音和左右震动引导。前方空旷时只做播报；障碍较远时先引导走近；障碍很近时逐点绕行。没有 LiDAR 的机型用 Depth Anything V2 估算深度。 |
| 拍照描述 | 短按中间的相机按钮描述画面；长按说出问题 | 默认不联网 | 默认用打包在 App 里的 MiniCPM-V 4.7，照片不出手机；也可以在设置里换成联网的模型服务（通义千问、DeepSeek 或兼容 OpenAI 接口的服务）。回答用 App 的播报声音读出来。 |
| 文字识别 | 三根手指按住屏幕 0.8 秒 | 不联网 | 用超广角相机，语音提示怎么对准，页面拍稳后自动拍照，拉正后用 Apple Vision 识别并朗读。 |
| Siri 和快捷指令 | "开始引导""停止引导""描述画面" | 视功能而定 | 见 `PRTS/App/PRTSIntents.swift`。 |

App 支持 iOS 17 及以上，当前版本 1.0（build 25）。

还没做的：

- 把本地视觉模型（MiniCPM-V 4.7）放进正式版，测试结果见 [本地视觉模型](docs/features/local-vlm.md)；
- 主动提醒（等公交、等红绿灯）；
- 目的地导航。

## 文档

全部在 [docs/](docs/README.md)。常用的几份：

- [代码结构](docs/architecture/code-structure.md)、[运行时数据流](docs/architecture/runtime-data-flow.md)
- [拍照描述](docs/features/photo-description.md)、[文字识别](docs/features/text-reading.md)
- [开发采集包](docs/guides/dev-capture.md)：编译时打开 `PRTS_DEV_CAPTURE` 才有，普通包里没有这部分代码。
