> **build 3 更新：** 每次应用启动另建完整DIAG，自动保存分析帧的深度／置信度和网格；不再保存新的RGB图像。详见 `Docs/DIAGNOSTICS.md`。以下Sessions布局继续兼容旧评测；历史RGB字段说明仅适用于旧版本。

# 导出数据与离线评测

默认只写指标、参数、状态事件和紧凑几何，不自动保存现场 RGB／深度。只有确认手动采样后保存原始传感器图像。无网络上传或相册写入。

## 会话目录

```
manifest.json
metrics.csv
frames.jsonl
events.jsonl
samples/<frameID>-<suffix>/       # 仅手动操作时存在
    rgb.jpg
    depth.f32le
    confidence.u8                # 当该帧 confidenceMap 存在
    metadata.json
    analysis.json                # 有同 epoch/frameID 分析结果时才存在
    mesh-snapshots.json
export-status.json               # 导出快照附加
```

### manifest

schemaVersion、source（本机传感器 `device`，合成测试 `synthetic`）、设备硬件标识（不是序列号）、系统版本、App版本／build／Bundle ID、能力列表、参数、epoch、日期、坐标约定和隐私声明。打包版本以应用版本和build标识；做对比实验时另外归档源代码或生成源文件 SHA256 清单，不用相同build冒充同一实现。

### 每帧 frames.jsonl

一行一个已完成的**分析帧**，不是全部60Hz采集帧。含epoch、frameID、ARFrame timestamp、参数版本／快照、相机姿态／RGB内参、估计平面、参与先验的mesh来源ID／revision／callbackTime、深度覆盖率、状态、距离、候选段、阶段时间和 metrics。

自 build 2 起明确区分：

- `metrics.geometryOutputEligible`：写该行时，此结果是否满足几何显示门控（不等于存在非空模型）。
- `metrics.outputEligible`：保持为**通道／方向距离**的显示资格，不能用几何资格替代；离线评测脚本继续使用此字段。
- `sourceDirectionStable`：分析源帧的方向状态。完整 `analysis.json` 中该字段可选，旧样本缺失时不得据此授权通道。
- CSV新增 `geometryOutputEligible`、`guidanceOutputEligible` 两列（0/1）；后者对应 JSON 的 `outputEligible`。旧文件缺列表示未知，不补造记录。

资格是写该行时的状态，它不证明某一像素真的呈现给用户；呈现时间和源帧ID另行记录。离线错误候选评估只比较当时合格的输出，过期计算不能伪装成已经展示。

顶层 `unknownFraction`／CSV在未建立地面时保守记1（名义4m×3m窗口全未知），不暗示此时已经有可投影的地面坐标系。grid 为可选：未建立参考平面时不存在。存在时：

- `columns=30`、`rows=40`、`cellSize=0.1`、`halfWidth=1.5`、basis。
- `states`：Base64编码原始字节，row-major，0未知／1障碍／2候选。
- `reasons` 字符串表，`reasonIndices` 是Base64的表索引字节。
- `footprint`：Base64字节，1为人体足迹通过，0为不通过。参考地面尚不稳定时允许为空数组或全0，绝不可按空数组解释成全可通行。
- 候选段 `cellIndices` 对应该grid；最小观测带宽、段长、起点距离均是米。

```python
import base64, json
row = json.loads(line)
if row.get("grid"):
    cells = list(base64.b64decode(row["grid"]["states"]))
```

### 时间与耗时

时间戳和采集／mesh回调时间使用单调 uptime 域；manifest日期为墙上时钟。epoch变更即不能拼接同一世界坐标。mesh回调时间不等于每面采样时间。

CSV包含coverage、unknownFraction、各FPS、captureMS、depthMS、groundGridMS、meshMS、channelMS、cpuDrawMS、gpuMS、presentAgeMS、sourceAgeMS、droppedFrames、thermal。depthMS包括CVPixelBuffer拷贝和点生成，JSON保留depthCopy细分。captureMS只计回调打包，非传感器曝光／采样开销。模拟器不支持呈现回调，空值不转换成0。

`events.jsonl` 包含会话开始／结束、输出门控变化、参数更新、热状态变化、失效／中断等；有界队列过载会丢记录，导出状态记录累计丢弃。指标采样只覆盖已完成分析，临界热暂停／无帧区间须结合事件、墙上时钟和现场录像解释，不能仅凭分析行跨度证明完整30分钟稳定运行。

