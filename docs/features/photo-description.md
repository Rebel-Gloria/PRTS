# 拍照描述与语音提问

避障运行时，短按拍照按键可听取画面描述，长按说话、松开后可听取回答。默认由本地 MiniCPM-V 4.7 处理照片；远端服务需要联网和上传授权。

## 按键与交互

| 设备或设置 | 拍照按键 |
|---|---|
| 有相机控制按钮 | 始终使用实体按钮，不显示屏幕拍照按钮 |
| 无相机控制按钮，开启音量键快捷操作 | 使用音量键，不显示屏幕拍照按钮 |
| 无相机控制按钮，关闭音量键快捷操作 | 使用屏幕拍照按钮 |

音量键快捷操作默认开启，仅在没有相机控制按钮的设备上提供设置。`AVCaptureEventInteraction` 同时接管音量键与相机控制按钮，无法只接管其中一种；启用后，两个音量键均用于拍照，不再调节音量。按键事件只在相机使用期间交给 App。

短按不足 0.5 s 时，松手拍照并播放 880 Hz 提示音。按住达到 0.5 s 时，播放 440 Hz 提示音并开始录音；松手停止录音，再播放高音提示。语音识别最多额外等待 3 s，没有识别出问题则不发送请求。

首次提问需授予麦克风和语音识别权限。不便长按时，可使用旁白自定义操作，或辅助触控、切换控制提供的两次点击方式，详见[使用与无障碍](usage.md)。

描述和回答期间，避障语音与振动暂停，空间计算继续；朗读结束后恢复反馈。取消、进入后台、打开设置、停止避障或来电都会使请求失效，迟到回答不再朗读。

## 服务与思考设置

在“设置 → PRTS intelligence → 智能设置”选择服务。

| 服务 | 模型或接口 | 默认思考设置 |
|---|---|---|
| 本机（默认） | MiniCPM-V 4.7 1B | 使用空思考段 |
| 通义千问 | `qwen3.8-flash`；`maas.qianwenaiapi.com/compatible-mode/v1/chat/completions` | `enable_thinking: false` |
| DeepSeek | `deepseek-flash`；`api.deepseek.com/chat/completions` | `thinking: {type: disabled}` |
| 自定义 | 用户填写模型和 HTTPS 地址；基础地址自动补 `/chat/completions` | 仅发送标准字段 |

本机服务无须 API Key 或照片上传授权。远端采用兼容 OpenAI 的流式 Chat Completions 请求，照片以 `data:image/jpeg;base64` 写入正文。

千问和 DeepSeek 可开启“提问时深度思考”，分别发送 `enable_thinking: true`、`thinking: {type: enabled}`。默认关闭，仅影响长按提问；自定义和本机服务不提供此开关。现有测试未显示稳定的质量收益，等待时间明显增加，数据见[验证结果](../validation.md)。

## 提示词与回答约束

| 场景 | 当前规则 |
|---|---|
| 短按描述 | 使用 `PhotoChatProtocol.system`，用户消息固定为“描述眼前。”；先说最近物体及位置，再说路面，限一到两句、四十字以内 |
| 远端提问 | 使用 `questionSystem`，直接回答问题，可描述颜色、穿着、数量、文字、用途或翻译，最多三句 |
| 本机提问 | 使用 `localQuestionSystem`，以具体问答示例约束细节回答，最多三句 |

长按问题保留语音识别原文，不再添加旧前缀。描述使用 4 条示例说明句式；提问通过 `threeSentences` 在第三句结束处截断。

所有提示词均要求只描述可见事实，不编造内容、不估计米数、不提供通行许可或绕行指令。看不到或无法判断时应明确说明。提示词约束不能消除模型错误，尤其是台阶方向和“能否通行”的回答。

## 图像、朗读与数据处理

照片直接取自 ARKit 当前帧，不另开相机。图像转正后保留完整画面，最长边缩放到 1280 像素，以 0.8 的 JPEG 质量编码。

远端响应只读取第一个 choice 的 `delta.content`，忽略思考内容。完整接收后才朗读；连接中断或缺少结束标志时，丢弃未完成回答。朗读由 `SpeechManager.announcementUtterance` 输出，沿用 App 音色、语言和语速。关闭自动播报不影响用户主动请求的回答。

API Key 按服务分别存入钥匙串，访问级别为 `WhenUnlockedThisDeviceOnly`；千问保留旧 `api-key` 账户兼容已有配置。远端请求仅允许 HTTPS、拒绝重定向，不使用缓存或 Cookie。照片、录音、问题和回答仅保留在内存，不写入诊断或文件。本地处理照片时，语音识别仍可能调用 Apple 服务。

实现集中在 `PRTS/PhotoDescription/`：`PhotoDescriptionCoordinator` 管理流程，`PhotoChatProtocol` 定义提示词与解析，`PhotoChatProvider` 定义服务，`PhotoChatClient` 发送请求。模型集成见[本地视觉模型](local-vlm.md)。
