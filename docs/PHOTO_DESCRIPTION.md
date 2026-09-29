# 拍照描述（build 19）

## 交互与数据流

启动摄像头后，屏幕中心显示160pt点击区域、80pt摄像头图标，图标不透明度25%。
短按（不足0.5秒）在松手时取最新AR帧并播放880Hz提示音A。
长按到0.5秒时取帧、播放440Hz提示音B、启动原生语音识别；松手立即停止采音，
播放A，等待识别最终文本（最多3秒，超时使用已有识别文本，空文本不提交）。
首次长按需批准麦克风/语音识别，授权后重新长按，避免把权限弹窗等待期间当作录音。
VoiceOver提供“开始语音提问”“结束语音提问并发送”操作。

`ContentView → PhotoDescriptionCoordinator → PhotoImageEncoder / PhotoSpeechRecognizer
→ PhotoChatClient → PhotoAudioOutput`。

- 使用单一ARSession已有capturedImage，不新增摄像头会话。
- 按拍摄帧方向旋转、保留完整视野，最长边1280、JPEG质量0.8，后台编码。
- 固定端点 `https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions`。
- 模型严格为 `qwen3.8-flash`；`stream=true`、`enable_thinking=true`。
- 短按使用用户指定的完整中文提示词；长按使用识别文字替换，不拼接默认提示词。
- SSE只汇总第一个choice的`delta.content`；忽略`reasoning_content`。完整接收后朗读，
  不逐token播放，避免碎片语音。断流且没有结束标志时不朗读残缺回答。
- 使用独立AVSpeechSynthesizer；优先另一已安装中文音色，若只有一个则使用0.8音高、0.46语速。
  图片交互期间暂停路线语音/触觉输出，空间计算继续。结束后恢复反馈。
- 取消、切后台、打开设置、停止摄像头和音频中断结束本次交互；旧请求不能恢复朗读。

## 配置与隐私

设置 → 拍照描述 → 服务与API Key。先允许发送图片/提问，再将该服务的Key保存到本机钥匙串。
Key使用WhenUnlockedThisDeviceOnly，不写入UserDefaults、代码、诊断或版本库。
只使用HTTPS固定地址；拒绝HTTP重定向；临时URLSession不使用缓存或Cookie。
照片、语音、提问及回答仅在内存中处理，本功能不落盘、不写入DIAG。
开发采集模式的独立RGB录像仍遵守原开关，不因本功能自动开启或关闭。
原生语音识别可能调用Apple服务，并非承诺完全离线。
服务端存储、计费及模型可用性取决于所配置服务；不把兼容协议文档当作服务可用性的证明。

## 模块职责

| 文件 | 职责 |
|---|---|
| PhotoPressState | 可控时间的0.5秒手势状态机 |
| PhotoDescriptionCoordinator | 单次交互、任务代次、取消及反馈所有权 |
| PhotoImageEncoder | AR图像方向、等比缩放及JPEG |
| PhotoSpeechRecognizer | 麦克风权限、音频缓冲、识别与结束等待 |
| PhotoChatProtocol / PhotoChatStream | 精确请求字段、SSE事件及正文解析 |
| PhotoChatClient | 有界响应、取消、HTTP错误、重定向拒绝 |
| PhotoCredentialStore | 钥匙串读写 |
| PhotoAudioOutput | A/B音、独立音色及朗读完成 |
| PhotoCaptureButton / PhotoDescriptionSettingsView | UIKit触摸事件与设置UI |

## 验证边界

模拟器App测试24项通过（原有14项、新增10项），覆盖精确请求、语音文本替换、SSE正文/思考分离、断流/空正文、半秒阈值/取消、图像四方向尺寸、模拟HTTP传输和401错误。
核心296项、契约8项、Python46项通过。普通iOS Release编译通过；最终Dev签名/安装记录另补。
没有使用真实API Key，没有上传现场图片，尚未完成真实服务、麦克风、音色、A/B音及长按实机验收。
后续受控实测：短按描述；长按问不同问题；权限拒绝再允许；请求中取消/后台；断网；
横竖屏照片内容；VoiceOver操作；确认导航提示与回答不重叠。无需边行走边测试。

协议参考：[OpenAI图像输入](https://developers.openai.com/api/docs/guides/images-vision)、
[流式响应](https://developers.openai.com/api/docs/guides/streaming-responses)、
[Apple原生语音请求](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)。
