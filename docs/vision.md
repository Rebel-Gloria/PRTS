# 图像与文字识别

本文介绍拍照描述、语音提问、流式字幕和文字识别的实现，包括模型服务、提示词、本地视觉模型和数据处理方式。操作方式请参阅[功能与操作](usage.md)。

拍照描述、语音提问和文字识别默认使用随应用打包的 MiniCPM-V 4.7 1B，在设备上离线运行，也可以改用联网服务；流式字幕使用通义千问。视觉模型不参与避障，避障由 `SpatialCore` 独立完成。

## 模型服务

在“设置 → 智能”中选择默认服务商，并在“服务商设置”中为每个服务商分别配置：

| 服务 | 模型与接口 | 默认思考设置 |
|---|---|---|
| 本机（默认） | MiniCPM-V 4.7 1B | 空思考段 |
| 通义千问 | `qwen3.8-flash`，`maas.qianwenaiapi.com/compatible-mode/v1/chat/completions` | `enable_thinking: false` |
| DeepSeek | `deepseek-flash`，`api.deepseek.com/chat/completions` | `thinking: {type: disabled}` |
| 自定义 | 用户指定的模型和 HTTPS 地址；仅填写基础地址时自动补全 `/chat/completions` | 仅发送标准字段 |

联网服务使用兼容 OpenAI 的流式 Chat Completions 请求，照片以 `data:image/jpeg;base64` 形式写入请求正文。应用只读取第一个 choice 的 `delta.content`，忽略思考内容，并在收到完整回答后开始朗读。连接中断、缺少结束标志或服务端报告回答被截断时，未完成的回答会被丢弃；描述和提问会播报失败提示，流式字幕的处理见下文。本机模型达到 token 上限时同样按截断处理。

通义千问的设置页提供默认关闭的“使用 Omni 模型”（`photoDescription.qwenOmni`）。开启后，描述、提问、流式字幕和读文字都改用 `qwen3.8-omni-flash`，价格不变，准确度较高，但耗时增加。该模型默认开启思考，因此请求必须发送 `enable_thinking: false`。

开启“提问时深度思考”后，千问请求发送 `enable_thinking: true`，DeepSeek 请求发送 `thinking: {type: enabled}`。该开关按服务商分别保存：千问使用 `photoDescription.questionThinking`，DeepSeek 使用 `photoDescription.questionThinking.deepseek`。该设置只影响语音提问，自定义服务和本机服务不提供此选项。测试中开启后等待时间明显增加，质量没有稳定提升，因此默认关闭。

本机服务的设置页提供默认关闭的“增强模式”，开启后本机语音提问改用联网服务的提问提示词，见下文“提示词”。

### 服务配比

描述画面、语音提问和读文字可以分别选择服务商，默认跟随默认服务商。选择保存在 `intelligence.provider.description`、`intelligence.provider.question` 和 `ocr.service` 中，没有保存值时跟随默认服务商；`ocr.service` 为 `vlm` 时同样跟随默认服务商，为 `vision` 时使用 Apple Vision。`IntelligenceFeature` 负责按功能解析服务商，拍照描述在确定是短按还是提问后检查对应服务商的上传许可和 API Key。

流式字幕固定使用通义千问，与默认服务商无关，开始前要求允许发送照片并已保存千问的 API Key。

请求、凭据和本机模型的公共实现位于 `PRTS/Shared/Intelligence/`。拍照描述的模型后端由 `PhotoDescription/Services/PhotoDescriptionBackend.swift` 选择，协调器只通过 `PhotoDescriptionServices` 调用，不直接依赖网络或推理实现。

## 提示词

拍照描述和语音提问的提示词定义在 `PRTS/Features/PhotoDescription/Services/PhotoPrompts.swift` 中，流式字幕的提示词定义在 `PRTS/Features/LiveCaption/LiveCaptionPrompts.swift` 中：

