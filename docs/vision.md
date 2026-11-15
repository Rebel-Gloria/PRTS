# 图像与文字识别

PRTS 的画面描述、语音提问和文字识别默认由随包携带的 MiniCPM-V 4.7 1B 离线执行，也可按功能分别切换到联网大模型或 Apple Vision；流式字幕由于动作理解准确性要求，固定使用通义千问。这些视觉功能与 `SpatialCore` 避障算法完全解耦。

## 服务路由与设置

用户可在“设置 → 智能”中指定默认服务商，并为各服务商独立维护凭据与高级开关：

| 服务商 | 默认模型与接口地址 | 思考参数配置 |
|---|---|---|
| 本机（默认） | MiniCPM-V 4.7 1B | 空思考段 |
| 通义千问 | `qwen3.8-flash`（`maas.qianwenaiapi.com/compatible-mode/v1/chat/completions`） | 默认关闭（`enable_thinking: false`） |
| DeepSeek | `deepseek-flash`（`api.deepseek.com/chat/completions`） | 默认关闭（`thinking: {type: disabled}`） |
| 自定义 | 用户指定的 HTTPS 兼容接口（仅填域名基础路径时自动补全 `/chat/completions`） | 仅发送标准字段 |

联网请求均采用兼容 OpenAI 的流式 Chat Completions 接口，照片以 `data:image/jpeg;base64` 传入。客户端仅提取首个 choice 的 `delta.content`，丢弃思考过程，待整段回答完整返回后再开始朗读；若中途断流、缺少结束标记或触发长度上限，未完回答会被丢弃并播报失败（流式字幕则静默跳过该句）。

- **通义千问 Omni 开关**（`photoDescription.qwenOmni`，默认关闭）：开启后所有千问请求改走 `qwen3.8-omni-flash`，准确率提高但单次延迟更长。因该模型默认会输出长段思考，客户端仍强制关闭思考。
- **提问时深度思考**（`photoDescription.questionThinking` / `.deepseek`，默认关闭）：仅在语音提问时生效。实测开启后延迟显著飙升而质量未见稳定收益，因此默认关闭。
- **本机增强模式**（`photoDescription.localEnhanced`，默认关闭）：开启后本机语音提问复用联网版提问提示词，允许更发散的细节描述。

### 按功能配比

描述画面（`intelligence.provider.description`）、语音提问（`intelligence.provider.question`）和读文字（`ocr.service`）默认跟随默认服务商；`ocr.service` 设为 `vision` 时直接走系统离线 OCR。`IntelligenceFeature` 在每次触发时读取最新配置并校验上传许可与 API Key。公共请求层位于 `PRTS/Shared/Intelligence/`，业务协调器仅通过协议调用后端。

## 提示词设计

短按描述和语音提问提示词写在 `PRTS/Features/PhotoDescription/Services/PhotoPrompts.swift`，流式字幕提示词写在 `PRTS/Features/LiveCaption/Services/LiveCaptionPrompts.swift`：

| 场景 | 符号 | 核心约束 |
|---|---|---|
| 短按描述 | `PhotoPrompts.system` | 用户消息固定为“描述眼前。”。先说最近物体和路面，限制 1–2 句、40 字内，禁用模糊距离估算和通行建议 |
| 语音提问（联网 / 本机增强） | `PhotoPrompts.questionSystem` | 直接回答问题本身（颜色、数量、文字、翻译等），最多 3 句，不代替用户做通行决策 |
| 语音提问（本机常规） | `PhotoPrompts.localQuestionSystem` | 沿用短按描述的防幻觉规则并附带问答示例，最多 3 句 |
| 流式字幕开场 | `LiveCaptionPrompts.opening` | 用户消息固定为“描述眼前。”。一句话说明所处位置与面前主要物体，≤ 20 字 |
| 流式字幕动作 | `LiveCaptionPrompts.system` | 接收 6–21 帧视频及上一句文本，仅描述新发生的动作，≤ 24 字；静止时只返回“无” |

