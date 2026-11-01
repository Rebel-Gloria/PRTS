# 开发指南

本文介绍如何构建和测试 PRTS，以及如何采集、读取和回放诊断数据。代码组织请参阅[工程架构](architecture.md)，编码和提交规范请参阅 [AGENTS.md](../AGENTS.md)。

## 环境要求

| 项目 | 要求 |
|---|---|
| 应用构建 | macOS、Xcode 26 或更高版本（应用使用 iOS 26 SDK 的 API），部署目标 iOS 17 |
| 本地模型 | cmake、ninja、网络连接，约 2 GB 磁盘空间 |
| 数据工具和格式检查 | Python 3.11 或更高版本 |
| 安装到真机 | 已配置签名团队 |

## 构建

1. 准备本地视觉模型和推理库。此步骤下载约 1.9 GB 权重并编译 llama.cpp，只需在首次构建或修改 `Packages/LocalVLM/csrc/` 后执行：

   ```sh
   bash Packages/LocalVLM/prepare.sh
   ```

2. 构建应用。标准版和开发版使用不同的 DerivedData 目录，避免产物混用：

   ```sh
   # 标准版
   xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath build/Standard build

   # 开发版
   xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
     -destination 'generic/platform=iOS' -xcconfig configs/DevCapture.xcconfig \
     -derivedDataPath build/DevCapture build
   ```

如需将源码提交写入二进制，请添加构建参数 `PRTS_SOURCE_COMMIT=$(git rev-parse HEAD)`。

### 开发版与标准版

开发功能由编译条件 `PRTS_DEV_CAPTURE` 控制，与 Debug 配置无关。工程默认的 Debug 和 Release 配置都不启用该条件，只有传入 `configs/DevCapture.xcconfig` 时才启用。两种构建使用相同的避障算法。

| 开发版功能 | 说明 |
|---|---|
| 主页指标、图例和测试指令栏 | 默认显示；测试指令栏也用于 UI 测试 |
| 演示选项和参数设置 | 调整底图、图层、路径、触觉反馈、深度来源和几何参数 |
| 相机视频与分析数据采集 | 每次启动默认关闭 |
| DIAG 和 Sessions 导出 | 导出自动诊断和单帧样本 |

`ProbeSettingsView`、`DemoOptionsView`、`HomeDemoOverlay` 和 `DevCaptureRecorder` 只参与开发版编译。标准版使用 `RenderOptions.product`，不读取开发版的显示设置。检查标准版产物时，应确认其中不包含采集相关的类型和字符串。

## 测试

### 完整检查

在已准备本地模型的 Mac 上运行：

```sh
bash scripts/validate_spatial.sh
```

该脚本依次执行 SpatialCore 的 Debug 和 Release 测试、PRTSContracts 测试、Python 测试，以及模拟器 Debug 和真机 Release 的无签名编译。LocalVLM 的模拟器库只包含 arm64，因此模拟器编译仅针对 arm64。该脚本不能代替真机交互测试。

### 单项检查

```sh
swift test --package-path Packages/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
git diff --check
```

应用的单元测试和 UI 测试需要在真机上通过 Xcode 或 `xcodebuild test` 运行。

### 持续集成

`.github/workflows/code-quality.yml` 在推送到 `main` 和面向 `main` 的拉取请求时运行：

| 作业 | 内容 |
|---|---|
| `style-and-boundaries` | 格式检查、Python 测试、`git diff --check` |
| `spatial-tests` | SpatialCore 测试和契约测试 |
| `app-build` | 应用的无签名编译检查 |

`app-build` 只验证代码能否编译：LocalVLM 以头文件和空静态库代替，权重以空文件占位，链接时允许未定义的模型符号，生成的产物无法运行。CI 不运行真机测试。

### 代码格式

格式工具的版本固定如下，`scripts/style.py` 在版本不符时报错：

| 语言 | 工具 |
|---|---|
| Swift | `swift-format` 6.2.0（Swift 6.2 工具链附带） |
| Python | Ruff 0.14.0 |
| C++ | clang-format 21.1.0 |
| Shell | shfmt 3.12.0 |

