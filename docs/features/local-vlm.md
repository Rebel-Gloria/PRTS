# 本地视觉模型

PRTS 使用 MiniCPM-V 4.7 1B 完成离线画面描述和文字识别，模型随 App 打包，默认启用。它不参与实时避障；空间计算由 `SpatialCore` 独立完成。

## 模型与配置

| 项目 | 配置 |
|---|---|
| 来源 | `openbmb/MiniCPM-V-4.7-1B-gguf` |
| 语言模型 | `MiniCPM-V-4_7-1B-Q5_K_M.gguf`，约 752 MB |
| 视觉模块 | `mmproj-model-f16.gguf`，约 1.1 GB |
| 总权重 | 约 1.9 GB |
| 推理依赖 | 固定提交 `620d222` 的 llama.cpp，启用 mtmd 和 Metal |
| 描述默认参数 | 贪心解码，最多 160 token，切片上限 9 |

切片上限通过 mmproj 元数据 `clip.vision.max_slice_nums` 设置，无须重新转换权重。当前选择优先保留画面细节；旧版 4.6 和 Gemma 对照模型未采用。选型与性能结果见[验证结果](../validation.md)。

## 准备与打包

在 macOS 安装 cmake、ninja 后运行：

```sh
bash Packages/LocalVLM/prepare.sh
```

可通过 Homebrew 或 `pip install cmake ninja` 安装构建工具。脚本编译 llama.cpp 与 `csrc/` 封装，生成支持真机和模拟器的 `Packages/LocalVLM/PRTSLocalVLM.xcframework`，并下载、校验两份权重的 SHA-256。8 GB 内存的 Mac 默认使用 `-j 2`。

权重保存在 `models/MiniCPM-V-4.7-1B/`。权重和编译产物不进入 Git。Xcode 的“Copy offline model”阶段用 `cp -c` 复制到 `PRTS.app/LocalVLM/`；APFS 文件克隆可避免立即复制整份数据。

## 请求与生命周期

`Packages/LocalVLM` 是本地 Swift 包，首次请求时加载模型，之后保留在内存。请求通过同一串行队列执行，取消在两个 token 之间生效。`PRTS/Features/PhotoDescription/PhotoLocalModel.swift` 指定安装包中的模型位置。

`describe` 接收一张照片并回答问题；`ask` 在同一图像上下文中继续提问，无须重新进行视觉编码。两者支持逐步输出，并保证 UTF-8 字符完整。文字识别使用这两个接口分别完成分类和转写。

模型偶尔输出 `</think>` 后继续生成额外内容，封装会在该标记处停止。描述和文字识别的具体回答约束由各自功能模块管理。

## 使用与限制

“设置 → PRTS intelligence → 智能设置”中的“本机（离线）”为默认服务，无须 API Key 或照片上传授权。

现有测试中，iPhone 17 Pro Max 热启动描述约需 2 s，内存峰值约 1.6 GB；这些数值仅对应少量测试图片。冷启动还包含模型加载与着色器编译。

目前模型加载后不会主动释放，尚无专门的内存警告处理。ARKit 同时运行、连续拍照发热、8 GB iPhone 15 Pro，以及完整实拍题库的质量验证仍未完成。权重采用 mmap，文件大小与 `phys_footprint` 不可直接等同。