### 手动同步样本

`depth.f32le` 是未平滑sceneDepth，按行主序Float32小端，无行padding；NaN等无效值原样保留，单位米、轴向深度。`confidence.u8` 同尺寸，0低／1中／2高；文件缺失意味着 unavailable，不是全2。

`rgb.jpg` 是同一ARFrame的capturedImage转码JPEG，保留原始传感器方向，**不是屏幕截图，不是无损RGB buffer**。若评估像素级色彩应另做无损采样扩展。metadata包括原始和深度尺寸／内参、pose、tracking、epoch、frameID、时间、参数和显示模式。

手动样本优先冻结帧，否则最近已分析帧；可能比屏幕当前帧旧，必须读timestamp。`matchingAnalysis` 明确是否有同帧分析；不匹配不保存其他帧结果冒充。analysis包括其使用的floor priors；mesh快照是保存请求时的结构缓存，版本可能与analysis使用的不同，必须按ID/revision核对。

**观测窗口是一个当前深度帧。** 虽可复算该帧点／格，地面连续确认依赖前序帧，样本不包含完整前序RGB/depth；不宣称能够完整重放跨帧状态。用frames/events追踪背景，需完整复现时另设计经同意的短时有限环形采样。

## 统计命令

```bash
python3 scripts/summarize_session.py /absolute/path/to/exported-session \
  --reference /absolute/path/to/independent-ground-truth.csv \
  --out /absolute/path/to/report.json
```

不提供 `--reference` 仍会给出性能、覆盖率和热状态统计，但距离／宽度／错误候选指标标为 **UNVERIFIED**，不输出猜测精度。空值／NaN不按0误差计算；每个统计有n、mean、p50、p95、max，另有5分钟窗口统计。覆盖率／未知率的范围为0–1。

### 人工真值模板

`Reports/ground-truth-template.csv` 只有表头，需按已记录的epoch/frameID/sector填表：

- sector：`left`／`center`／`right`。
- `gt_obstacle_ground_m`：卷尺测相机在估计区域真实地面的投影至对应障碍前缘。保留测量不确定度于notes。不能填相机斜距或直接复制热图。
- `gt_channel_width_m`：与候选段最窄截面对应的独立实际净宽。斜向、不规则通道须在notes说明横截面定义，必要时人工分析。
- `candidate_label`：`safe`／`unsafe`／`unknown`，是人工对**该候选段是否穿过不可通过／未观测区域**的受控标注；safe仅为该标注分类，不是应用安全承诺。
- notes：布置ID、重复次数、参考误差、影像编号、风险原因。

报告按epoch/frameID/sector精确关联；重复标注拒绝。无读数会计入 unavailable，不能用零误差掩盖低可用率。发现unsafe candidate单独FAIL；无已标注失败不代表通过。动态场景须现场时间对齐录像／人工标注，不能用ARKit分类／深度作为评测真值。

## 存储与隐私边界

每会话配额512MiB；队列、单帧、网格缓存有上限；多个会话和临时导出副本会累计空间，应在备份后通过Files人工管理。磁盘满／权限错误显示记录失败而非阻塞摄像头。导出最好在停止后执行。部分写入失败会留下可见的不完整样本，必须核对文件和metadata，不应默认为成功采样。


## 2026-09-27 表面模型扩展

新增 `frames.jsonl.surfaceModel` 可选摘要字段（地面／突起三角面数、相对地面阈值、最高观测高度、步长），手动样本 `analysis.json.surfaceModel` 则包含完整三角面。`stageMilliseconds.surfaceModel` 和 CSV 末列 `surfaceModelMS` 记录本阶段耗时。旧记录缺该字段表示未提供，不等于零突起；详见 `Docs/SURFACE_MODEL.md`。


## Build 6 扩展

DiagnosticStream 增加 prediction。relative_depth_frame 二进制为 UInt32LE JSON头长度＋头＋Float32LE相对逆深度（分析分辨率）。头中 units=relative_inverse_depth_not_meters。analysis 的 depth_frame 保留schemaVersion=1，新增可选 predictionSupportBytes/depthEvidence，按 depth、confidence、predictionSupport 顺序排列；旧文件缺失该字段按0处理。掩码不能作为confidence读取。来源和模型版本不可省略；详见 NO_LIDAR.md。

