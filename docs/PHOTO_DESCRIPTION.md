# 拍照描述（build 19 起）

## 交互与数据流

启动摄像头后，屏幕中心显示160pt点击区域、80pt摄像头图标，图标不透明度25%。
短按（不足0.5秒）在松手时取最新AR帧并播放880Hz提示音A。
长按到0.5秒时取帧、播放440Hz提示音B、启动原生语音识别；松手立即停止采音，
播放A，等待识别最终文本（最多3秒，超时使用已有识别文本，空文本不提交）。
建议先在设置页“语音提问权限”连续批准麦克风/语音识别；首次长按也会请求权限，授权后重新长按，避免把权限弹窗等待期间当作录音。
VoiceOver提供“开始语音提问”“结束语音提问并发送”操作。

`ContentView → PhotoDescriptionCoordinator → PhotoImageEncoder / PhotoSpeechRecognizer
→ PhotoChatClient → PhotoAudioOutput`。

- 使用单一ARSession已有capturedImage，不新增摄像头会话。
- 按拍摄帧方向旋转、保留完整视野，最长边1280、JPEG质量0.8，后台编码。
- 固定端点 `https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions`。
- 模型严格为 `qwen3.8-flash`；`stream=true`、`enable_thinking=true`。
- 短按使用用户指定的完整中文提示词（含“控制在一句到两句话内”）；长按使用识别文字替换，不拼接默认提示词或短按的句数约束。
- SSE只汇总第一个choice的`delta.content`；忽略`reasoning_content`。完整接收后朗读，
  不逐token播放，避免碎片语音。断流且没有结束标志时不朗读残缺回答。
- LLM回答沿用应用播报的原生音色、语言和语速设置，使用相同utterance工厂与默认音调；
  不再选择另一普通话声音或降低音高。每次回答开始朗读时读取当前设置。
  仍保留独立AVSpeechSynthesizer的取消/完成所有权，图片交互期间暂停路线语音/触觉输出，
  空间计算继续，结束后恢复反馈。手动请求的回答不受自动播报开关影响。
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
| PhotoAudioOutput | A/B音、复用应用播报音色配置及朗读完成 |
| SpeechManager | 应用播报与LLM回答的统一utterance工厂、语言/语速设置 |
| PhotoCaptureButton / PhotoDescriptionSettingsView | UIKit触摸事件与设置UI |

## 验证边界

模拟器App测试24项通过（原有14项、新增10项），覆盖精确请求、语音文本替换、SSE正文/思考分离、断流/空正文、半秒阈值/取消、图像四方向尺寸、模拟HTTP传输和401错误。
核心296项、契约8项、Python46项通过。普通iOS Release编译通过；最终Dev签名/安装记录见下文。
没有使用真实API Key，没有上传现场图片，尚未完成真实服务、麦克风、音色、A/B音及长按实机验收。
后续受控实测：短按描述；长按问不同问题；权限拒绝再允许；请求中取消/后台；断网；
横竖屏照片内容；VoiceOver操作；确认导航提示与回答不重叠。无需边行走边测试。

