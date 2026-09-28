# DIAG 自动空间测量记录（build 3起；build 4增加连续性诊断）

## 行为与隐私

- **每次启动应用**自动创建一个 `Documents/Diagnostics/<UTC时间>-<UUID>/`。启动、权限状态、能力、生命周期在相机未运行时也有记录；不会自动启动相机，仍需点击“开始”。
- 多次开始／停止ARSession使用同一个启动目录，按epoch隔离；下一次应用启动创建新目录，不覆盖旧数据。
- 自动保存已完成分析帧的 **Float32深度、UInt8置信度、内参、位姿、来源时间、参数及实际floor先验**，默认约10Hz，可随分析频率调整。即使地面或方向不可靠，也保存取得的深度观测，供排查。
- 自动保存处理到的 **ARMeshAnchor网格更新**（顶点、索引、逐面分类、变换、revision、回调时间）；新增／更新／删除／缓存丢弃可追溯。
- **不保存RGB、capturedImage、彩色视频、音频或GPS。** 原有手动样本按钮也改为仅空间数据；旧版本已经存下的RGB不会被自动删除。
- 深度和室内三维结构仍可能包含环境隐私。全部写应用本地，没有后台上传、第三方服务或新增定位／相册／麦克风权限。
- 这不是“全部硬件数据”或无损录制每个60Hz采集帧：ARKit未公开的独立LiDAR采集时间、内部SLAM地图和原始IMU不伪造记录；视觉特征只记录可用点数。完整RGB对齐和运动模糊检查仍需单独的用户录屏。

## 日志内容

所有JSONL记录有全局排队写入序号 `sequence`、`writtenUptime`、`payload`，可选 `attachment` 和日志自身开销 `diagnosticTiming`。写入时间不是传感器时间；采集与分析均保留源帧时间和epoch/frameID。

|文件|频率／内容|
|---|---|
|`manifest.json`|启动墙上时钟＋单调时钟基准、设备／系统／版本、格式、隐私、采样策略和限额|
|`status.json`|约每秒同步：各流尝试／成功／丢弃／失败计数，排队条数及字节、高水位、已写字节、错误、配额、最近生命周期和checkpoint；停止采集后也能更新|
|`events.jsonl`|启动、权限、能力、开始／停止／中断、参数／图层、冻结、热状态、内存警告、前后台等事件|
|`capture.jsonl`|每个接收的ARFrame的轻量元数据：时间、位姿／内参、追踪、worldMappingStatus、视觉特征点数、曝光、环境光估计、深度是否存在及格式／尺寸、方向角速度／回稳计时等。无像素图像|
|`analysis.jsonl`|每个完成分析帧：兼容FrameLog指标／栅格／距离／段、相机元数据、详细判定原因、原始深度数据附件引用|
|`mesh.jsonl`|网格版本／来源与分类数量；更新附件保留完整MeshSnapshot，删除不补造几何|
|`render.jsonl`|绘制提交、跳过原因、GPU完成、可测的drawable呈现回调。renderID连接三个阶段；保存显示帧／分析帧、门控原因、实际编码的表面／阻挡柱／通道顶点数、图层、完整视野矩形与displayTransform|
|`heartbeat.jsonl`|约1Hz：是否采集、权限、帧年龄、FPS、热状态、电池／低电量、resident内存、队列丢帧、网格缓存、当前参数和DIAG状态。电池-1表示系统不可用，不当作0电量|
|`data-00000.bin`等|深度帧与网格附件的无损压缩分段|

### 地面与显示失效原因

`analysis.payload.diagnostics`包含：

- `depthReadStatus`：ARKit未提供sceneDepth、深度格式不支持、buffer锁定／基址读取失败或available；另有独立 `confidenceReadStatus`。
- `depth`：总像素、有限／非有限／非正／量程外计数，各置信度级别及异常编码数，高置信度有效覆盖与该部分深度最小／最大／均值。
- `sampledPoints`、`priorCount`、`groundConfirmationCount`、`groundConfirmationRequired`、`groundConfirmed`。
- `planeOffsetDelta`、`planeNormalDeltaDegrees`、`forwardGroundProjection`。
- `modelState`、**多个** `modelBlockReasons`：例如floor先验不匹配、地面等待连续确认、参考方向过陡。方向不稳不再掩盖地面原因。

原来的安全判定阈值没有改变。`render`的显示资格与`analysis`的“算出了模型”是不同事实；CPU提交不等于GPU成功，GPU成功也不等于几何正确或安全。分析失败不会被写成一帧成功的空闲空间。

## 数据帧二进制格式

`attachment`包含文件名、offset、压缩／未压缩字节数、`codec=deflate-raw`与未压缩数据SHA256。

从offset开始：两个UInt32小端整数（压缩长度、未压缩长度），随后原始DEFLATE字节流。使用Apple Foundation的zlib压缩，无损；Python用 `zlib.decompress(..., -15)`。先写二进制，再写引用的JSONL。

