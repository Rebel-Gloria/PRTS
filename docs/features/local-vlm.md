# 本地视觉模型

结论：MiniCPM-V 4.7 1B 可以在 iPhone 17 Pro Max 上离线做拍照描述，每张约 2 秒，内存峰值约 1.6 GB。它只能用来描述画面，不能进避障：避障要求每秒 10 次、毫秒级、结果确定。它已经打包进 App，作为拍照描述的服务商"本机（离线）"，见下面"在 App 里"。

## 选哪个模型

**MiniCPM-V 4.7 1B**：Q5_K_M 语言模型（752 MB）加 F16 视觉模块（1.1 GB），权重合计约 1.9 GB。

切片上限用时间换质量，改 mmproj 元数据 `clip.vision.max_slice_nums` 就能调，不用重新转换权重：

- 9（官方默认）：每张约 1.9 秒，描述最好；
- 1：每张约 0.9 秒，仍比 4.6 好，但会漏掉贴近画面边缘的东西。

试过但没选的：

- **MiniCPM-V 4.6**：试过思考模式、放大图片、加切片，描述都没有变好，瓶颈在 0.8B 的语言部分。模型已删除。
- **Gemma 4 E2B**：比 4.7 慢，中文回答短，漏掉台阶、椅子和文字。

## 实测（iPhone 17 Pro Max，2026-10-29）

输入是 3 张实拍照片，按 `PhotoImageEncoder` 缩到 960×1280，用现在的 `PhotoChatProtocol.system`，贪心解码，热启动。

| 模型 | 视觉 token | 视觉编码 | 生成速度 | 每张总耗时 | 内存峰值 |
|---|---:|---:|---:|---:|---:|
| MiniCPM-V 4.7，切片上限 9 | 462 | 1.29–1.33 s | 85–87 token/s | 1.84–2.02 s | 1.56 GB |
| MiniCPM-V 4.7，切片上限 1 | 129 | 0.47–0.49 s | 83–85 token/s | 0.84–0.97 s | 1.56 GB |
| Gemma 4 E2B QAT Q4_0 | 540 | 2.24–2.26 s | 35 token/s | 2.75–2.85 s | 1.43 GB |
| 对照：4.6 Q5，切片上限 1 | 126 | 0.46 s | 81–87 token/s | 0.72–0.89 s | 1.54 GB |

回答对比：

| 照片 | 4.7，切片 9 | 4.7，切片 1 | Gemma 4 E2B |
|---|---|---|---|
| 自行车和台阶 | 正前方是一辆浅蓝色自行车，停在石阶旁的水泥地。台阶左边有柱子，右边有人站着…… | 近处是一辆蓝灰色自行车，停在台阶旁的地面上……右边是白色柱子。远处有两个人站着…… | 很近有一辆蓝色的自行车，前面是水泥路面。（漏了台阶） |
| 健身房地面 | 近处是一台黑棕相间的健身器械，右边是带轮的大风扇。地面干净，**左边有点椅子腿**。 | 近处是一台黑色健身器械，带棕色垫子。右边有个大风扇……（漏了椅子） | 很近有一台健身器材，后面是一个大型的黑色风扇。（漏了椅子） |
| 健身凳和 15KG 杠铃片 | **正前方是一台棕色靠背的健身凳**，下面有个 Hammer Strength 的 15kg 重量块……左边是 treadmill。 | 近处有一块15KG的 weights，旁边是棕色卧推凳…… | 很近是一台健身器材，后面是另一台。（没读出字） |

只有 4.7 切片 9 同时说出了"左边的椅子腿"和"正前方的健身凳"。它的毛病：

- 偶尔夹英文（"treadmill""weights"）；
- 把健身车说成跑步机；
- 没说台阶是向上还是向下。

样本只有 3 张。上线前要用 30 张实拍图，按致命错误的标准（编造、方向说反、指挥通行、漏掉贴近的东西）评一遍。

## 其他发现

- **冷启动约 3 秒**（加载加首张，含 Metal 着色器编译），可以在 App 启动后或进入拍照前预热。
- **内存比估算低得多**：估算 2.6–3.1 GB，实测 1.5 GB 左右。权重是 mmap 映射的，干净的文件页不算进 `phys_footprint`，而系统是按 `phys_footprint` 决定要不要杀掉 App 的。
- **8 GB 的 iPhone 15 Pro 还没测过。**

## 怎么复现