| 场景 | 系统提示词 | 约束 |
|---|---|---|
| 短按描述 | `PhotoPrompts.system` | 用户消息固定为“描述眼前。”。先说明最近的物体及其位置，再说明路面；一到两句，四十字以内 |
| 流式字幕开场 | `LiveCaptionPrompts.opening` | 用户消息固定为“描述眼前。”。一句话说明地点和面前主要的一两样东西，最多 20 字 |
| 流式字幕动作 | `LiveCaptionPrompts.system` | 输入 4～6 帧视频和上一句。只说谁或什么做了什么动作，最多 24 字；没有明显动作时只输出“无” |
| 语音提问（联网服务） | `PhotoPrompts.questionSystem` | 直接回答问题，可以描述颜色、穿着、数量、文字和用途，也可以翻译；最多三句 |
| 语音提问（本机，增强模式关闭） | `PhotoPrompts.localQuestionSystem` | 在描述提示词的基础上调整，以问答示例约束回答细节；最多三句 |
| 语音提问（本机，增强模式开启） | `PhotoPrompts.questionSystem` | 复用联网提问提示词，允许更广泛的细节、翻译与解释；最多三句 |

语音提问直接发送语音识别的原文，不添加前缀。提问的回答由 `threeSentences` 在第三句结束处截断。

`PhotoPrompts.localSystem` 在每次本机请求时读取 `photoDescription.localEnhanced`：没有问题时使用 `system`，有问题时根据开关选择 `localQuestionSystem` 或 `questionSystem`。联网提问继续使用 `questionSystem`；OCR 始终使用 `TextReadingPrompt`，包括远端失败后的本机回退。增强模式不增加新的固定提示词。

描述和提问提示词要求只描述可见内容，不编造、不估计米数、不给出通行许可或绕行建议，无法判断时明确说明。流式字幕提示词禁止猜测身份、情绪和目的，不判断能否通行。文字识别提示词只要求按原样转写。

