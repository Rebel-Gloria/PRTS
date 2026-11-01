# 图像与文字识别

本文介绍拍照描述、语音提问和文字识别的实现，包括模型服务、提示词、本地视觉模型和数据处理方式。操作方式请参阅[功能与操作](usage.md)。

这两项功能默认使用随应用打包的 MiniCPM-V 4.7 1B，在设备上离线运行。用户也可以选择联网服务。视觉模型不参与避障，避障由 `SpatialCore` 独立完成。

## 模型服务

在“设置 → PRTS intelligence → 智能设置”中选择服务：

| 服务 | 模型与接口 | 默认思考设置 |
|---|---|---|
| 本机（默认） | MiniCPM-V 4.7 1B | 空思考段 |
| 通义千问 | `qwen3.8-flash`，`maas.qianwenaiapi.com/compatible-mode/v1/chat/completions` | `enable_thinking: false` |
| DeepSeek | `deepseek-flash`，`api.deepseek.com/chat/completions` | `thinking: {type: disabled}` |
| 自定义 | 用户指定的模型和 HTTPS 地址；仅填写基础地址时自动补全 `/chat/completions` | 仅发送标准字段 |

联网服务使用兼容 OpenAI 的流式 Chat Completions 请求，照片以 `data:image/jpeg;base64` 形式写入请求正文。应用只读取第一个 choice 的 `delta.content`，忽略思考内容，并在收到完整回答后开始朗读。连接中断或缺少结束标志时，未完成的回答会被丢弃。

开启“提问时深度思考”后，千问请求发送 `enable_thinking: true`，DeepSeek 请求发送 `thinking: {type: enabled}`。该设置只影响语音提问，自定义服务和本机服务不提供此选项。测试中开启后等待时间明显增加，质量没有稳定提升，因此默认关闭。

模型后端由 `Services/PhotoDescriptionBackend.swift` 选择，协调器只通过 `PhotoDescriptionServices` 调用，不直接依赖网络或推理实现。

## 提示词

提示词定义在 `PRTS/Features/PhotoDescription/Services/PhotoPrompts.swift` 中：

| 场景 | 系统提示词 | 约束 |
|---|---|---|
| 短按描述 | `PhotoPrompts.system` | 用户消息固定为“描述眼前。”。先说明最近的物体及其位置，再说明路面；一到两句，四十字以内 |
| 语音提问（联网服务） | `PhotoPrompts.questionSystem` | 直接回答问题，可以描述颜色、穿着、数量、文字和用途，也可以翻译；最多三句 |
| 语音提问（本机服务） | `PhotoPrompts.localQuestionSystem` | 在描述提示词的基础上调整，以问答示例约束回答细节；最多三句 |

语音提问直接发送语音识别的原文，不添加前缀。提问的回答由 `threeSentences` 在第三句结束处截断。

所有提示词都要求只描述可见内容，不编造、不估计米数、不给出通行许可或绕行建议，无法判断时明确说明。

