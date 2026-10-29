# 拍照描述

开着避障时，按一下屏幕中间的相机按钮，App 把当前画面交给模型，读出一两句描述；按住说出问题，松手后读出回答。服务商选"本机（离线）"时不联网，照片不出手机；选其他服务商要联网。

## 怎么用

- **描述画面**：短按（不到 0.5 秒）。松手时拍照，响一声高音（880 Hz）。
- **提问**：按住 0.5 秒，响一声低音（440 Hz）后开始录音；松手停止录音，响高音，把问题和照片一起发出去。识别结果最多再等 3 秒；什么都没听到就不发送。
- **实体按键**：相机运行时，音量键和相机控制按钮的用法和屏幕按钮一样。开关在 设置 → 拍照描述 → "音量键和相机控制按钮"（默认打开）。打开时音量键不调音量；系统不允许只接管其中一个。
- **不方便按住的用户**：旁白里有"开始语音提问""结束语音提问并发送"两个操作；打开辅助触控或切换控制时，屏幕上多一个"开始/发送语音提问"按钮，点两下代替按住。
- 第一次提问前，最好先在设置里的"语音提问权限"一次把麦克风和语音识别都允许了。

取消、切到后台、打开设置、停止避障、来电时，本次请求作废，之后到达的回答不会再读出来。描述期间暂停避障的语音和震动，空间计算照常进行，读完后恢复。

## 服务商

设置 → 拍照描述 → 服务商：

| 服务商 | 地址 | 模型 | 怎么关闭思考 |
|---|---|---|---|
| 本机（离线） | 不联网，模型打包在 App 里 | MiniCPM-V 4.7 1B，见 [本地视觉模型](local-vlm.md) | 对话模板里写一个空的思考段 |
| 通义千问（默认） | `maas.qianwenaiapi.com/compatible-mode/v1/chat/completions` | `qwen3.8-flash` | `enable_thinking: false` |
| DeepSeek | `api.deepseek.com/chat/completions` | `deepseek-flash` | `thinking: {type: disabled}` |
| 自定义 | 用户填写，只接受 `https://`，只填基础地址时自动补上 `/chat/completions` | 用户填写 | 只发标准字段 |

本机不需要 Key，也不需要打开"允许发送照片"。三个联网的服务商都用 OpenAI 兼容的流式 Chat Completions，图片以 `data:image/jpeg;base64` 内联。思考模式都关掉：描述画面不需要推理，关掉后第一个字回来得更快。

## 提示词

- 所有服务商共用系统提示词 `PhotoChatProtocol.system`：要做的、不要做的，外加 4 条示例回答。怎么调出来的见 [拍照提示词](photo-prompt.md)。
- 短按的用户消息是 `描述眼前。`。
- 提问时在识别出的文字前面加 `简短回答盲人的问题：`。

## 请求和朗读

- 照片直接取自 ARKit 当前帧，不另开相机。按拍摄方向转正，保留完整画面，最长边缩到 1280，JPEG 质量 0.8。
- 只收集第一个 choice 的 `delta.content`，忽略思考内容。全部收完再读，不边收边读；连接中途断掉、没收到结束标志的回答不读。
- 回答用 App 播报的同一套声音、语言和语速（`SpeechManager.announcementUtterance`）。"自动播报"关掉时，用户主动要的回答照样会读。

## 隐私

- 每个服务商的 API Key 单独存进钥匙串（`WhenUnlockedThisDeviceOnly`），不写进 UserDefaults、诊断记录或代码。千问沿用旧的 `api-key` 账户，老用户升级后不用重新输入。
- 只走 HTTPS，拒绝重定向，Key 和照片不会被转到别的地址。URLSession 不用缓存和 Cookie。
- 照片、录音、问题和回答只在内存里，不写盘，不进诊断记录。
- 选本机（离线）时，照片只交给手机上的模型，什么都不发出去。
- 语音识别用的是系统的 Speech 框架，可能会用到 Apple 的服务。

## 代码

| 文件 | 做什么 |
|---|---|
| `PhotoPressState` | 0.5 秒短按/长按判断 |
| `PhotoDescriptionCoordinator` | 一次交互的全过程、取消、暂停和恢复避障反馈 |
| `PhotoImageEncoder` | 转正、缩放、编码 JPEG |
| `PhotoSpeechRecognizer` | 麦克风权限、录音、识别 |
| `PhotoChatProtocol` | 提示词、请求格式、流式解析 |
| `PhotoChatProvider` | 三个服务商的地址、模型和思考开关 |
| `PhotoChatClient` | 发请求、限制响应大小、拒绝重定向 |
| `PhotoCredentialStore` | 钥匙串读写 |
| `PhotoAudioOutput` | 提示音和朗读 |
| `PhotoCaptureButton`、`PhotoDescriptionSettingsView` | 按钮和设置页 |

测试在 `PRTSTests` 里，用合成图片和模拟的网络响应，不发真实请求。
