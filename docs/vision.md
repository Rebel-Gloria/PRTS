# 图像与文字识别

本文说明 PRTS 的视觉服务路由、提示词约束、流式字幕采样调度、文字识别回退链与本地视觉模型封装。操作方式请参阅[交互与设置规格](usage.md)。

画面描述、语音提问和文字识别默认使用随应用打包的 MiniCPM-V 4.7 1B 离线运行，也可按功能切换至联网服务（文字识别还可选用 Apple Vision）；流式字幕因动作理解准确性要求固定使用通义千问。这些功能与 `SpatialCore` 避障算法相互独立。

## 模型服务与路由

你可以在“设置”>“智能”中指定默认服务商，并为各服务商单独配置凭据与推理开关：

| 服务商 | 模型与接口地址 | 默认思考参数 |
|---|---|---|
| 本机（默认） | MiniCPM-V 4.7 1B | 空思考段 |
| 通义千问 | `qwen3.8-flash`，`maas.qianwenaiapi.com/compatible-mode/v1/chat/completions` | `enable_thinking: false` |
| DeepSeek | `deepseek-flash`，`api.deepseek.com/chat/completions` | `thinking: {type: disabled}` |
| 自定义 | 用户指定的 HTTPS 模型接口（仅填基础地址时自动补全 `/chat/completions`） | 仅发送标准字段 |

联网服务采用兼容 OpenAI 的流式 Chat Completions 接口，照片以 `data:image/jpeg;base64` 传入请求正文。客户端仅读取首个 choice 的 `delta.content`，忽略思考内容，在收到完整回答后开始朗读。连接中断、缺少结束标志或触发长度上限时，未完成回答会被丢弃并播报失败提示（流式字幕则跳过该句继续运行）。

- **通义千问 Omni 开关**（`photoDescription.qwenOmni`，默认关闭）：开启后全部千问请求改用 `qwen3.8-omni-flash`，准确度提高但耗时增加；客户端仍强制发送 `enable_thinking: false`。
- **提问时深度思考**（`photoDescription.questionThinking` / `.deepseek`，默认关闭）：仅作用于语音提问。测试中开启后等待时间显著延长而质量无稳定提升，因此默认关闭。
- **本机增强模式**（`photoDescription.localEnhanced`，默认关闭）：开启后本机语音提问复用联网提问提示词，允许更发散的细节回答。

### 按功能配置

描述画面（`intelligence.provider.description`）、语音提问（`intelligence.provider.question`）和读文字（`ocr.service`）默认跟随默认服务商；`ocr.service` 设为 `vision` 时直接调用 Apple Vision。`IntelligenceFeature` 在每次操作开始时解析对应服务商并检查上传许可与 API Key。公共请求层位于 `PRTS/Shared/Intelligence/`，协调器仅通过抽象接口调用。

## 提示词设计

短按描述和语音提问的提示词定义在 `PRTS/Features/PhotoDescription/Services/PhotoPrompts.swift`，流式字幕的提示词定义在 `PRTS/Features/LiveCaption/Services/LiveCaptionPrompts.swift`：

| 场景 | 符号 | 核心规则 |
|---|---|---|
| 短按描述 | `PhotoPrompts.system` | 用户消息固定为“描述眼前。”；先说最近物体及位置再说路面，1–2 句、40 字以内 |
| 语音提问（联网 / 本机增强） | `PhotoPrompts.questionSystem` | 直接回答问题（颜色、数量、文字、翻译等），最多 3 句，禁止给出通行建议 |
| 语音提问（本机常规） | `PhotoPrompts.localQuestionSystem` | 沿用短按描述的防幻觉规则并附带问答示例，最多 3 句 |
| 流式字幕开场 | `LiveCaptionPrompts.opening` | 用户消息固定为“描述眼前。”；一句话说明所处位置与面前主要物体，20 字以内 |
| 流式字幕动作 | `LiveCaptionPrompts.system` | 输入 6–21 帧视频和上一句文本，仅描述新发生的动作，24 字以内；无动作时输出“无” |