- 模型来源：
  - `openbmb/MiniCPM-V-4.7-1B-gguf` 的 `MiniCPM-V-4_7-1B-Q5_K_M.gguf` 和 `mmproj-model-f16.gguf`；
  - `google/gemma-4-E2B-it-qat-q4_0-gguf`（Google 官方 QAT Q4_0）加 mmproj。
- 下载后和 Hugging Face 上的 SHA-256 核对。Mac 上放在 `models/`，这个目录被 git 忽略。
- 每个模型放一个文件夹 `Documents/vlm/models/<名字>/`，里面放语言模型，再放一个文件名带 `mmproj` 的视觉模块。用 `xcrun devicectl device copy to --domain-type appDataContainer` 拷进手机。
- 测试在 `PRTSTests/LocalVLMBenchmarkTests`：
  - `photos()`：结果写到 `Documents/vlm/photos-<名字>.json`；
  - `photosThinking()`：开思考模式；
  - `prompts()`：对比提示词变体；
  - `promptsCloud()`：云端对照，需要手机上存了 Key。
- 测试要链接 llama.cpp 的 mtmd 库，库会按 `general.architecture` 选择 Gemma 或 MiniCPM 的对话模板。这个库不在仓库里，构建时要额外传 `OTHER_LDFLAGS` 和 `SWIFT_INCLUDE_PATHS`。

## 在 App 里

因为要考虑没有网络的场景，模型直接打包进安装包，不在设置里另外下载。代价是安装包多了约 1.9 GB。

- **准备**：`zsh Vendor/LocalVLM/prepare.sh`。它做两件事：
  - 把 llama.cpp（固定提交 `620d222`，带 mtmd 和 Metal）和 `csrc/` 里的 C 封装编成 `Vendor/LocalVLM/PRTSLocalVLM.xcframework`，真机和模拟器各一份；
  - 把两个权重文件下载到 `models/MiniCPM-V-4.7-1B/`，用 Hugging Face 上的 SHA-256 校验。
  
  两样都不进 git。需要 cmake 和 ninja（`pip install cmake ninja` 或 Homebrew）。在 8 GB 的 Mac 上默认 `-j 2`，第一次要编几分钟。
- **代码**：
  - `Vendor/LocalVLM` 是一个本地 Swift 包。`LocalVLM` 第一次用时加载模型，之后一直留在内存里，所有调用排队在一个串行队列上，取消时在两个 token 之间停下；
  - `PRTS/PhotoDescription/PhotoLocalModel.swift` 指向安装包里的权重；
  - 解码、对话模板和基准测试一样：贪心解码，最多 160 个 token，切片上限用官方默认的 9。
  - 封装有两个调用：`describe` 看一张照片回答一个问题；`ask` 对同一张照片接着追问，图已经在上下文里，不用再看一遍。两个都可以边生成边把文字交给 App，按完整的 UTF-8 字符切开。文字识别就是先 `describe` 问字写在什么上面，再 `ask` 让它照抄，见 [文字识别](text-reading.md)；
  - 小模型偶尔答完后自己写一个 `</think>` 再编一轮回答，封装看到它就停。
  - 调提示词时不用每次装到手机上：在 Mac 上用 llama.cpp 编一份 macOS 版，再把 `csrc/prts_local_vlm.cpp` 和一个小的命令行程序一起编译，跑的就是 App 同一份推理代码。Mac 上看一张图约 6 秒，比手机慢，但结果一样。
- **打包**：工程里有一个构建步骤"Copy offline model"，用 `cp -c` 把两个权重拷进 `PRTS.app/LocalVLM/`。在 APFS 上这只是克隆，不占时间也不占空间。
- **用法**：设置 → PRTS intelligence → 服务与 API Key → 服务商 → "本机（离线）"。这个服务商不需要 Key，也不需要打开"允许发送照片"，照片不出手机。它是默认服务商，因为 PRTS 要考虑没网的场景。

真机实测（iPhone 17 Pro Max，2026-10-30，`PRTSTests/PhotoLocalModelTests`，走 App 自己的描述路径）：3 张照片的回答和上面基准测试一字不差。第一张 2.6 秒（含加载模型），之后每张 1.8–2.0 秒；描述到一半取消会立刻停下。

还没做的：

1. 实测开着 ARKit 避障时同时跑模型：分析能不能保持 10 Hz，画面会不会掉帧，连续拍照的发热。
2. 用 30 张实拍图评质量，和云端模型对比。
3. 8 GB 的 iPhone 15 Pro 还没测过。
4. 模型加载后一直占着内存，收到内存警告时还不会主动释放。