> [!NOTE]
> 提示词无法完全消除模型错误，台阶方向和“能否通行”类问题尤其容易出错。通行判断应以避障功能为准。各版本提示词的评估结果请参阅[验证结果](validation.md#拍照描述与提问)。

## 流式字幕

流式字幕以视频的形式向千问发送画面。其他服务在测试中会编造动作，因此该功能不跟随服务配比，配置要求见上文“服务配比”。实现位于 `PRTS/Features/LiveCaption/`：`LiveCaptionSession.swift` 管理采样、请求和朗读，并先对拍照按键做连按判定（见[工程架构](architecture.md#拍照按键)），`LiveCaptionFrame.swift` 处理采样帧，`LiveCaptionPolicy.swift` 处理回答和调度，`LiveCaptionBackend.swift` 组装请求。

### 请求流程

1. 开始时播报“流式字幕已开启，按一下退出”，同时以第一帧发出单图请求生成开场句，生成上限为 40 个 token。开场句在启动播报读完后朗读。
2. 之后每 0.1 s 取一次 ARKit 当前帧，只保留最近 2 s 的最多 20 帧。每帧保存 720×960、质量 0.5 的 JPEG 和 48×64 灰度图。
3. 无论画面是否变化，每 2 s 发送一次视频，并附上一句文字。生成上限为 24 个 token，关闭深度思考。没有动作时由模型回答“无”。
4. 每次视频由新画面和上一次视频的最后一帧组成，至少 4 帧。新画面的帧数按窗口内的累计运动量决定：运动量不超过 30 时为 5 帧，不低于 150 时为 20 帧（相当于 10 帧每秒），两者之间按比例增加。

运动量为相邻两帧灰度图逐像素绝对差的平均值。以窗口首帧为起点累计运动量，在总量的等分点处依次选择累计值最近且尚未选中的帧；画面完全静止时按时间等分。

### 调度与回答处理

请求耗时通常长于 2 s，因此请求可以重叠，最多 3 个同时进行，超过时跳过本次发送。单次请求失败时跳过，下一次继续发送；连续失败 3 次时播报错误并退出字幕，成功一次后重新计数。请求可能乱序返回，比已处理结果更早发出的回答会被丢弃。上一句仍在朗读时，只保留最新的一条回答，读完后朗读。

开场句通常直接朗读，达到 40 个 token 的上限时跳过，字幕继续运行。动作句由 `LiveCaptionPolicy.answer` 处理，只取第一行，以下情况不朗读：

| 情况 | 说明 |
|---|---|
| 回答为“无”或“无。” | 画面中没有动作 |
| 超过 24 字，或达到生成上限 | 不朗读，字幕继续运行 |
| 包含“照片”“画面”或“镜头” | 模型在描述画面而不是动作 |
| 与上一句相同 | 重复描述 |

## 文字识别

文字识别的服务在“设置 → 智能 → 服务配比 → 读文字”中选择：

| 服务 | 处理方式 | 失败时 |
|---|---|---|
| 跟随默认服务商（默认），或指定服务商 | 使用所选服务商。本机模型分两次完成分类和转写；联网服务在一次请求中完成分类和转写 | 远端不可用时静默改用本机模型，本机模型失败后改用 Apple Vision |
| Apple Vision | 系统离线文字识别，不判断物体类型，统一使用“你面前的物体上写着” | 不调用其他服务 |

所选服务商为联网服务、允许上传照片并保存了该服务商的 API Key 时，先使用远端识别；否则直接在本机识别。远端连接失败、超时或返回错误时改用本机模型，本机模型失败时改用 Apple Vision。所有服务都失败或照片无法编码时，应用播报“读文字失败，请重试”，并丢弃尚未读出的文字。取消识别会结束整个过程，包括网络层以 `URLError.cancelled` 报告的取消。

旧版的“远端 API”选项按“跟随默认服务商”处理，“本地 VLM”按“本机”处理。

### 本地识别流程

1. 停止 ARKit 会话，改用后置主摄。相机在应用启动时预先配置，从开始识别到显示预览约 0.3 s；10 s 内未收到图像时，提示“无法打开相机”并退出。
2. 收到第一帧后等待 1 s，使对焦和曝光稳定，然后自动拍照并振动。
3. 按下文“图像与数据处理”的最长边规则缩放照片，向模型提问：文字位于路标、牌子、纸张还是物体上。应用在回答中查找这四个词，找不到时按“物体”处理。
4. 在同一对话中继续提问，转写照片里的文字；没有文字时回答“无”。此步骤复用已编码的图像，不重新进行视觉编码。
5. 转写结果按行或句逐步朗读，无须等待全部生成。

提示词使用“照片里的文字”而不是“上面的文字”，以免模型将问题本身当作待转写内容。转写的生成上限为 400 个 token；达到上限时按识别失败处理，停止朗读并改用 Apple Vision，因此无法保证完整覆盖一整页密集文字。判断物体这一步只有 8 个 token，超出时按已生成的内容查找这四个词，不影响转写。

文字识别的提示词定义在 `PRTS/Features/TextReading/Services/TextReadingPrompt.swift` 中：

| 提示词 | 用途 |
|---|---|
| `system` | 本机模型的系统提示词，约束逐字转写、阅读顺序和输出格式 |
| `surfaceQuestion` | 本机模型判断文字所在的物体 |
| `copyQuestion` | 本机模型在同一图像上下文中转写文字 |
| `remoteSystem` | 联网服务，第一行分类，其余行转写 |
| `remotePrompt` | 联网识别的用户消息：“读出照片里的文字。” |

实现位于 `PRTS/Features/TextReading/`：`TextReadingSession.swift` 管理一次识别的生命周期，`Capture/TextCamera.swift` 管理主摄，`Services/TextReadingServices.swift` 集中了会话用到的时钟、编码和识别调用，测试可以替换。`Services/` 中，`TextReadingPrompt.swift` 定义提示词，`TextReadingBackend.swift` 发出本机和联网请求，`TextReadingAnswer.swift` 解析分类和逐句输出，`TextReadingFallback.swift` 处理回退，`TextRecognizer.swift` 调用 Apple Vision。服务选择由 `PRTS/Shared/Intelligence/TextReadingService.swift` 定义。

## 本地视觉模型

| 项目 | 配置 |
|---|---|
| 来源 | `openbmb/MiniCPM-V-4.7-1B-gguf` |
| 语言模型 | `MiniCPM-V-4_7-1B-Q5_K_M.gguf`，约 752 MB |
| 视觉模块 | `mmproj-model-f16.gguf`，约 1.1 GB |
| 推理引擎 | llama.cpp，固定提交 `620d222`，启用 mtmd 和 Metal |
| 描述参数 | 贪心解码，最多 160 个 token，切片上限 9 |

切片上限由 mmproj 元数据 `clip.vision.max_slice_nums` 控制，修改时无须重新转换权重。切片上限为 9 时保留的画面细节最多；MiniCPM-V 4.6 和 Gemma 4 E2B 经对比后未采用，数据请参阅[验证结果](validation.md#本地视觉模型)。

### 准备与打包

模型和推理库由 `Packages/LocalVLM/prepare.sh` 准备。该脚本编译 llama.cpp 和 `csrc/` 中的封装，生成包含真机和模拟器（仅 arm64）的 `Packages/LocalVLM/PRTSLocalVLM.xcframework`，并下载两个权重文件、校验 SHA-256。权重保存在 `models/MiniCPM-V-4.7-1B/`。编译产物和权重均不纳入版本控制。运行方法请参阅[开发指南](development.md#构建)。

构建应用时，Xcode 的“Copy offline model”阶段使用 `cp -c` 将权重复制到 `PRTS.app/LocalVLM/`。在 APFS 上该操作创建文件克隆，不会立即占用额外空间。权重使安装包增加约 1.9 GB。

### 推理接口

`Packages/LocalVLM` 提供两个接口：

- `describe`：接收一张照片和一个问题，返回回答。
- `ask`：在同一图像上下文中继续提问，无须重新进行视觉编码。

两个接口都支持流式输出，并保证不会截断 UTF-8 字符。模型在首次请求时加载，之后常驻内存。所有请求在同一串行队列上执行，取消在两个 token 之间生效。模型偶尔在回答后输出 `</think>` 并继续生成，推理封装在该标记处停止；文字识别解析流式回答时还会丢弃 `<` 之后的内容。

`PRTS/Shared/Intelligence/PhotoLocalModel.swift` 指定安装包中的模型路径。

## 图像与数据处理

短按描述、语音提问和流式字幕使用 ARKit 当前帧，读文字使用后置主摄照片。图像转正后保留完整画面，最长边默认缩放至 1280 像素；开启“高分辨率”（`photoDescription.highResolution`，默认关闭）后，语音提问和读文字的最长边为 1920 像素，短按描述仍为 1280 像素。流式字幕固定为 960 像素。所有模型后端共用 `PRTS/Shared/Imaging/PhotoImageEncoder.swift`，以 0.8 的质量编码为 JPEG。

| 数据 | 处理方式 |
|---|---|
| API Key | 按服务分别存储在钥匙串中，访问级别为 `WhenUnlockedThisDeviceOnly`。千问保留旧账户名 `api-key` 以兼容已有配置 |
| 网络请求 | 仅允许 HTTPS，拒绝重定向，不使用缓存或 Cookie |
| 照片、录音、问题和回答 | 仅保存在内存中，不写入诊断记录或文件 |
| 语音识别 | 使用系统语音识别，即使选择本机服务，也可能调用 Apple 的服务 |

回答通过 `SpeechVoice.utterance` 朗读，使用应用当前的音色、语言和语速。

## 已知限制

- 模型加载后不会主动释放。收到内存警告时只写入诊断事件，不卸载模型。
- 尚未验证与 ARKit 同时运行时的资源占用、连续调用时的发热，以及 8 GB 内存的 iPhone 15 Pro。
- 权重通过 mmap 加载，文件大小不等于 `phys_footprint` 中计入的内存。
- 文字识别尚未覆盖反光、倾斜、远处小字、手写和整页密集文字。
- 尚未检查三指手势与长按停止手势之间的冲突。
