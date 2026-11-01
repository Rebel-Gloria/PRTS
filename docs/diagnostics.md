# 诊断与采集

PRTS 提供自动 DIAG、开发录像和手动 Sessions 三种记录方式。DIAG 用于排查运行状态，开发录像用于对照现场，Sessions 保存单帧样本。

| 类型 | 启用条件 | 内容与位置 |
|---|---|---|
| 自动 DIAG | 普通版和开发版每次启动自动建立，不自动打开相机 | `Documents/Diagnostics/<UTC时间>-<UUID>/`；不含画面、音频和位置 |
| 开发采集 | 开发版手动开启，取得相机权限并开始避障 | DIAG 内的 `dev-capture-<UUID>/`；视频与传感器、分析数据 |
| Sessions | 开发版手动保存 | `Sessions/` 中的单帧深度、元数据、分析和网格 |

## 采集与导出

开发版从“设置 → 开发者选项”开启“保存相机视频与分析数据”，每次启动默认关闭。录制期间主页持续显示提示，隐藏调试面板或相机画面不会停止录像。

关闭开关、停止避障、进入后台或导出时，录像停止并完成 MP4 写入；再次录制需要重新开启。“停止采集并打开 DIAG 导出页”会等待写入结束。

开发版可导出本次或历史 DIAG。建议先停止避障，避免目录复制阻塞日志写入。普通版没有导出入口，也可连接开发机使用 `scripts/pull_diag.py` 提取。换回普通版不会删除已有采集。

开发采集不录音、不上传，也不申请位置、麦克风或相册权限；视频和空间数据仍可能包含现场隐私，分享前应检查。

## DIAG 文件与时间

同一次启动使用一个目录，多次启停通过 epoch 区分；再次启动创建新目录。JSONL 记录包含全局 `sequence`、写入时间 `writtenUptime` 和 `payload`，可附带 `attachment`、`diagnosticTiming`。

对齐数据使用 payload 的源帧时间戳、epoch 和 frameID，不能使用写入时间替代采样时间。

| 文件 | 内容 |
|---|---|
| `manifest.json` | 时钟基准、设备与版本、格式、采样策略、配额、算法版本 |
| `status.json` | 约每秒更新各流计数、队列、字节数、错误与配额状态 |
| `events.jsonl` | 启停、权限、中断、参数、发热、内存警告和前后台变化 |
| `capture.jsonl` | ARFrame 元数据、位姿、内参、跟踪、曝光、深度可用性和方向稳定性，不含像素 |
| `analysis.jsonl` | 每个分析帧的指标、栅格、距离、原因和深度附件 |
| `mesh.jsonl` | 网格增改删、分类与完整网格附件 |
| `render.jsonl` | 绘制提交、跳过原因、GPU 完成、顶点数和图层 |
| `prediction.jsonl` | 单目模型输出、尺度拟合与各阶段耗时 |
| `path.jsonl` | 路线、目标、参数及保留、撤销、重规划原因，当前 schema4 |
| `heartbeat.jsonl` | 约每秒记录帧龄、FPS、发热、电量、内存和丢帧；电量 -1 表示不可用 |
| `data-*.bin` | 分段存放的无损压缩深度与网格 |

`manifest.routeAlgorithmRevision` 标记算法版本。旧记录缺少的字段按缺失处理，不推断补齐。schema3 起已有 `plannedLength`、`planned`，可选 `turnCandidateLength`、`turnReason`、`routePointCount` 和 `turnAngle`；即使转向被阻止，也记录实际偏离角。

### 排查地面未显示

先查看 `analysis.payload.diagnostics` 的深度与置信度读取状态、像素数量、`groundConfirmed`、连续确认次数及平面差异。地面要求连续 3 次，高度差小于 4 cm、法向差小于 3°。

`groundReferenceMode` 区分 `current_confirmed` 与 `retained_world_reference`，`modelState` 和 `modelBlockReasons` 说明模型状态。最后检查渲染的 `surfacePresentationMode`：`current_depth`、`historical_wireframe` 或 `none`。分析成功不代表实际绘制。

## 二进制格式

DIAG 的 `attachment` 记录文件、offset、压缩前后长度、`codec=deflate-raw` 和原始内容 SHA-256。offset 处先存两个 UInt32 LE，依次为压缩长度和原始长度，再存 raw DEFLATE。Python 使用 `zlib.decompress(data, -15)` 解压。二进制先写，JSONL 引用后写。