深度附件解压后：

1. UInt32 LE JSON头长度；
2. JSON头：width/height、epoch/frameID/timestamp、相机pose/intrinsics、参数版本／参数、实际使用的floor priors、方向稳定性和source；
3. `width*height`个Float32 LE深度；
4. 可选的`width*height`个UInt8置信度，缺失时字节数为0，不补造高置信度。

深度NaN／Inf／无效像素的原始位模式也保留。网格附件是压缩后的MeshSnapshot JSON，由 `attachmentKind=mesh_snapshot_json`区别。

## 限额、可靠性和失效

- 32MiB目标分段，单次启动数据上限512MiB，整个Diagnostics目录2GiB；少量manifest／status控制数据另计。既有Sessions不计入Diagnostics限额，也不自动清理。
- 达到限额停止新增数据，UI和status明确标识；不静默覆盖／自动删除早期证据。用户先导出，再通过iOS“文件”或Xcode容器工具清理历史目录。
- 生产者队列最多64项，其中为事件预留8个计数槽位，并限制估计待处理内存16MiB；拒绝发生在构造原始数据／编码JSON之前。每个流都有丢弃计数，不能把有丢记录的日志称为完整回放。
- 编码、压缩、SHA256、写盘都在串行后台队列；每条记录保留排队／编码／压缩耗时，status包含写入耗时。实际性能仍需真机长时间检查。
- 约每秒同步文件，进后台时短暂申请后台执行，等待当前分析／网格工作后flush。iOS强杀、突然断电或后台执行到期仍可能丢最后的数据；未收到终止事件不能直接判为崩溃。
- 导出在日志队列上取一致快照，较大目录复制期间可能导致输入队列满并记录丢弃。**建议停止采集后导出。** 历史目录也可从设置导出。
- 默认保存的是分析帧而不是所有相机帧。比如256×192的深度＋置信度每帧约240KiB，10Hz未压缩约141MiB/分钟；不能因为没有RGB就认为存储一定很小。实际压缩率取决于现场数据，限额是必要的。

## 获取与分析

应用中：设置 → DIAG → “导出本次完整DIAG”或“导出历史DIAG”。

开发机读取已连接且可访问容器的设备（不启动相机，不上传）：

```bash
python3 /Users/yuanyuan/Desktop/Prts/PRTSTEST/scripts/pull_diag.py \
  --device 32826C27-26A1-511E-997F-5AD5CF3859E9 \
  --output /Users/yuanyuan/Desktop/Prts/PRTSTEST/build/diag-pull-unique
```

读取其中一个启动目录：

```bash
python3 /Users/yuanyuan/Desktop/Prts/PRTSTEST/scripts/read_diag.py /absolute/path/to/launch-directory --verify-data
python3 /Users/yuanyuan/Desktop/Prts/PRTSTEST/scripts/read_diag.py /absolute/path/to/launch-directory \
  --extract-depth 2:151 --output /absolute/path/to/extracted-data
```

读取器校验字节数、SHA256、帧／网格身份与文件路径，明确报告截断的JSON尾行和损坏附件。提取输出metadata.json、depth.f32le、confidence.u8，不生成图像。日志缺帧或缺置信度不自动修补。

合成测试记录固定标记 `source=synthetic`；模拟器manifest标记 `simulator_no_LiDAR_evidence`，不作为真实传感器验收。


## build 4 连续性诊断

- analysis.diagnostics增加groundReference（确认平面、源帧、时间、相机位置、epoch和参数版本）、groundReferenceMode、groundReferenceAge、groundReferenceInvalidation及geometryBasisMode。
- groundReferenceMode=current_confirmed表示本帧地面满足确认；retained_world_reference表示历史地面参考＋当前深度，**不允许当前可通行格或通道**。groundConfirmed仍代表当前地面，不会因缓存被改成true。
- 部分ground_fit_failed/ground_confirmation_pending原因可与modelState=built同时存在：本帧直接地面失败，但在严格时空上限内使用近期参考继续显示当前深度表面。需结合referenceMode理解，不应仅按原因字符串统计“没有渲染”。
- render.submitted增加surfaceSourceFrameID、surfacePresentationMode和surfaceAgeMS。current_depth是当前深度模型；historical_wireframe是短暂历史线框；none是没提交表面顶点。模型输出合格不等于实际绘制，历史线框也不属于当前测量。
- read_diag.py分别汇总groundReferenceModes与surfacePresentationModes，旧build字段缺失明确标legacy_or_unavailable。
- scripts/replay_diag.swift可在macOS上对已保存的分析帧附件进行离线重放，校验SHA256、保留真实深度/置信度，输出source=device_replay。它不是完整ARSession回放，也不重建缺失记录，不代替实时Metal画面或性能验收。编译时与SpatialCore源文件一起传给swiftc -O -parse-as-library。


## build 5 网格编码与日志保留微调