> [!NOTE]
> 提示词无法完全消除模型错误，台阶方向和“能否通行”类问题尤其容易出错。通行判断应以避障功能为准。各版本提示词的评估结果请参阅[验证结果](validation.md#拍照描述与提问)。

## 文字识别

文字识别提供两种服务，在“设置 → 识别服务”中选择：

| 服务 | 处理方式 | 失败时 |
|---|---|---|
| VLLM（默认） | 跟随智能设置中的服务商。本机模型分两次完成分类和转写；千问并行调用分类模型（`qwen3.8-flash`）和转写模型（`qwen-vl-ocr`）；其他联网服务在一次请求中完成分类和转写 | 远端不可用时静默改用本机模型，本机模型失败后改用 Apple Vision |
| Apple Vision | 系统离线文字识别，不判断物体类型，统一使用“你面前的物体上写着” | 不调用其他服务 |

远端请求须同时满足以下条件：已选择联网服务、已允许上传照片、已保存 API Key。配置不完整或未允许上传时，直接在本机识别。连接失败、超时或远端返回错误时，按固定顺序回退，不提示切换，也不修改服务商设置。取消识别会终止当前请求，不再发起回退请求。

旧版“本地 VLM”和“远端 API”选项统一迁移为 VLLM；原先选择 Apple Vision 的用户保持原设置。

### 本地识别流程

1. 停止 ARKit 会话，改用后置主摄。相机在应用启动时预先配置，从开始识别到显示预览约 0.3 s；10 s 内未收到图像时，提示“无法打开相机”并退出。
2. 收到第一帧后等待 1 s，使对焦和曝光稳定，然后自动拍照并振动。
3. 将照片缩放至最长边 1280 像素，向模型提问：文字位于路标、牌子、纸张还是物体上。只接受这四种回答。
4. 在同一对话中继续提问，转写照片里的文字；没有文字时回答“无”。此步骤复用已编码的图像，不重新进行视觉编码。
5. 转写结果按行或句逐步朗读，无须等待全部生成。

提示词使用“照片里的文字”而不是“上面的文字”，以免模型将问题本身当作待转写内容。生成上限为 400 个 token，无法保证完整覆盖一整页密集文字。

文字识别的提示词定义在 `PRTS/Features/TextReading/Services/TextReadingPrompt.swift` 中：

| 提示词 | 用途 |
|---|---|
| `system` | 本机模型的系统提示词，约束逐字转写、阅读顺序和输出格式 |
| `surfaceQuestion` | 判断文字所在的物体；本机模型和千问分类请求共用 |
| `copyQuestion` | 本机模型在同一图像上下文中转写文字 |
| `remoteSystem` | 无专用 OCR 模型的联网服务，第一行分类，其余行转写 |
| `remotePrompt` | 联网识别的用户消息：“读出照片里的文字。” |
| `ocrSystem` | 专用 OCR 模型的系统提示词，只转写文字，不输出分类 |

拍照描述、语音提问和文字识别共使用上述两个文件中的 10 条固定提示词。语音提问另接收用户的识别原文；Apple Vision 不使用提示词。`Vendor/PRTSCore` 中的旧模型提示词未接入当前应用。

实现位于 `PRTS/Features/TextReading/`：`TextReadingSession.swift` 管理一次识别的生命周期，`Capture/TextCamera.swift` 管理主摄，`Services/` 包含提示词、回答解析、服务选择和 Vision 识别。

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

如需准备模型和推理库，请在安装了 cmake 和 ninja 的 Mac 上运行：

```sh
bash Packages/LocalVLM/prepare.sh
```

该脚本编译 llama.cpp 和 `csrc/` 中的封装，生成包含真机和模拟器（仅 arm64）的 `Packages/LocalVLM/PRTSLocalVLM.xcframework`，并下载两个权重文件、校验 SHA-256。权重保存在 `models/MiniCPM-V-4.7-1B/`。编译产物和权重均不纳入版本控制。在 8 GB 内存的 Mac 上，脚本默认使用 `-j 2`，可通过环境变量 `JOBS` 修改。

构建应用时，Xcode 的“Copy offline model”阶段使用 `cp -c` 将权重复制到 `PRTS.app/LocalVLM/`。在 APFS 上该操作创建文件克隆，不会立即占用额外空间。权重使安装包增加约 1.9 GB。

### 推理接口

`Packages/LocalVLM` 提供两个接口：

- `describe`：接收一张照片和一个问题，返回回答。
- `ask`：在同一图像上下文中继续提问，无须重新进行视觉编码。

两个接口都支持流式输出，并保证不会截断 UTF-8 字符。模型在首次请求时加载，之后常驻内存。所有请求在同一串行队列上执行，取消在两个 token 之间生效。模型偶尔在回答后输出 `</think>` 并继续生成，推理封装在该标记处停止，应用也会丢弃 `<` 之后的内容。

`PRTS/Features/PhotoDescription/Services/PhotoLocalModel.swift` 指定安装包中的模型路径。

## 图像与数据处理

拍照描述直接使用 ARKit 当前帧，不另外打开相机。图像转正后保留完整画面，最长边缩放到 1280 像素，以 0.8 的质量编码为 JPEG。

| 数据 | 处理方式 |
|---|---|
| API Key | 按服务分别存储在钥匙串中，访问级别为 `WhenUnlockedThisDeviceOnly`。千问保留旧账户名 `api-key` 以兼容已有配置 |
| 网络请求 | 仅允许 HTTPS，拒绝重定向，不使用缓存或 Cookie |
| 照片、录音、问题和回答 | 仅保存在内存中，不写入诊断记录或文件 |
| 语音识别 | 使用系统语音识别，即使选择本机服务，也可能调用 Apple 的服务 |

回答通过 `SpeechManager.announcementUtterance` 朗读，使用应用当前的音色、语言和语速。

## 已知限制

- 模型加载后不会主动释放，尚未处理内存警告。
- 尚未验证与 ARKit 同时运行时的资源占用、连续调用时的发热，以及 8 GB 内存的 iPhone 15 Pro。
- 权重通过 mmap 加载，文件大小不等于 `phys_footprint` 中计入的内存。
- 文字识别尚未覆盖反光、倾斜、远处小字、手写和整页密集文字。
- 尚未检查三指手势与长按停止手势之间的冲突。