### build 7 无LiDAR连续性诊断

`prediction.jsonl` 及其相对深度附件头追加兼容字段：
- `scaleSamples[].featureID`：可选 UInt64 原生点标识；历史日志缺失不伪造。
- `provisionalFit`：当前帧质量筛选通过的拟合，尚未通过跨帧门控也保存；最终 `calibration` 只在确认通过后存在。
- `scaleDecision`：确认数、原因、投影/可评估/内点数量、空间分区、共享ID数、世界参考冲突数、中位相对残差及参考时间差。
- `groundReference`：模式、原因、有界平面和参考年龄。年龄不是表面的实际观测年龄；retained_reference 不生成尺度样本或净空。
- `relativeCoverage`：模型相对张量有限值比例，区别于有效米制预测覆盖率。

读取器兼容旧记录，分别汇总尺度拒绝原因与地面模式；手动重复样本不重复计入预测确认统计。`retained_native_reference` 与 `metric_world_reference_conflict` 会进入分析/展示失效判定，追踪与生命周期门槛不变。

## build 8 path.jsonl

DIAG新增path流：prediction包含PathUpdate/PathOptions与epoch/frameID/parameterVersion/timestamp；feedback包含pathID、PathHeading、可选PathHapticPulse及触觉API状态。render记录pathID/pathVertices/pathHistorical/pathAge。路径时间是ARFrame时间基准，不是额外硬件采集时间。路径是实验预测、非真值。历史路径只保存单条有界世界线，不将历史未知格转换为可通行。


## build 9 扇形目标与足迹宽度

`path.jsonl`的options追加`minimumWidth`（默认0.50m总宽度）；PathUpdate追加可选`reachableCells`、`targetBearingDegrees`、`targetGroundDistance`、`approachDistance`，路径追加`footAtPlan`。`points`和长度只代表有支持的实线段，不能把脚下连接长度算成已观测地面。目标按±45°扇形选择，历史目标保留世界坐标。`render.jsonl`追加实际提交的`pathApproachVertices`、`pathTargetVertices`；`pathVertices`为包含目标环的路径绘制总顶点数。旧记录缺失字段不补造。

read_diag.py分别汇总`pathTargetDistanceMeters`、`pathUnknownApproachMeters`、`pathReachableCells`、连接线与目标提交数；与既有`pathLengthMeters`区分。脚下是相机地面投影，不是已测足部位置；虚线仍未验证；API触觉请求/绘制提交不构成安全性证据。


## build 10 固定目标与左右触觉

PathUpdate新增`goal`（id/epoch/point/plane/selectedAt/maxDistance）和`goalChangeReason`；目标可在`path=null`时保留，不能将其计为已验证几何/可绘制路线。`target_reached`、`target_out_of_range`、`target_blocked`记录重选原因；同目标绕障保留ID。PathOptions增加targetHalfAngleDegrees/arrivalRadius/alignmentDegrees，旧设置解码保留已有选项并使用新字段默认值。PredictedPath增加可选targetRange。

触觉pulse.kind新增left_double/right_long；aligned_once保留。可选segments保存每段relativeTime/duration/intensity/sharpness，pulse.duration是包含组内间隔的总跨度。旧deviation记录仍可读取。read_diag.py新增fixedGoalChanges/distinctFixedGoals/fixedGoalWithoutPathFrames，原hapticRequestedPulseKinds分别统计左右/对准请求，不视为实际触觉完成。

replay_monocular.swift读取原capture.directionStable用于选点稳定性，不改变PredictedGeometry的sourceDirectionStable=false（后者保留禁止模型输出授权严格安全通道的含义）。缺失capture方向数据按不稳定处理，不伪造。所有回放仍是记录输入的离线重算，不是真机实时性能或精度真值。

### Build 11 地面确认性能诊断（2026-09-28）

- manifest metadata新增 `buildConfiguration`（Debug/Release）、`clearanceFramePixelBudget`（当前262144）。旧日志没有这些字段，读取时应视为未知而非推断。
- 分析 `stageMilliseconds` 新增 `groundFit`、`gridClearance`，保留原 `groundGrid`。未执行相应阶段的帧可能没有该键；缺失不代表零开销。
- 地面尚未确认时只统计直接支持/障碍，不运行身体净空检查。净空回退预算耗尽返回未知，不能作为可通行证据。
