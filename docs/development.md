# 开发指南

App 构建需要 macOS、Xcode 和本地视觉模型依赖。Python 数据工具可独立运行。目录职责见[工程架构](architecture.md)，开发要求见[仓库规范](../AGENTS.md)。

## 准备与构建

首次构建先运行模型准备脚本。它会下载依赖和约 1.9 GB 权重、校验文件并编译推理库，需要 cmake、ninja 和网络。版本与打包细节见[本地视觉模型](features/local-vlm.md)。

```sh
bash Packages/LocalVLM/prepare.sh

# 普通构建
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Standard build

# 开发构建
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -xcconfig configs/DevCapture.xcconfig \
  -derivedDataPath build/DevCapture build
```

安装到真机需要配置签名 Team。构建参数可加入 `PRTS_SOURCE_COMMIT=$(git rev-parse HEAD)`，将源码提交写入二进制。普通版和开发版使用独立 DerivedData，避免产物混用。

## 开发版与普通版

`PRTS_DEV_CAPTURE` 独立于 DEBUG；工程默认 Debug、Release 均未启用，只有传入 `configs/DevCapture.xcconfig` 才加入开发功能。两种构建使用同一套避障算法。

| 开发功能 | 行为 |
|---|---|
| 主页指标、图例、测试指令栏 | 默认显示并保存选择；大字体下隐藏指标 |
| 演示模式和参数页 | 调整底图、图层、路径、触觉、深度来源与几何参数 |
| 相机视频与分析数据采集 | 每次启动默认关闭，需手动开启 |
| DIAG 与 Sessions 导出 | 提取自动诊断和单帧样本 |

`ProbeSettingsView`、`DemoOptionsView`、`HomeDemoOverlay`、`DevCaptureRecorder` 仅参与开发构建，其余集成入口受条件编译保护。普通版不读取开发版显示设置，默认使用 `RenderOptions.product`。检查普通版产物时，应确认没有采集类型及入口字符串。

## 构建与回归检查

### 代码风格

使用 Python 3.11 及以上版本。首次准备格式工具：

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r scripts/requirements-style.txt
python scripts/install_shfmt.py
xcrun swift-format --version
```

Swift 格式工具固定为 Swift 6.2 工具链随附的 `swift-format 6.2.0`；Python、C++ 和 Shell 分别固定为 Ruff 0.14.0、clang-format 21.1.0 和 shfmt 3.12.0。Shell 工具下载后校验固定 SHA-256，保存在忽略的 `build/tools/`。如果 Xcode 随附版本不同，可将 `SWIFT_FORMAT` 指向单独安装的匹配工具，不必更换 App 编译器。

```sh
python scripts/style.py          # 检查全部自有源码
python scripts/style.py --fix    # 应用格式和 Python 安全修复
```

检查包含新增的未跟踪源码，排除上游 `Vendor/PRTSCore`、被忽略的生成文件和原始数据。工具缺失、版本不符或格式不合规均返回失败；脚本不会自动安装或升级工具。Windows 可运行相同 Python 入口，或用 `--language python` 检查单一语言；完整检查仍是提交要求。

`.github/workflows/code-quality.yml` 在 `main` 推送和面向 `main` 的 PR 中运行全部格式检查、Python 测试，macOS 上的 SpatialCore 和契约测试，以及 App 的无签名真机编译。这一步只检查能否编译：LocalVLM 用头文件和空库代替，权重用空文件占位，产物不能运行。CI 不运行 App 真机交互。

### Mac 回归

在具备依赖的 macOS 上运行完整检查：

```sh
bash scripts/validate_spatial.sh
```

脚本执行 SpatialCore 的 Debug、Release 测试，PRTSContracts 测试，Python 测试，以及模拟器 Debug 和真机 Release 的无签名编译。LocalVLM 的模拟器库只有 arm64，模拟器编译因此只编 arm64。它不替代真机交互验证。

单独检查对应模块：

```sh
swift test --package-path Packages/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
git diff --check
```

## 数据工具与回放

以下工具在本机处理数据，不上传采集内容。`pull_diag.py` 连接手机复制文件；采集操作与格式见[诊断与采集](diagnostics.md)。

| 任务 | 入口 |
|---|---|
| 从手机提取诊断 | `python3 scripts/pull_diag.py` |
| 校验 DIAG | `python3 scripts/read_diag.py <run> --verify-data` |
| 校验开发采集 | `python3 scripts/read_dev_capture.py <dev-capture>`，不解码视频 |
| 汇总旧 Sessions | `scripts/summarize_session.py`，不支持 DIAG 目录 |
| 比较路线结果 | `scripts/replay_routes.swift`、`scripts/compare_route_replays.py` |
| 回放 `{result, options}` 快照 | `scripts/replay_route_snapshots.swift` |
| 回放完整避障流程 | `bash Experiments/astra/run.sh <DIAG目录>` |
| 查看源码规模 | `python3 scripts/code_inventory.py`；加 `--write` 写入本地 `build/code-inventory.md` |

路线回放沿用已记录的深度和分析结果，只重跑规划。对比前后版本必须使用相同帧顺序、epoch、frameID 和时间戳；缺失帧不可补齐，也无法模拟用户走向另一条路线后会看到的场景。

`replay_route_snapshots.swift` 默认使用 `obstacle_veto_v1`，`--verified` 用严格策略对照。由压缩栅格恢复的输入缺少原始样本数，结论应注明。`confirmedModelFree` 为 unavailable 或 `confirmedModelChecksPresent` 缺失时，不能视为障碍检查通过。

astra 会重新运行感知、规划、发布和反馈策略，并保存源码、二进制和工具指纹。结果为离线代理指标，其中语音是模拟请求，不代表实际播报。产物不提交 Git；不在此重复记录各轮运行过程。

`run.sh` 默认回放当前产品源码。历史实验的文本补丁依赖原始源码写法，`prepare.py` 明确从整理前的固定提交读取输入；`round3_sources.py` 保留原补丁系列的历史路径。它们用于复现旧实验，不作为当前产品实现。

SpatialProbe 位于 `Experiments/SpatialProbe`，是 iOS 17 及以上的独立感知验证 App，保留冻结对照实现。可在该目录运行 `bash scripts/validate.sh`，或打开 `PRTSSpatialProbe.xcodeproj`，选择 `PRTSSpatialProbe` scheme。Bundle ID 为 `org.prts.SpatialProbe`；着色器启动时从 `App/ProbeShaders.metal.txt` 编译，无须 Metal 离线工具链。

## 品牌与资源维护

`docs/branding/` 保存用户提供的 SVG 原稿，不修改原有形状、颜色和字标。原稿使用 mask，统一由 WebKit 渲染，以减少工具差异；文字已转为路径，无须安装字体。

| 原稿 | 导出要求 |
|---|---|
| `app-logo-prts.svg` | 1024×1024、不含透明通道的 PNG，供浅色、深色和染色图标槽使用 |
| `app-logo.svg` | 主页标志，按 32 pt 导出 1×、2×、3× PNG，保持黑底白字 |

第三方来源与升级要求见[工程架构](architecture.md)。宣传专用内容继续在 `marketing` 分支维护。