协议参考：[OpenAI图像输入](https://developers.openai.com/api/docs/guides/images-vision)、
[流式响应](https://developers.openai.com/api/docs/guides/streaming-responses)、
[Apple原生语音请求](https://developer.apple.com/documentation/speech/sfspeechaudiobufferrecognitionrequest)。

## 本轮交付

- 实现提交：`b2f00a4`；权限设置与普通话音色调整：`2ea95f4`。
- Dev二进制：`1.0 (19)`，源码`2ea95f4c59e4992d304d18af6887d404734e2821`。
- 2026-09-30 00:48，安装到Gloria iPhone 15 Pro并成功启动；不卸载、不删除历史记录。
- 最终源码模拟器App测试24项全部通过，签名Dev Release构建及严格签名检查通过。
- 图像测试使用合成像素缓冲，HTTP测试使用URLProtocol模拟响应；没有上传真机照片。
- 真实API、长按录音、A/B音、不同朗读音色与摄像头方向的实机体验仍待用户测试。
- [校验和与证据](architecture/PHOTO_DESCRIPTION_EVIDENCE_2026-09-30.json)。

复验命令：

```sh
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -derivedDataPath /tmp/prts-photo19/simulator -xcconfig configs/DevCapture.xcconfig \
  CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/prts-photo19/signed \
  -xcconfig configs/DevCapture.xcconfig PRTS_SOURCE_COMMIT=2ea95f4c59e4992d304d18af6887d404734e2821 build
```


## Build 20：交互链路与显示回归

本轮验证发现：UIButton布局将`imageView.alpha`重置为1，build19图标透明度设置实际失效。
现在在按钮本身设置0.25，不改变160pt触摸区域，独立状态文字仍保持可读。
回归测试先复现布局后alpha=1，再验证修复后的布局及按下/松手状态。

A提示音使用纯播放音频会话，不再为短按启用输入音频路由；B提示音与录音使用playAndRecord。
保留原频率、0.1秒时长和普通话独立音色。提示音播放失败会明确报错。

`PhotoDescriptionServices`仅隔离时钟、权限、原生音频与网络依赖，默认实现与原接口相同。
应用不提供模拟模式。新增6项可控时间/异步响应测试证明：

- 短按在松手取图，使用固定提示词。
- 长按到0.5秒取图并播放B，再开始采音；松手先停采音再播放A；只提交识别文字。
- 取消的按压不拍照、不提交；迟到的旧响应不能朗读或结束新交互。
- 缺少上传许可/Key不拍照；缺少语音权限不退回固定提示词。

另有3项原生UIKit/音频数据测试（透明度/触摸及VoiceOver动作、A/B WAV解码与时长、TTS音色配置）
和1项四象限合成图测试（四方向旋转、无镜像/裁切）。测试不播放音频、不调用真实麦克风或接口。
最终App测试34项全部通过。真实服务、实际音色与手机触摸/采音仍需用户配合确认。


Build20已通过普通iOS Release、签名Dev Release与严格签名校验；2026-09-30 01:02安装并启动。
二进制源码`9504ae89601a03fbc4ecea6c3191d75eaa508847`；保留App数据，不读取用户Key。
[Build20证据](architecture/PHOTO_DESCRIPTION_BUILD20_EVIDENCE.json)。

### 完成审查：尚未关闭的真机验收

| 要求 | 已有证据 | 尚需确认 |
|---|---|---|
| 摄像头中心按钮、25%不透明度 | 条件渲染源码、UIKit布局/高亮测试 | 主页面真机视觉位置与触摸体验 |
| 短按拍照、A音、固定提示词 | 控制器全链路、精确JSON、原生WAV解码测试 | 真机当前场景照片与实际A音 |
| 长按0.5秒、B音、录音、松手停录、提问替换 | 可控时钟及事件次序、替换请求测试 | 麦克风权限、真实转写及B音 |
| 指定端点、模型、stream/thinking | 请求字段、URLProtocol及SSE正文测试 | 该服务与账号实际返回 |
| 原生TTS、沿用应用播报音色 | 共用utterance工厂、语速/语言配置一致性测试 | 手机上的实际朗读与播报一致性 |
| 生命周期与取消 | 旧响应延迟、取消、不允许上传等测试 | 系统中断/后台的设备体验 |
| 交付 | 原子提交、构建、签名、安装和启动结果 | 不以安装代替上述实测 |

请在手机设置页配置Key并授权，在静止、无隐私内容的场景测试短按/长按及取消。
不要把Key发送到聊天。未收到真实服务与设备音频的验证结果前，不将整个功能标为完成验收。


## Build 21：固定提示词契约修复

按当前任务目标核验发现，build20的固定提示词遗漏了最后的句数约束。
本轮保持端点、模型、stream、enable_thinking、图像编码与交互链路不变，
将短按提示词完整修正为：

> 请面向盲人，用简短、凝练、易理解的语言描述这张图片。重点说明图片中的主要物体、人物或场景，以及它们之间的空间位置、方向、距离和几何关系。不要加入无关细节控制在一句到两句话内。

新增独立文本契约测试，同时检查常量和JSON请求，不再只把请求与同一个实现常量比较。
测试先在build20实现上失败（其余34项通过）；修正后35项App测试全部通过。
本轮重跑SpatialCore 296项、PRTSCore契约8项及Python 46项，全部通过。
长按自定义问题另检查不附加短按的句数限制。该限制通过原文提示模型，不人为截断回答。

未改路线算法、目录结构或录制策略。真实服务调用和手机音频的验收仍需用户配置Key后完成；
测试不会发送现场图像或使用真实Key。

Dev build21源码`18a2fdd882096a9b5a54cc1f83d696faffd9de57`已推送main，普通iOS Release、
签名Dev Release及严格签名检查通过；2026-09-30 10:22安装到Gloria iPhone 15 Pro并成功启动，
保留应用及历史数据。二进制中独立检查了完整提示词；真实接口和实际音频尚未据此验收。


## Build 22：LLM回答沿用应用播报音色

按用户的新要求，取消build19/20的独立低音调回答配置。`SpeechManager.announcementUtterance`
成为主页/设置播报、后端路线播报和`PhotoAudioOutput.answerUtterance`共同使用的原生utterance工厂。
语言遵循原“跟随系统/自选语言”设置，语速沿用慢/正常/快三档，音调与音量保持原播报默认值。
回答开始播放时读取现有偏好，不额外创建SpeechManager，不改变原播报的排队、取消及过期处理。

A/B提示音、0.5秒长按、语音识别、提示词、网络请求与路线算法不变。
仍使用独立合成器处理照片交互的完成和取消，避免把LLM回答放入带过期时间的路线播报队列。
自动播报关闭不会静音用户主动请求的照片回答。

回归测试使用隔离的UserDefaults域，不播放音频、不开麦、不读取API Key或发送照片：
检查两种语言×三档语速的音色标识、rate/pitch/volume与播报配置一致；检查设置即时变更和跟随系统。
三个配置回归测试先在旧回答配置上失败，修复后App测试37项全部通过；
本轮SpatialCore 296项、PRTSCore契约8项、Python 46项全部通过。
普通/Dev构建、签名及设备安装结果在操作完成后补充。
