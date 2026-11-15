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

   脚本默认以 `-j 2` 编译，适合 8 GB 内存的 Mac；如需修改并行数，请设置环境变量 `JOBS`。

2. 构建应用。标准版和开发版使用不同的 DerivedData 目录，避免产物混用：

   ```sh
   # 标准版
   xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
     -destination 'generic/platform=iOS' -derivedDataPath build/Standard build

   # 开发版
   xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Dev \
     -destination 'generic/platform=iOS' -derivedDataPath build/Dev build
   ```

如需将源码提交写入二进制，请添加构建参数 `PRTS_SOURCE_COMMIT=$(git rev-parse HEAD)`。

### 构建模式

工程仅保留 `Release` 和 `Dev` 两个构建模式。两者使用相同的产品界面、避障算法、参数和编译优化；`Dev` 额外定义 `PRTS_DEV`，自动记录用于重放的数据，并提供分享和清理入口。旧的手动采集开关、演示面板、测试指令栏和独立开发配置文件已移除。

| 模式 | 录制与界面 |
|---|---|
| `Release` | 产品功能和错误日志，不保存相机、空间或提问音频数据 |
| `Dev` | 自动录制；首页显示隐私提示；设置末尾提供分享和清除录制数据 |

共享 `PRTS` scheme 在运行、分析和测试时默认使用 `Dev`，在归档和性能分析时默认使用 `Release`。如需更换模式，请修改 scheme 的构建配置或传入 `-configuration`。

## 测试

### 完整检查

在已准备本地模型的 Mac 上运行：

```sh
bash scripts/validate_spatial.sh
```

该脚本依次执行 SpatialCore 的 Debug 和 Release 测试、PRTSContracts 测试（应用不链接该包）、Python 测试，以及模拟器 Dev 和真机 Release 的无签名编译。LocalVLM 的模拟器库只包含 arm64，因此模拟器编译仅针对 arm64。该脚本不能代替真机交互测试。

### 单项检查

```sh
swift test --package-path Packages/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
git diff --check
```

不依赖传感器的应用单元测试可以在模拟器中运行；相机、音频、模型和交互验证需要在真机上通过 Xcode 或 `xcodebuild test` 运行。

SpatialCore 的路线测试按场景使用独立的 `XCTestCase`，可按文件同名的套件筛选，例如 `swift test --package-path Packages/SpatialCore --filter RouteProjectionTests`。共享的合成场景由 `Tests/SpatialCoreTests/Support/RoutingTestScene.swift` 构造；测试通过该值类型生成帧、障碍和位姿，不实例化其他测试套件。

### 持续集成

`.github/workflows/code-quality.yml` 在推送到 `main` 和面向 `main` 的拉取请求时运行：

| 作业 | 内容 |
|---|---|
| `style-and-boundaries` | 格式检查、Python 测试、`git diff --check` |
| `spatial-tests` | SpatialCore 测试和契约测试 |
| `app-build` | 分别构建 `Release` 和 `Dev`，运行模拟器应用单元测试，并检查真机编译 |

`app-build` 为设备和模拟器编译可链接的 LocalVLM 替身，权重以空文件占位。替身始终报告模型不可用；CI 排除 `PhotoLocalModelTests`，不验证实际推理、真机相机、传感器或交互。其余 `PRTSTests` 在两个构建模式下实际运行，不再只检查测试目标能否编译。格式失败时上传 `style.patch` 和格式器日志；应用测试结果上传为压缩的 `.xcresult`。

旧开发指令栏已移除，公开的 UI 自动化接口无法执行三指长按。依赖此手势的读字 UI 场景明确跳过，保留场景断言供真机验证；相关生命周期由可注入相机的单元测试覆盖。Dev 隐私提示、录制入口、清除二次确认与取消、系统分享及 Release 入口隔离使用普通界面操作验证。

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

模型附带的 `Manifest.json` 和 `AppleModelCard.txt` 必须保留上游原始字节。`.gitattributes` 禁止对这些文件转换换行，`test_spatial_integration.py` 同时校验上游记录的字节数、SHA-256 和产品副本的一致性。

## 自动录制