首次使用时安装格式工具：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-style.txt
python scripts/install_shfmt.py
```

shfmt 下载后会校验 SHA-256，保存在 `build/tools/` 中。如果 Xcode 附带的 `swift-format` 版本不是 6.2.0，请将环境变量 `SWIFT_FORMAT` 指向单独安装的 6.2.0 版本。

```sh
python scripts/style.py          # 检查全部源码
python scripts/style.py --fix    # 应用格式修正
```

检查范围包括新增的未跟踪源码，不包括 `Vendor/PRTSCore`、被忽略的生成文件和原始评测数据。

## 诊断记录

应用提供三种记录方式：

| 类型 | 启用方式 | 位置与内容 |
|---|---|---|
| 自动 DIAG | 标准版和开发版每次启动时自动创建，不会自动打开相机 | `Documents/Diagnostics/<UTC 时间>-<UUID>/`；不包含画面、音频和位置 |
| 开发采集 | 开发版在“设置 → 开发者选项”中手动开启 | DIAG 目录内的 `dev-capture-<UUID>/`；包含视频、传感器和分析数据 |
| Sessions | 开发版手动保存 | `Sessions/`；单帧深度、元数据、分析结果和网格 |

### 采集与导出

开发采集每次启动默认关闭。录制期间主页持续显示提示，隐藏调试面板或相机画面不会停止录制。关闭开关、停止避障、进入后台或导出时，录制停止并完成 MP4 写入。

开发版可以导出本次或历史 DIAG。导出前建议先停止避障，以免目录复制阻塞日志写入。标准版没有导出入口，可以连接 Mac 使用以下命令提取：

```sh
python3 scripts/pull_diag.py --device <设备标识> --output <新目录>
```

开发采集不录音、不上传，也不申请位置、麦克风或相册权限。但视频和空间数据可能包含现场隐私信息，分享前请检查。

### DIAG 文件

每次启动使用一个目录，同一次启动中的多次开始和停止以 epoch 区分。JSONL 记录包含全局 `sequence`、写入时间 `writtenUptime` 和 `payload`，可附带 `attachment` 和 `diagnosticTiming`。

> [!IMPORTANT]
> 对齐数据时，请使用 payload 中的源帧时间戳、epoch 和 frameID，不要使用写入时间。

| 文件 | 内容 |
|---|---|
| `manifest.json` | 时钟基准、设备与版本、格式、采样策略、配额、算法版本（`routeAlgorithmRevision`） |
| `status.json` | 约每秒更新一次：各数据流计数、队列、字节数、错误和配额状态 |
| `events.jsonl` | 启停、权限、中断、参数、发热、内存警告和前后台切换 |
| `capture.jsonl` | ARFrame 元数据：位姿、内参、跟踪状态、曝光、深度可用性和方向稳定性，不含像素 |
| `analysis.jsonl` | 每个分析帧的指标、栅格、距离、原因和深度附件 |
| `mesh.jsonl` | 网格的增加、修改和删除，分类和完整网格附件 |
| `render.jsonl` | 绘制提交、跳过原因、GPU 完成时间、顶点数和图层 |
| `prediction.jsonl` | 单目深度模型输出、尺度拟合和各阶段耗时 |
| `path.jsonl` | 路线、目标、参数，以及保留、撤销和重新规划的原因（schema 4） |
| `heartbeat.jsonl` | 约每秒记录一次：帧龄、FPS、热状态、电量（-1 表示不可用）、内存和丢帧数 |
| `data-*.bin` | 分段存储的无损压缩深度和网格 |

旧记录中缺少的字段按缺失处理，不推断补齐。从 schema 3 起，`path.jsonl` 包含 `plannedLength` 和 `planned`，以及可选的 `turnCandidateLength`、`turnReason`、`routePointCount` 和 `turnAngle`；转向被阻止时也记录实际偏离角。

### 二进制附件

`attachment` 字段记录文件名、偏移量、压缩前后长度、`codec=deflate-raw` 和原始内容的 SHA-256。偏移处依次存放压缩长度和原始长度（两个 UInt32 LE），然后是 raw DEFLATE 数据。在 Python 中使用 `zlib.decompress(data, -15)` 解压。二进制数据先于引用它的 JSONL 记录写入。

| 附件 | 解压后的布局 |
|---|---|
| 深度 | UInt32 LE 头长度 → JSON 头 → `width*height` 个 Float32 LE 深度 → 可选的 UInt8 置信度 → 可选的预测支持掩码 |
| 网格（`mesh_frame_binary_v1`） | UInt32 LE 头长度 → JSON 头 → `vertexCount×3` 个 Float32 坐标 → `indexCount` 个 UInt32 索引 → `classificationCount` 个 UInt8 分类 |

深度的 JSON 头包含尺寸、epoch、frameID、时间戳、位姿、内参、参数、地面先验、方向稳定性和数据来源；网格的 JSON 头包含 ID、epoch、版本、回调时间、变换、来源和数量。网格不抽样；深度中的 NaN、Inf 和无效像素原样保留。缺少置信度时该段长度为 0，不补充高置信度。

### 开发采集格式

开发采集只保存已完成分析的帧，最高 5 Hz。编码繁忙时跳过帧，保留真实时间间隔，不补帧。

```text
dev-capture-<UUID>/
  manifest.json
  status.json                            # recording / completed / failed
  camera.mp4
  samples.jsonl                          # 帧标识、PTS、附件引用
  <epoch>-<frame>.evidence.json.deflate
  <epoch>-<frame>.depth.bin.deflate
  <epoch>-<frame>.relative.f32.deflate
