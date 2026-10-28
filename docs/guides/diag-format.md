# DIAG 记录格式

App 每次启动都会自动建一个诊断目录，记录启动信息、权限、每帧的分析结果、深度、网格、渲染、路线和心跳，用来复盘实地测试。正式版和开发版都记录，都不存画面、音频和位置。正式版没有导出入口，数据只留在手机上。

## 存在哪

`Documents/Diagnostics/<UTC时间>-<UUID>/`。同一次启动里多次开始、停止避障用同一个目录，按 epoch 区分；下次启动新建目录，不覆盖旧的。不会自动开相机。

取出来：

- 开发版：设置 → 开发者选项 → DIAG → "导出本次完整 DIAG"或"导出历史 DIAG"。建议先停止避障再导出，复制大目录时队列可能满了丢记录。
- 开发机：`python3 scripts/pull_diag.py`，详见 [脚本](scripts.md)。

## 文件

每条 JSONL 记录都有全局写入序号 `sequence`、`writtenUptime`、`payload`，可能还有 `attachment` 和日志自身的开销 `diagnosticTiming`。写入时间不是传感器时间，传感器时间在 payload 里（源帧的时间戳、epoch、frameID）。

| 文件 | 内容 |
|---|---|
| `manifest.json` | 启动时钟基准、设备、系统、版本、格式、采样策略、限额、算法版本 |
| `status.json` | 约每秒更新：各流的尝试、成功、丢弃、失败计数，队列、已写字节、错误、配额 |
| `events.jsonl` | 启动、权限、开始、停止、中断、参数变化、发热、内存警告、前后台 |
| `capture.jsonl` | 每个 ARFrame 的元数据：时间、位姿、内参、跟踪状态、特征点数、曝光、有没有深度、方向是否稳定。没有像素 |
| `analysis.jsonl` | 每个分析完的帧：指标、栅格、距离、判定原因，深度附件的引用 |
| `mesh.jsonl` | 网格的增、改、删和分类数量，附件是完整网格 |
| `render.jsonl` | 每次绘制：提交、跳过原因、GPU 完成、实际提交的顶点数、图层 |
| `prediction.jsonl` | 无 LiDAR 时的模型输出、尺度拟合、各阶段耗时 |
| `path.jsonl` | 每次规划的路线点、目标、保留/撤销/重规划原因、参数（现在是 schema4） |
| `heartbeat.jsonl` | 约每秒：帧龄、FPS、发热、电量（-1 表示系统拿不到）、内存、丢帧 |
| `data-00000.bin` 等 | 深度和网格附件，无损压缩，分段存放 |

### 地面判定的诊断字段

`analysis.payload.diagnostics` 里能看出为什么这一帧没有地面或没有画出来：

- `depthReadStatus`、`confidenceReadStatus`：深度有没有、格式对不对、读没读出来；
- `depth`：有效、无效、超量程像素数，各置信度级别的数量；
- `groundConfirmationCount` / `Required`、`groundConfirmed`、`planeLocalHeightDelta`、`planeNormalDeltaDegrees`：地面连续确认（高度差小于 4 cm、法向差小于 3°、连续 3 次）；
- `groundReferenceMode`：`current_confirmed` 是本帧确认的地面，`retained_world_reference` 是沿用最近的地面参考；
- `modelState` 和 `modelBlockReasons`：可以有多个原因。

"算出了模型"和"画出来了"是两回事，要结合 `render.jsonl` 的 `surfacePresentationMode` 看（`current_depth`、`historical_wireframe`、`none`）。

## 附件格式

`attachment` 里有文件名、offset、压缩前后的字节数、`codec=deflate-raw` 和压缩前的 SHA-256。

从 offset 开始：两个 UInt32 LE（压缩长度、原始长度），然后是 raw DEFLATE 数据。Python 用 `zlib.decompress(data, -15)`。二进制先写，引用它的 JSONL 后写。

深度附件解压后：

1. UInt32 LE：JSON 头的长度；
2. JSON 头：宽高、epoch、frameID、时间戳、位姿、内参、参数、地面先验、方向稳定性、来源；
3. `width*height` 个 Float32 LE 深度；
4. 可选的 `width*height` 个 UInt8 置信度。没有就是 0 字节，不会补一个"高置信度"。

NaN、Inf 和无效像素原样保留。无 LiDAR 时附件里多一个预测支持掩码，置信度字节为 0。

网格附件（`mesh_frame_binary_v1`）解压后：UInt32 LE 头长度、JSON 头（id、epoch、revision、回调时间、变换、来源、数量），然后是 vertexCount×3 个 Float32 坐标、indexCount 个 UInt32 索引、classificationCount 个 UInt8 分类。不抽样。

## 限额

| 项 | 上限 |
|---|---|
| 分段文件 | 32 MiB |
| 每次启动 | 512 MiB |
| 整个 Diagnostics 目录 | 2 GiB |
| 待写队列 | 64 条、16 MiB，其中给事件留 8 条和 64 KiB |

到了上限就停止写新数据，界面和 `status.json` 都会标出来，不会覆盖或删旧数据。要清理，先导出，再用"文件"App 或 Xcode 删。

存的是每个分析帧（默认约 10 Hz），不是每个相机帧。256×192 的深度加置信度一帧约 240 KiB，不压缩时每分钟约 141 MiB，所以限额是必须的。

队列满时会丢记录，每个流都有丢弃计数。有丢弃的日志不能当完整记录用。iOS 强杀或断电可能丢掉最后约一秒的数据；没有终止事件不一定是崩溃。

## 读取

```sh
python3 scripts/read_diag.py /absolute/path/to/run --verify-data
python3 scripts/read_diag.py /absolute/path/to/run --extract-depth 2:151 --output /absolute/path/out
python3 scripts/read_diag.py /absolute/path/to/run --extract-prediction ...
```

读取器校验字节数、SHA-256、帧和网格身份，报告截断的尾行和损坏的附件。提取深度输出 `metadata.json`、`depth.f32le`、`confidence.u8`，不生成图片。缺的帧不会补。合成测试的记录标着 `source=synthetic`，不能当真机结果。

## 手动采样（Sessions）

开发版还可以手动保存单帧样本，放在 `Sessions/` 下：`manifest.json`、`metrics.csv`、`frames.jsonl`、`events.jsonl`，以及 `samples/<frameID>-<suffix>/` 里的深度、置信度、元数据、分析结果和网格。早期版本的样本里有 `rgb.jpg`，现在不再保存画面。用 `scripts/summarize_session.py` 汇总。