| 附件 | 解压后的排列 |
|---|---|
| 深度 | UInt32 LE 头长度 → JSON 头 → `width*height` 个 Float32 LE 深度 → 可选 UInt8 置信度 → 可选预测支持掩码 |
| 网格 `mesh_frame_binary_v1` | UInt32 LE 头长度 → JSON 头 → `vertexCount×3` 个 Float32 坐标 → `indexCount` 个 UInt32 索引 → `classificationCount` 个 UInt8 分类 |

深度头包含尺寸、epoch、frameID、时间戳、位姿、内参、参数、地面先验、方向稳定性与来源。网格头包含 id、epoch、revision、回调时间、变换、来源与数量。网格不抽样，深度中的 NaN、Inf 和无效像素原样保留。缺少置信度时为 0 字节，不补高置信度；预测深度附带支持掩码。

## 开发采集格式

只保存已完成分析的帧，最高 5 Hz；编码忙时跳帧，保留真实时间间隔，不补帧。

```text
dev-capture-<UUID>/
  manifest.json
  status.json                            # recording / completed / failed
  camera.mp4
  samples.jsonl                          # 帧身份、PTS、附件引用
  <epoch>-<frame>.evidence.json.deflate
  <epoch>-<frame>.depth.bin.deflate
  <epoch>-<frame>.relative.f32.deflate
```

| 数据 | 保存内容 |
|---|---|
| 视频 | 无标注 H.264，800 kbps，最长边 960，不裁切、无音轨，有损缩小 |
| LiDAR | 实际分析使用的 Float32 `sceneDepth` 和 UInt8 置信度 |
| 单目模型 | 相机坐标下的校准前相对逆深度、模型与尺寸、尺度样本和参数、地面参考、耗时；校准通过后另存米制深度 |
| ARKit | 内参、位姿、跟踪、曝光、方向、水平平面和最多 512 个特征点 |
| 网格 | 每帧 anchor ID 与版本；完整内容从父 DIAG 读取并核对版本 |
| 分析 | 完整 `AnalysisResult`、`PathUpdate` 和路线参数 |

不包含 ARKit 内部 SLAM 地图、原始 IMU 或 LiDAR 硬件时间戳。附件使用 raw DEFLATE，索引保存压缩前后长度和原始 SHA-256。evidence 将非有限数写为 `nan`、`+inf`、`-inf`。深度由 `DepthFrameCodec` 编码，relative 为行优先 Float32 LE，尺寸见 `evidence.model`；不量化、不以 0 填洞。

视频 PTS 为 `ARFrame.timestamp - manifest.originARTimestamp`，timescale 为 60000，索引对应实际分析帧。视频保留相机方向，投影时按缩放后的宽高调整内参。

## 容量与完整性

| 项目 | 限制 |
|---|---|
| DIAG 分段文件 | 32 MiB |
| DIAG 每次启动 / 整个目录 | 512 MiB / 2 GiB |
| DIAG 待写队列 | 64 条、16 MiB，预留事件 8 条、64 KiB |
| 开发采集单段 / 每次启动 | 10 分钟 / 约 256 MiB |
| 开发采集剩余空间 | 低于 256 MiB 停止 |

达到上限停止新增记录，不覆盖或自动删除旧数据；先导出，再通过“文件”App 或 Xcode 清理。默认约 10 Hz 保存分析深度，256×192 深度加置信度每帧约 240 KiB，未压缩时每分钟约 141 MiB。

队列满会丢记录，DIAG 和开发采集的计数需分别检查。强制终止或断电可能丢失最后约一秒 DIAG，并留下未完成 MP4；缺少终止事件不等于崩溃。残留附件以索引为准，缺失帧不能恢复。

原始尺寸、无损压缩的深度和模型附件可用于几何回放。有损视频只用于核对现场，不能重跑模型后直接比较原始输出。

## 读取与手动样本

```sh
python3 scripts/read_diag.py <run> --verify-data
python3 scripts/read_diag.py <run> --extract-depth 2:151 --output <out>
python3 scripts/read_diag.py <run> --extract-prediction 1:123 --output <out>
python3 scripts/read_dev_capture.py <dev-capture>
```

读取器核对长度、SHA-256、帧与网格身份，并报告截断尾行和损坏附件。深度提取输出 `metadata.json`、`depth.f32le`、`confidence.u8`，不生成图片或补帧。`source=synthetic` 表示合成数据，不能当作真机结果。

Sessions 保存 `manifest.json`、`metrics.csv`、`frames.jsonl`、`events.jsonl` 和 `samples/<frameID>-<suffix>/` 中的单帧附件，可用 `scripts/summarize_session.py` 汇总。早期样本可能含 `rgb.jpg`，当前手动采样不再保存画面。