```

| 数据 | 内容 |
|---|---|
| 视频 | 无标注 H.264，800 kbps，最长边 960 像素，不裁切，无音轨 |
| LiDAR | 分析实际使用的 Float32 `sceneDepth` 和 UInt8 置信度 |
| 单目模型 | 校准前的相对逆深度、模型与尺寸、尺度样本和参数、地面参考、耗时；校准通过后另存米制深度 |
| ARKit | 内参、位姿、跟踪状态、曝光、方向、水平平面和最多 512 个特征点 |
| 网格 | 每帧的 anchor ID 与版本；完整内容从父 DIAG 读取并核对版本 |
| 分析 | 完整的 `AnalysisResult`、`PathUpdate` 和路线参数 |

开发采集不包含 ARKit 内部 SLAM 地图、原始 IMU 数据或 LiDAR 硬件时间戳。evidence 中的非有限数写为 `nan`、`+inf` 或 `-inf`。深度由 `DepthFrameCodec` 编码；relative 为行优先的 Float32 LE，尺寸见 `evidence.model`。视频 PTS 为 `ARFrame.timestamp - manifest.originARTimestamp`，timescale 为 60000。

> [!NOTE]
> 视频经过有损压缩，只能用于核对现场情况，不能用于重新运行模型并比较原始输出。几何回放请使用无损压缩的深度和模型附件。

### 容量限制

| 项目 | 上限 |
|---|---|
| DIAG 分段文件 | 32 MiB |
| DIAG 每次启动 / 整个目录 | 512 MiB / 2 GiB |
| DIAG 待写队列 | 64 条、16 MiB；为事件预留 8 条、64 KiB |
| 开发采集单段 / 每次启动 | 10 分钟 / 约 256 MiB |
| 开发采集最低剩余空间 | 256 MiB |

达到上限后停止新增记录，不覆盖或自动删除旧数据，请先导出再通过“文件”App 或 Xcode 清理。分析深度默认约 10 Hz 保存，256×192 的深度加置信度每帧约 240 KiB，未压缩时每分钟约 141 MiB。

队列满时会丢弃记录，DIAG 和开发采集的丢弃计数需要分别检查。强制退出或断电可能丢失最后约 1 s 的 DIAG，并留下未完成的 MP4；缺少终止事件不代表发生了崩溃。

### 排查地面未显示

1. 检查 `analysis.payload.diagnostics` 中的深度和置信度读取状态、像素数量、`groundConfirmed`、连续确认次数和平面差异。地面需要连续 3 次确认，高度差小于 4 cm，法向差小于 3°。
2. 检查 `groundReferenceMode`（`current_confirmed` 或 `retained_world_reference`），以及 `modelState` 和 `modelBlockReasons`。
3. 检查 `render.jsonl` 中的 `surfacePresentationMode`（`current_depth`、`historical_wireframe` 或 `none`）。分析成功不代表画面已经绘制。

## 数据工具

以下工具均在本地处理数据，不上传采集内容。

| 任务 | 命令 |
|---|---|
| 从手机提取诊断 | `python3 scripts/pull_diag.py --device <设备标识> --output <新目录>` |
| 校验 DIAG | `python3 scripts/read_diag.py <run> --verify-data` |
| 提取深度帧 | `python3 scripts/read_diag.py <run> --extract-depth <epoch>:<frame> --output <目录>` |
| 提取预测深度帧 | `python3 scripts/read_diag.py <run> --extract-prediction <epoch>:<frame> --output <目录>` |
| 校验开发采集 | `python3 scripts/read_dev_capture.py <dev-capture>`（不解码视频） |
| 汇总 Sessions | `python3 scripts/summarize_session.py <session>`（不支持 DIAG 目录） |
| 比较路线结果 | `scripts/replay_routes.swift`、`scripts/compare_route_replays.py` |
| 回放 `{result, options}` 快照 | `scripts/replay_route_snapshots.swift` |
| 回放完整避障流程 | `bash Experiments/astra/run.sh <DIAG 目录>` |
| 统计源码规模 | `python3 scripts/code_inventory.py`；加 `--write` 写入 `build/code-inventory.md` |

`read_diag.py` 会核对长度、SHA-256、帧和网格标识，并报告截断的尾行和损坏的附件。深度提取输出 `metadata.json`、`depth.f32le` 和 `confidence.u8`。`source=synthetic` 表示合成数据，不能作为真机结果。

### 回放

路线回放使用已记录的深度和分析结果，只重新运行规划。比较两个版本时，必须使用相同的帧顺序、epoch、frameID 和时间戳。缺失的帧无法补齐，回放也无法模拟用户走向另一条路线后看到的场景。

`replay_route_snapshots.swift` 默认使用 `obstacle_veto_v1` 策略，加 `--verified` 使用严格策略对照。从压缩栅格恢复的输入缺少原始样本数，结论中应注明。`confirmedModelFree` 为 unavailable 或缺少 `confirmedModelChecksPresent` 时，不能视为障碍检查通过。

`Experiments/astra/run.sh` 重新运行当前源码的感知、规划、发布和反馈策略，并记录源码、二进制和工具的指纹。结果为离线代理指标，语音为模拟请求，不代表实际播报。产物不纳入版本控制。`prepare.py` 和 `round3_sources.py` 从固定的历史提交读取源码，仅用于复现旧实验。

### SpatialProbe

`Experiments/SpatialProbe` 是独立的感知验证应用（iOS 17 及更高版本），保留冻结的对照实现，Bundle ID 为 `org.prts.SpatialProbe`。如需验证，请在该目录运行 `bash scripts/validate.sh`，或在 Xcode 中打开 `PRTSSpatialProbe.xcodeproj` 并选择 `PRTSSpatialProbe` scheme。着色器在启动时从 `App/ProbeShaders.metal.txt` 编译，无须 Metal 离线工具链。

## 品牌资源

`docs/branding/` 保存 SVG 原稿，请勿修改其中的形状、颜色和字标。原稿使用 mask，应使用 WebKit 渲染导出；文字已转为路径，无须安装字体。

| 原稿 | 导出要求 |
|---|---|
| `app-logo-prts.svg` | 1024×1024、不含透明通道的 PNG，用于浅色、深色和着色图标 |
| `app-logo.svg` | 主页标志，按 32 pt 导出 1×、2×、3× PNG，保持黑底白字 |

宣传材料维护在 `marketing` 分支。