`Dev` 每次启动自动创建 `Documents/Recordings/<时间戳>-<UUID>/`，不需要打开采集开关。相机和传感器由实际功能按需启动，录制不会额外开启 ARKit、LiDAR 或麦克风。录制内容按照原始时间戳关联；系统中断、丢帧或写入失败均作为缺口记录。

| 数据 | 保存规则 |
|---|---|
| RGB 视频 | H.264，目标码率 1 Mbps；保持相机原始分辨率、比例、方向和实际时间间隔，不裁切或补帧 |
| 深度、置信度和点云 | 原始尺寸和数值，无损压缩；保留单位、位姿、内参、帧标识和时间戳 |
| 网格与空间结果 | 完整网格、锚点增删改、算法实际输入和输出、参数版本及路径结果 |
| 拍照描述、提问和读字 | 单独保存取得的原图与实际送入识别服务的图像，避免视频压缩丢失文字或细节 |
| 实时字幕 | 原尺寸 RGB 视频及实际提交的 JPEG 帧、选帧标识与时间戳；不额外保存每个采样帧的 PNG |
| 语音提问 | 仅在提问录音期间保存麦克风音频，同时保存识别文本 |
| 交互与返回 | 记录启停、功能操作、取消、前后台变化、错误日志和模型返回，以墙钟和单调时钟关联 |

1 Mbps 只针对 RGB 视频，属于编码目标而非总容量上限。深度、点云、原图和音频另行保存，因此录制包的总码率和容量会更高。凭据、认证头和密钥不进入录制。

> [!IMPORTANT]
> 自动录制可能保存现场画面、空间结构、提问声音和返回内容。首页持续显示“此构建将自动录制数据到本地，请注意隐私安全”。数据仅保存在本地，由用户主动导出。

### 分享与清理

如需分享录制数据，请在 Dev 的“设置”末尾选择“分享所有录制数据”。应用将已写入的所有会话打包为单个 `PRTS-<时间戳>.zip`，通过系统分享界面发送到 AirDrop 或保存到“文件”。导出期间继续保持功能运行，导出文件只包含打包时已完成写入的数据。分享 ZIP 位于临时目录 `RecordingExports`，可在本次运行期间重复访问，下次应用启动时清除；原始录制不受影响。

如需清除数据，请点击设置最下方红色的“清除所有录制数据”，并在弹窗中再次确认。清除会关闭录制写入入口，取消描述、字幕、读字与提问任务，释放相机并等待空间任务结束，卸载本机模型后删除全部录制。随后重建首页和功能会话，按清除前的运行意图恢复相机并开始新录制。该操作是应用内重置，不退出或重新启动 iOS 进程。取消确认不会删除数据。

如需从已连接并配对的设备直接提取，请在 Mac 上运行：

```sh
python3 scripts/pull_recordings.py --device <设备标识> --output <录制文件.zip>
```

该工具通过 `xcrun devicectl` 读取应用录制目录，并打包为一个 ZIP 文件，不需要应用内开关。设备必须允许读取该应用的数据容器。

### 数据完整性

二进制附件使用无损 raw DEFLATE 压缩，并保存原始长度及 SHA-256。RGB 视频按原始尺寸分段，尺寸或相机来源改变时创建新段；帧索引将视频时间与传感器、交互时间关联。保存点云时不将单目相对深度伪装为 LiDAR 米制数据。

封存录制段时会写入终止时间并完成视频。停止某项功能只记录该功能的停止事件，其他功能和交互仍会继续录制。强制退出、系统挂起或存储不足可能留下不完整尾段；读取工具必须报告缺口，不能把缺少终止事件直接解释为崩溃，也不能补造缺帧。

> [!NOTE]
> iOS 真正进入后台时可能中断相机和 ARKit，应用不能保证后台持续采集。录制可重放应用收到的空间输入、算法和交互过程，不包含 ARKit 私有 SLAM 内部状态。视频为有损压缩数据；需要逐像素核对的单次识别使用另存原图和实际模型输入。

## 数据工具

以下工具均在本地处理数据，不上传录制内容。