- 网格attachmentKind改为mesh_frame_binary_v1。解压后为UInt32 LE JSON头长度、JSON头、vertexCount×3个Float32 LE坐标、indexCount个UInt32 LE索引、classificationCount个UInt8分类。头内保留id、epoch、revision、callbackTime、transform、floorPriors、source和数量。
- 不抽样/丢弃网格顶点或面，Float32位模式及索引/分类精确保留。外层仍用既有DEFLATE分段和SHA256校验。read_diag.py兼容build 3/4的mesh_snapshot_json，也支持新二进制网格校验。
- 保留64项/16MiB总队列上限，为事件另预留64KiB字节空间（除既有8个计数槽位），防止网格用尽内存额度后连后台/错误事件都无法入队。仍会如实记录过载丢弃，不承诺零丢失。
- analysis.diagnostics新增planeLocalHeightDelta，与planeOffsetDelta分别表示手机位置处的平面距离差和世界原点处的平面系数差。连续确认使用前者<4cm、法向<3°、连续3次；不是扩大容差。
- manifest.metadata记录地面比较方式、表面三角面预算和网格二进制编码。空间数据仍不含RGB，所有单次/总磁盘配额保持不变。


## Build 6 无 LiDAR 数据

新增 prediction.jsonl 和压缩 relative_depth_frame 附件（相对逆深度、非米）；记录 Apple 模型版本、输入帧身份、方向、原生平面快照、尺度配对／拟合和各阶段耗时。通过尺度校验的 analysis 附件追加 predictionSupportBytes 及独立掩码；confidenceBytes 仍为0，绝不把预测质量标成硬件高置信度。read_diag.py 支持 --extract-prediction 并校验新增附件。无LiDAR手动样本在DIAG中标记 manual=true。旧LiDAR导出保持兼容。详情见 NO_LIDAR.md。

## build 7 预测连续性

自动日志另外保存跨帧重投影的参考数/内点数/空间分区/米制残差/原因、原生point ID（存在时）、未通过跨帧确认的单帧拟合和地面短时参考状态。`read_diag.py` 汇总 `predictionScaleReasons`、`predictionGroundModes` 及确认数；旧日志不补造这些字段。相对深度与米制预测覆盖率是两个概念。模型数据仍无传感器置信度，不落盘RGB；参考轮廓或历史线框不是当前占用证据。

### build 8 路径与触觉

新增path.jsonl记录每次分析的路线点、来源、最后完整验证时间、保留/撤销/重规划原因和配置；反馈记录当前姿态对应的角度、横偏、前视点以及触觉请求。render.jsonl增加真实提交的路径顶点数与历史状态。read_diag.py自动汇总。强振API提交不等于完成触觉感知或安全认证。详见PATH_PREDICTION.md。


## build 9 扇形目标与足迹宽度

`path.jsonl`的options追加`minimumWidth`（默认0.50m总宽度）；PathUpdate追加可选`reachableCells`、`targetBearingDegrees`、`targetGroundDistance`、`approachDistance`，路径追加`footAtPlan`。`points`和长度只代表有支持的实线段，不能把脚下连接长度算成已观测地面。目标按±45°扇形选择，历史目标保留世界坐标。`render.jsonl`追加实际提交的`pathApproachVertices`、`pathTargetVertices`；`pathVertices`为包含目标环的路径绘制总顶点数。旧记录缺失字段不补造。

read_diag.py分别汇总`pathTargetDistanceMeters`、`pathUnknownApproachMeters`、`pathReachableCells`、连接线与目标提交数；与既有`pathLengthMeters`区分。脚下是相机地面投影，不是已测足部位置；虚线仍未验证；API触觉请求/绘制提交不构成安全性证据。


## build 10 固定目标与左右触觉

PathUpdate新增`goal`（id/epoch/point/plane/selectedAt/maxDistance）和`goalChangeReason`；目标可在`path=null`时保留，不能将其计为已验证几何/可绘制路线。`target_reached`、`target_out_of_range`、`target_blocked`记录重选原因；同目标绕障保留ID。PathOptions增加targetHalfAngleDegrees/arrivalRadius/alignmentDegrees，旧设置解码保留已有选项并使用新字段默认值。PredictedPath增加可选targetRange。

触觉pulse.kind新增left_double/right_long；aligned_once保留。可选segments保存每段relativeTime/duration/intensity/sharpness，pulse.duration是包含组内间隔的总跨度。旧deviation记录仍可读取。read_diag.py新增fixedGoalChanges/distinctFixedGoals/fixedGoalWithoutPathFrames，原hapticRequestedPulseKinds分别统计左右/对准请求，不视为实际触觉完成。

replay_monocular.swift读取原capture.directionStable用于选点稳定性，不改变PredictedGeometry的sourceDirectionStable=false（后者保留禁止模型输出授权严格安全通道的含义）。缺失capture方向数据按不稳定处理，不伪造。所有回放仍是记录输入的离线重算，不是真机实时性能或精度真值。