语音提问直接发送系统语音识别原文，不附加前缀；回答由 `threeSentences` 在第三个句末标点处截断。所有提示词均禁止模型估算具体米数或代替用户判断“能否通行”；各版本提示词的评估结果请参阅[验证结果](validation.md#拍照描述与提问)。

## 流式字幕

流式字幕将相机画面编码为短视频片段发往通义千问（其他模型在测试中会对静止画面编造动作，因此未开放）。实现位于 `PRTS/Features/LiveCaption/`，按键连按判定规则见[工程架构](architecture.md#拍照按键分发链路)。

### 采样与发送流程

1. **启动**：先播报“流式字幕已开启，再按一下退出”，同时发送首帧单图请求生成最多 40 token 的开场句，在启动提示读完后播出。
2. **滑动缓冲**：每 0.1 s 从当前采集后端采样一帧，保存最长边 960 像素、质量 0.5 的 JPEG 与 48×64 灰度图，保留最近 2 s 内最多 20 帧。
3. **定时请求**：每 2 s 固定发送一次视频请求（上限 24 token，关闭思考），无动作时由模型回答“无”。
4. **运动自适应抽帧**：相邻请求复用上一次视频的尾帧。尾帧与首张新帧相隔超过 2 s 时，仅使用新帧；总计至少 4 帧才发送。新帧数由窗口内相邻灰度图平均绝对差之和插值决定：总运动量 ≤ 30 时取 5 帧，≥ 150 时取满 20 帧（10 fps），按累计运动量等分点挑帧以避开重复画面。

### 并发与输出过滤

单次请求往返通常长于 2 s，因此最多允许 3 个请求同时在途，超出时跳过本次请求；单次失败静默跳过，连续失败 3 次才播报错误并退出。先发后至的过时回答按序号丢弃；上一句仍在朗读时，仅保留最新一条待播回答。

开场句达到 40 token 上限时跳过并继续运行；动作句由 `LiveCaptionPolicy.answer` 取第一行，满足以下任一条件时不朗读：

| 过滤条件 | 说明 |
|---|---|
| 回答为“无”或“无。” | 画面中没有明显动作 |
| 超过 24 字，或达到生成上限 | 超长截断，跳过本句并继续运行 |
| 包含“照片”“画面”或“镜头” | 模型在静态描述画面而非动作 |
| 与上一句相同 | 避免重复播报同一动作 |

## 文字识别

文字识别按“选定后端 → 本机模型 → Apple Vision”三级回退（直接选择 Apple Vision 时不回退），所有服务均失败时播报“读文字失败，请重试”。主动取消（包括网络层 `URLError.cancelled`）会立即结束流程并释放资源。

### 识别流程与代码结构

1. 暂停 ARKit 或普通 RGB 采集，切换至预配置好的后置主摄。启动主摄后若 10 s 内未进入拍照，播报“无法打开相机”并退出。
2. 收到首帧后等待 1 s 待对焦和曝光稳定，自动拍照并触发反馈振动。
3. **本机两次提问**：先发 8 token 短问判断文字所在物体（路标 / 牌子 / 纸张 / 物体），再在同一图像上下文中发 400 token 请求逐行流式转写。问句使用“照片里的文字”以免模型复读提问词；若转写达到 400 token 上限，按失败截断并回退至 Apple Vision。
4. **联网请求与 Apple Vision**：联网服务采用单次请求，首行完整匹配分类词时从第二行开始朗读，普通标题保留，模型单独回答“无”表示未识别到文字；Apple Vision 直接识别原始照片，不经过模型所需的 JPEG 缩放和编码，结果按原文朗读。

提示词定义在 `PRTS/Features/TextReading/Services/TextReadingPrompt.swift`：

| 符号 | 用途 |
|---|---|
| `system` | 本机模型系统提示词，约束逐字转写、阅读顺序与输出格式 |
| `surfaceQuestion` | 本机模型第一步：判断文字所在的物体类别 |
| `copyQuestion` | 本机模型第二步：在同一图像上下文中转写文字 |
| `remoteSystem` | 联网服务系统提示词：首行分类，次行起转写 |
| `remotePrompt` | 联网识别用户消息：“读出照片里的文字。” |

实现位于 `PRTS/Features/TextReading/`（服务枚举定义在 `PRTS/Shared/Intelligence/TextReadingService.swift`）：

| 文件 | 职责 |
|---|---|
| `TextReadingSession.swift` | 管理采集、识别与朗读生命周期；结束或取消后拒绝迟到回调 |
| `Capture/TextCamera.swift` | 管理后置主摄、预览回调与照片采集 |
| `Services/TextReadingServices.swift` | 读取服务配置，封装可注入的时钟、编码与识别调用 |
| `Services/TextReadingBackend.swift` | 发出本机与联网请求，处理模型输出与控制标记 |
| `Services/TextReadingAnswer.swift` | 解析分类词与逐句朗读分片，保留普通 `<` 等原文符号 |
| `Services/TextReadingFallback.swift` | 执行识别服务三级回退 |
| `Services/TextReadingPrompt.swift` | 定义本机与联网识别提示词 |
| `Services/TextRecognizer.swift` | 调用系统 Apple Vision 识别文字 |

> [!NOTE]
> 部分自定义或思考型服务会把思考内容写入 `content`。本机封装在遇到孤立 `</think>` 时停止输出（并在流式回调前暂存潜在标签前缀）；联网层仅在开头 `<think>…</think>` 后紧跟有效分类词或“无”时移除思考前缀，正文中的普通 `<` 和成对标签按原文朗读。

## 本地视觉模型

| 项目 | 规格 |
|---|---|
| 来源 | `openbmb/MiniCPM-V-4.7-1B-gguf`（主模型 `Q5_K_M` 约 752 MB + 视觉投影权重约 1.1 GB，包含 BF16 和 F32 张量） |
| 推理引擎 | llama.cpp（固定提交 `620d222`），使用 mtmd，真机推理启用 Metal |
| 解码参数 | 贪心解码，描述最多 160 token，切片上限 9 |

切片上限读取自 mmproj 元数据 `clip.vision.max_slice_nums`（模型选型对比见[验证结果](validation.md#本地视觉模型)）。`Packages/LocalVLM/prepare.sh` 校验两份模型文件，并将推理引擎编译为 `PRTSLocalVLM.xcframework`（见[模拟器推理后端](development.md#模拟器推理后端)）。构建应用时，模型文件通过 `cp -c` 以 APFS 文件克隆方式复制进 `PRTS.app/LocalVLM/`，路径由 `PRTS/Shared/Intelligence/PhotoLocalModel.swift` 解析。

`Packages/LocalVLM` 对外提供 `describe` 与复用视觉编码的 `ask` 两个流式接口。模型首次调用时加载并常驻内存，所有请求在单串行队列排队执行，取消在两个 token 之间生效，并确保回调不会截断多字节 UTF-8 字符。

## 图像规格与数据安全

送入视觉模型的图像经 `PRTS/Shared/Imaging/PhotoImageEncoder.swift` 转正并按以下规范缩放，回答统一通过 `SpeechVoice.utterance` 按当前音色、语言与语速朗读：

| 功能 | 最长边上限（默认 / 高分辨率） | JPEG 质量 |
|---|---|---|
| 短按描述 | 1280 px / 1280 px | 0.8 |
| 语音提问与模型读文字 | 1280 px / 1920 px | 0.8 |
| 流式字幕 | 固定 960 px | 0.5 |

- **凭据与传输**：API Key 分服务商保存在钥匙串（访问级别 `WhenUnlockedThisDeviceOnly`；千问保留旧账户名 `api-key`）；自定义服务按 HTTPS 主机和端口保存，更改模型或同源路径不需要重新输入。旧版自定义密钥没有接收方记录，请为原地址重新保存一次。网络层仅允许 HTTPS，拒绝重定向并禁用缓存与 Cookie。
- **数据留存**：Release 构建不将图像、录音和问答写入磁盘；Dev 自动录制数据仅存本机供手动导出（见[开发指南](development.md#自动录制)）。选择本机提问时强制使用本机语音识别，不可用时无法发起并播报提示，不回退联网；联网提问可能使用 Apple 语音识别服务。
- **联网许可的生效时间**：每次发起描述、提问、读文字或开启流式字幕时检查许可。更改设置只影响下一次操作；已经开启的字幕会话可继续发送后续画面，直到退出。

## 已知限制

- 本地模型通过 mmap 加载并常驻内存，收到内存警告时仅记日志不卸载；尚未在 8 GB 内存机型（如 iPhone 15 Pro）验证与 ARKit 长期并行时的发热与内存峰值。
- 文字识别尚未系统覆盖强反光、大角度倾斜、远处极小字、手写体以及整页密集印刷文档。
- 尚未验证三指读文字手势与主按钮长按停止手势之间的边界冲突。