| 任务 | 命令 |
|---|---|
| 从设备提取并打包录制 | `python3 scripts/pull_recordings.py --device <设备标识> --output <录制文件.zip>` |
| 校验和解包录制 | `python3 scripts/read_recording.py`，具体参数见 `--help` |
| 读取空间诊断字段 | `python3 scripts/read_diag.py <run> --verify-data` |
| 提取深度帧 | `python3 scripts/read_diag.py <run> --extract-depth <epoch>:<frame> --output <目录>` |
| 提取预测深度帧 | `python3 scripts/read_diag.py <run> --extract-prediction <epoch>:<frame> --output <目录>` |
| 比较路线结果 | `scripts/replay_routes.swift`、`scripts/compare_route_replays.py` |
| 回放 `{result, options}` 快照 | `scripts/replay_route_snapshots.swift` |
| 回放完整避障流程 | `bash Experiments/astra/run.sh <诊断目录>` |
| 统计源码规模 | `python3 scripts/code_inventory.py`；加 `--write` 写入 `build/code-inventory.md` |

`read_diag.py` 保留读取历史空间诊断数据的能力。历史 Sessions 和开发采集的读取工具仅用于旧文件，不代表当前应用仍使用旧录制机制。`source=synthetic` 表示合成数据，不能作为真机结果。

### 回放

路线回放使用已记录的深度和分析结果，只重新运行规划。比较两个版本时，必须使用相同的帧顺序、epoch、frameID 和时间戳。缺失的帧无法补齐，回放也无法模拟用户走向另一条路线后看到的场景。

`replay_route_snapshots.swift` 默认使用 `obstacle_veto_v1` 策略，加 `--verified` 使用严格策略对照。从压缩栅格恢复的输入缺少原始样本数，结论中应注明。`confirmedModelFree` 为 unavailable 或缺少 `confirmedModelChecksPresent` 时，不能视为障碍检查通过。

`Experiments/astra/run.sh` 重新运行当前源码的感知、规划、发布和反馈策略，并记录源码、二进制和工具的指纹。结果为离线代理指标，语音为模拟请求，不代表实际播报。产物不纳入版本控制。

`Experiments/astra/` 中的工具分为两组：

| 用途 | 文件 |
|---|---|
| 回放当前源码 | `run.sh` 调用 `run_product.sh`，后者使用 `prepare_product.py`、`ReplayProduct.swift`、`metrics_product.py` 和 `seal_product.py` |
| 复现第二轮历史实验 | `run_round2.sh`，使用 `prepare.py`、`Replay.swift` 和 `metrics.py`；原型源码按固定历史提交提取，`SpatialCore` 使用当前工作区 |

两组工具共用 `generated/` 目录，但各自只编译明确列出的生成文件，避免先运行产品回放后将其适配器混入历史实验。历史实验还需要本地存在 `prepare.py` 指定的提交；源码缺失时不能复现完整回放。

结论以[验证结果](validation.md)为准，回放工具不生成报告。

### SpatialProbe

`Experiments/SpatialProbe` 是独立的感知验证应用（iOS 17 及更高版本），保留冻结的对照实现，Bundle ID 为 `org.prts.SpatialProbe`。如需验证，请在该目录运行 `bash scripts/validate.sh`，或在 Xcode 中打开 `PRTSSpatialProbe.xcodeproj` 并选择 `PRTSSpatialProbe` scheme。着色器在启动时从 `App/ProbeShaders.metal.txt` 编译，无须 Metal 离线工具链。

## 品牌资源

`docs/branding/` 保存 SVG 原稿，请勿修改其中的形状、颜色和字标。原稿使用 mask，应使用 WebKit 渲染导出；文字已转为路径，无须安装字体。

| 原稿 | 导出要求 |
|---|---|
| `app-logo-prts.svg` | 1024×1024、不含透明通道的 PNG，用于浅色、深色和着色图标 |
| `app-logo.svg` | 主页标志，按 32 pt 导出 1×、2×、3× PNG，保持黑底白字 |

录制清单 schema 3 保存每段独立的 `recordCounts` 和 `lastSequence`。校验器检查缺失文件、记录数量及重复或断号；旧版清单仍可读取，但会报告无法验证流完整性。