语音提问直接将系统语音识别出的原文送给模型，不额外包裹提示前缀；回答通过 `threeSentences` 在第三个句末标点处强制截断。所有提示词均禁止模型猜测米数或给出“可以往前走”之类的安全承诺；更多提示词评测数据见[验证结果](validation.md#拍照描述与提问)。

## 流式字幕

流式字幕把相机画面拼成短视频段发给通义千问，其他后端由于在测试中容易对静态场景编造动作而未开放。核心实现位于 `PRTS/Features/LiveCaption/`（按键连按仲裁参见[工程架构](architecture.md#拍照按键分发链路)）。

### 采样与发送节拍

1. **启动**：先播报“流式字幕已开启，再次点按退出”，同时将当前首帧作为单图发出，生成最多 40 token 的开场句，在启动提示读完后播出。
2. **滑动采样**：随后每 0.1 s 从当前采集端抽取一帧，保存最长边 960 像素、质量 0.5 的 JPEG 以及一张 48×64 灰度图，只保留最近 2 s 内的最多 20 帧。
3. **固定发送**：每 2 s 固定发一次视频请求（上限 24 token，关闭思考），静止时由模型回答“无”。
4. **运动自适应抽帧**：每段视频包含上一段的最后一帧以及本次窗口的新帧（总计不少于 4 帧）。新帧数量根据窗口内相邻灰度图平均差的总和线性插值：总运动量 ≤ 30 时抽 5 帧，≥ 150 时抽满 20 帧（10 fps），按累计运动量等分点挑帧以避开重复画面。

### 并发与输出过滤

因为单次网络往返常超过 2 s，系统允许最多 3 个字幕请求并发在途，超出时跳过本拍；单次报错静默跳过，连续失败 3 次才播报错误并退出。先发后至的过时回复会被序号丢弃；若上一句仍在朗读，仅缓存最新一条结果等待顺延播出。

`LiveCaptionPolicy.answer` 只取返回的首行，遇到以下情形静默忽略：回答“无”或“无。”、超过 24 字、触发 token 截断、包含“照片 / 画面 / 镜头”等元描述词汇，或与上一句完全相同。

## 文字识别

读文字服务在一次交互内依次按“选定后端 → 本机模型 → Apple Vision”三级回退（若直接选定 Apple Vision 则无回退），全部失败才播报“读文字失败，请重试”。当触发远端超时、网络错误或主动取消（包括 `URLError.cancelled`）时，立刻清理资源并终止流程。

### 识别流程与解析边界

1. 暂停 ARKit 或普通 RGB 采集，切换至预配置好的后置主摄。启动后若 10 s 内未完成对焦稳定并拍照，则播报“无法打开相机”并退出。
2. 收到首帧后等待 1 s 待对焦和曝光稳定，拍照并触发反馈振动。
3. **本机两次提问**：先发 8 token 短问判断文字载体的类别（路标 / 牌子 / 纸张 / 物体），再复用同一组视觉特征向同一会话发 400 token 转写请求逐行流式朗读。问句刻意写成“照片里的文字”，避免模型把提问词当成待抄录文字；若转写达到 400 token 上限，判定为失败截断并自动回退至 Apple Vision。
4. **联网单次请求**：提示词要求模型首行输出载体分类、次行起逐字抄录，格式不符合约定时同样回退。

由于模型偶尔会在回答前夹带 `<think>…</think>` 标签，或将思考泄漏到正文末尾：本机封装会在遇到孤立 `</think>` 时截断停止（并在流式回调前暂存潜在标签前缀防止误读）；联网适配层仅在 `<think>…</think>` 后紧跟有效分类词或“无”时剥离前置思考段，正文里的正常 `<` 和成对标签保持原文朗读。

## 本地视觉模型

| 配置项 | 当前规格 |
|---|---|
| 模型与来源 | `openbmb/MiniCPM-V-4.7-1B-gguf`（主模型 `Q5_K_M` 约 752 MB + `mmproj` FP16 约 1.1 GB） |
| 推理引擎 | llama.cpp（固定提交 `620d222`），启用 mtmd 与 Metal 加速 |
| 解码参数 | 贪心解码，描述最多 160 token，动态切片上限 9 |

切片上限直接读取 mmproj 元数据 `clip.vision.max_slice_nums`（模型对比结果见[验证结果](validation.md#本地视觉模型)）。该模型与 llama.cpp 由 `Packages/LocalVLM/prepare.sh` 编译为支持真机与 arm64 模拟器的 `PRTSLocalVLM.xcframework`（构建说明见[开发指南](development.md#构建)），Xcode 构建时通过 `cp -c` 以 APFS 克隆方式打入 `PRTS.app/LocalVLM/`。

`Packages/LocalVLM` 对外暴露 `describe` 与在同一图像上下文内追问的 `ask` 两个流式接口。模型在首次调用时懒加载并常驻内存，所有推理请求在单串行队列排队执行，取消标志在 token 间隔生效，并确保不会在多字节 UTF-8 字符中间截断回调。

## 图像规格与隐私边界

所有拍照和流式字幕图像统一经 `PRTS/Shared/Imaging/PhotoImageEncoder.swift` 转正和缩放：

| 功能 | 最长边限制（默认 / 高分辨率） | JPEG 质量 |
|---|---|---|
| 短按描述 | 1280 px / 1280 px | 0.8 |
| 语音提问与读文字 | 1280 px / 1920 px | 0.8 |
| 流式字幕 | 固定 960 px | 0.5 |

- **凭据安全**：API Key 分服务商保存在钥匙串（`WhenUnlockedThisDeviceOnly`；千问保留 `api-key` 账户名以兼容升级），网络层强制 HTTPS、禁用重定向、Cookie 与缓存。
- **数据留存**：Release 构建不落盘任何照片、语音和问答文本；Dev 构建自动录制的数据仅存本机供手动导出（见[开发指南](development.md#自动录制)）。调用语音提问时，系统语音识别可能会连接 Apple 服务。

## 已知限制

- 本地 VLM 权重通过 mmap 加载，首次加载后常驻内存直到进程退出；收到内存警告时仅记日志不主动卸载，尚未在 8 GB 内存机型（如 iPhone 15 Pro）验证与 ARKit 长期并发的发热和内存峰值。
- 文字识别尚未系统覆盖强反光、大角度倾斜、远处极小字、手写体以及整页密集印刷文档。
- 尚未验证三指读文字手势与主按钮长按停止手势之间的边界冲突。
