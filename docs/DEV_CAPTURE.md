# 开发信息采集模式

此功能仅在 Swift 编译条件 **PRTS_DEV_CAPTURE** 下存在。不是 DEBUG 的别名，不会默认随 Debug/Release 打开；标准项目配置未引用开发配置文件。

## 编译

在项目根目录执行：

```sh
# 开发采集包：仅本次构建注入编译标记（签名沿用原项目）
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -xcconfig configs/DevCapture.xcconfig \
  -derivedDataPath build/DevCapture build

# 普通包：独立构建目录，不传开发 xcconfig
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Standard build
```

也可以仅为专门的本地开发 configuration 在 `SWIFT_ACTIVE_COMPILATION_CONDITIONS` 中添加 `PRTS_DEV_CAPTURE`，但不要加到普通发布配置。配置文件不放入 App 资源。

## 使用与隐私

开发包设置顶部出现“开发 · 信息采集模式”。每次启动默认关闭，不持久化开启状态；需在知情同意的受控环境手动开启，并通过主页面开始感知。无相机权限或未开始 ARSession 时不采集。主页面持续显示独立于 HUD 开关的采集提示。

关闭、停止 ARSession、离开前台及导出会停止采集并结束 MP4 写入。重新开始需要再次手动开启。设置中“停止采集并打开 DIAG 导出页”会打开原有导出页面；导出完整 DIAG 包含下面的子目录。导出会等待录像结束，不改变原先的文件分享方式。

隐藏主页面 RGB **不是停止摄像机或视频记录**。不采集音频，不新增 GPS、麦克风或相册授权，不上传。压缩视频、三维场景及特征点均可能泄露现场隐私。

普通包不包含该模式 UI、录像类或相应采集调用；原有不含 RGB 的 DIAG 不受影响。安装普通包不会破坏性删除以前开发包保存的数据，因此导出旧 DIAG 仍可能包含以前的视频，分享前应检查。

## 实际记录的内容

选取**已完成分析的源帧**，最高 5 FPS（不是独立的实时30/60 FPS录像）。只保留一个正在编码/待处理的样本，编码忙则丢弃，保留实际时间间隔，不插帧。分析慢时实际录像帧率更低。

- RGB：未叠加算法标注的摄像机帧，H.264 MP4，目标码率800 kbps，最长边960，偶数像素尺寸，不裁切；无音轨。属于缩小、有损的原始画面，不是无损传感器RAW。
- LiDAR：分析实际使用的 `sceneDepth` Float32、可用时的 UInt8 置信度；不保存未使用的平滑深度。
- DA：应用使用的、映射回摄像机坐标的原始相对逆深度 Float32（校准前，不是热图），输出尺寸、模型名、尺度样本、暂定和接受的尺度参数、尺度跟踪判定、原生地面参考及耗时。**不是 CoreML 原始输入方向的张量**，而是已完成输入/输出坐标映射后的模型数值输出。
- DA 校准后：只有实际可用才保存米制预测及 predictionSupport；后者不是传感器置信度。未校准的模型仍可保存相对输出和RGB；不伪造米制数据。
- ARKit：源帧内参、位姿、追踪/映射状态、曝光/照度、方向；算法使用的水平平面边界；最多512个稀疏世界特征点及ID，记录总数和采样步长。
- 网格：样本记录 anchor ID、revision、回调时间；完整顶点、索引、分类与变换复用父 DIAG 的 `mesh.jsonl` 和附件，不在每个视频帧复制全部网格。必须检查相关版本是否实际保存，缺失不能补成当前证据。
- 分析：完整 `AnalysisResult`（地面、栅格、表面三角形、候选区域、参数及拒绝原因），`PathUpdate` 和实际使用的路径选项。

不是 ARKit 私有SLAM地图或原始IMU；没有独立LiDAR硬件时间戳。水平面时间是ARFrame快照时间，不是各表面真实观测时间。

## 格式

```
Documents/Diagnostics/<run>/
  manifest.json, analysis.jsonl, mesh.jsonl, data-*.bin, ...  # 原有 DIAG
  dev-capture-<UUID>/
    manifest.json
    status.json                 # recording / completed / failed
    camera.mp4
    samples.jsonl               # 帧身份、PTS、附件描述
    <epoch>-<frame>.evidence.json.deflate
    <epoch>-<frame>.depth.bin.deflate        # 可选
    <epoch>-<frame>.relative.f32.deflate     # DA 可选
```

附件为 **raw DEFLATE**，Python用 `zlib.decompress(data, -15)`。每条索引有压缩/原始字节数和未压缩SHA256。evidence JSON的非有限浮点值明确编码为 `nan/+inf/-inf` 字符串。

深度附件复用 `DepthFrameCodec`：UInt32 LE头长 + JSON头 + Float32 LE深度 + 可选UInt8置信度 + 可选预测支持掩码。模型relative附件为行优先Float32 LE，尺寸在evidence.model中。两类浮点二进制保留NaN/Inf比特，不量化，不用0填洞。

视频PTS = 源ARFrame.timestamp − manifest.originARTimestamp，timescale为60000。分析可能延迟完成，但索引始终指向其**原始输入图像和位姿**，不是编码时最新的摄像机帧。视频使用摄像机原始方向；显示方向保存在capture中，旋转时无需混改内参。投影到缩小视频时按manifest中的实际宽高分别缩放内参。

## 限制与可复现性

- 单段最长10分钟、本次进程开发采集约256 MiB软上限，空闲磁盘不足256 MiB停止。视频编码/文件封装及manifest有少量额外开销；不自动删除历史。跨启动历史由用户管理，父DIAG还受原有总配额限制。
- 默认深度/模型输出保留原尺寸，空间压缩无损；仅时间采样降低。可从采样附件重放几何，但无法恢复被跳过的帧。
- 视频有损且缩小，适合现场语义参考；**不能用重编码视频重跑DA来要求原模型输出逐bit一致**。比较后处理算法应使用保存的相对输出或深度附件。
- 突然强杀/断电可能留下不完整MP4；检查status与真实解码，不把recording文件当成完整采集。
- 数据写入失败可能留下未被索引引用的附件，索引是成功提交样本的入口；失败状态不能宣称无丢帧。
- 现有DIAG和开发采集队列独立，丢弃情况分别检查，不能仅凭视频存在断言父日志齐全。

## 检查

```sh
python3 scripts/read_dev_capture.py /absolute/path/to/dev-capture-UUID
python3 scripts/read_diag.py /absolute/path/to/run --verify-data
```

第一个工具验证帧/时间关联、附件长度、SHA256、深度格式及模型输出尺寸；不解码视频，也不代替检查父DIAG网格版本。视频解码、内容方向、真实设备持续负载仍需真机验证。

合成测试显式使用 `synthetic_test` 来源，不作为真机验收。开发/普通编译应使用不同DerivedData，检查普通包无 `DevCaptureRecorder` 类型符号及开发采集入口字符串。

## 开发者选项与主页（2026-09-29）

设置中的“开发 · 信息采集模式”和“空间感知与演示”已合并为 **开发者选项**，整个区域只在 `PRTS_DEV_CAPTURE` 构建中存在。

- “主页面参数指标与图例”：控制主页上方技术面板；原演示分页仍可细分指标栏和图例显示。
- “主页面测试指令栏”：控制主页底部测试输入及发送按钮。
- 两个显示开关默认开启、持久保存，与每次启动默认关闭的视频采集开关独立。
- 图层/路径/DIAG参数页和演示选项也仅编入开发包。正常构建不读取开发包保存的显示图层选项，避免继承隐藏摄像机等不可恢复的显示设置；不清除开发包偏好。
- 删除了开始按钮上方重复的后端状态卡片。保留主要相机状态、必要操作错误及简短实验风险说明。
- 录像提示独立于技术面板开关：关闭调试面板不隐藏正在录像的提示。

该变化不停止普通包的空间分析、方向反馈和既有不含RGB的DIAG。

## build16 policy / diagnostics

`PRTS_DEV_CAPTURE` only enables developer tools and opt-in recording. Both ordinary and Dev builds use `verified_continuous_v1`; neither recording nor its compile flag selects the historical occupancy-only strategy. Route journal schema2 fields and old-format compatibility are described in [route continuity](architecture/ROUTE_CONTINUITY_2026-09-29.md). Pass `PRTS_SOURCE_COMMIT=$(git rev-parse HEAD)` to xcodebuild for traceable binary metadata (otherwise unavailable).
