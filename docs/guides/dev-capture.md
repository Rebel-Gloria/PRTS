# 开发版和采集

开发版比正式版多了调参界面、主页指标、测试指令栏，以及一个可以录下画面和传感器数据的采集功能，用来复盘实地测试。这些都只在编译开关 `PRTS_DEV_CAPTURE` 打开时才编进去，正式版里没有这部分代码。

## 编译

第一次编译前先跑 `zsh Vendor/LocalVLM/prepare.sh`，准备离线看图模型，见 [本地视觉模型](../features/local-vlm.md)。

`PRTS_DEV_CAPTURE` 不是 DEBUG 的别名，工程自带的配置都不带它，只能通过 `configs/DevCapture.xcconfig` 加上：

```sh
# 开发版
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -xcconfig configs/DevCapture.xcconfig \
  -derivedDataPath build/DevCapture build

# 正式版：用另一个构建目录，不传 xcconfig
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath build/Standard build
```

加上 `PRTS_SOURCE_COMMIT=$(git rev-parse HEAD)`，可以把源码提交号写进二进制。两种包要用不同的 DerivedData。检查正式版：里面不应该有 `DevCaptureRecorder` 这个类型，也不应该有采集入口的字符串。

正式版和开发版用同一套避障算法。开采集不会改变规划。

## 开发版多出的界面

设置里的"开发者选项"：

- 主页参数指标与图例、主页测试指令栏：两个显示开关，默认开，会记住；
- 保存相机视频与分析数据：每次启动都是关的，不记住；
- 演示模式选项、图层/路径/触觉/DIAG 参数页。

正式版不读开发版存下的显示设置，所以不会继承"隐藏相机画面"之类改不回来的设置。正式版的画面固定是 `RenderOptions.product`：只有相机画面，加上用户可选的扫描网格。

## 采集

在设置里手动打开，再在主页点开始，才会录。没有相机权限或者 ARKit 没在跑时不录。录像时主页一直显示提示，关掉调试面板也不会隐藏。

关闭开关、停止避障、切到后台、导出时都会停止录像并写完 MP4。要再录得重新打开。"停止采集并打开 DIAG 导出页"会等录像写完再打开导出页。

隐藏主页画面不等于停止录像。不录音，不要位置、麦克风、相册权限，不上传。但视频、三维场景和特征点都可能拍到现场的隐私，分享前要检查。装回正式版不会删掉以前开发版录的数据。

## 录了什么

只录**已经分析完的帧**，最多每秒 5 帧。编码忙就丢帧，不补帧，保留真实的时间间隔。

- **画面**：没有叠加标注的相机原图，H.264 MP4，800 kbps，最长边 960，不裁切，没有音轨。是缩小的有损画面。
- **LiDAR**：分析实际用的 `sceneDepth`（Float32）和置信度（UInt8）。
- **Depth Anything**：映射回相机坐标后的相对逆深度（Float32，校准前），加上模型名、尺寸、尺度样本和尺度参数、地面参考、耗时。尺度校准通过后才另存米制深度。
- **ARKit**：内参、位姿、跟踪状态、曝光、方向、水平平面、最多 512 个特征点。
- **网格**：每帧只记 anchor ID 和版本号，完整网格在父 DIAG 的 `mesh.jsonl` 里，用时要核对版本对得上。
- **分析结果**：完整的 `AnalysisResult`、`PathUpdate` 和当时的路线参数。

没有 ARKit 内部的 SLAM 地图和原始 IMU，也没有 LiDAR 硬件时间戳。

## 文件格式

```
Documents/Diagnostics/<run>/
  manifest.json, analysis.jsonl, mesh.jsonl, data-*.bin, ...  # DIAG
  dev-capture-<UUID>/
    manifest.json
    status.json                 # recording / completed / failed
    camera.mp4
    samples.jsonl               # 每帧的身份、PTS、附件
    <epoch>-<frame>.evidence.json.deflate
    <epoch>-<frame>.depth.bin.deflate        # 有 LiDAR 时
    <epoch>-<frame>.relative.f32.deflate     # 有 Depth Anything 时
```

- 附件是 raw DEFLATE，Python 里用 `zlib.decompress(data, -15)`。索引里有压缩前后的字节数和压缩前的 SHA-256。
- evidence JSON 里的 NaN 和无穷写成字符串 `nan` / `+inf` / `-inf`。
- 深度附件用 `DepthFrameCodec`：UInt32 LE 头长度 + JSON 头 + Float32 LE 深度 + 可选 UInt8 置信度 + 可选预测支持掩码。relative 附件是行优先的 Float32 LE，尺寸在 `evidence.model` 里。浮点不量化，不用 0 填洞。
- 视频 PTS = 源帧的 `ARFrame.timestamp` − `manifest.originARTimestamp`，timescale 60000。索引指向的是**分析用的那一帧**，不是编码时最新的一帧。视频保持相机原始方向；投到缩小的视频上时，内参按实际宽高缩放。

## 限制

- 单段最长 10 分钟；每次启动大约录 256 MiB；剩余空间不足 256 MiB 时停止。不会自动删旧数据。
- 深度和模型输出是原尺寸、无损压缩的，可以拿来重放几何；被跳过的帧补不回来。
- 视频是有损的，只适合看现场；不能拿视频重跑 Depth Anything 去对比原输出，要用存下的附件。
- 强杀或断电可能留下不完整的 MP4，先看 `status.json`。
- 写入失败时可能有没被索引引用的附件，以索引为准。DIAG 和采集的队列是分开的，丢帧要分别查。

## 检查数据

```sh
python3 scripts/read_dev_capture.py /absolute/path/to/dev-capture-UUID
python3 scripts/read_diag.py /absolute/path/to/run --verify-data
```

第一个检查帧和时间的对应、附件长度、SHA-256、深度格式和模型尺寸，不解码视频。

## 路线日志字段

`path.jsonl` 现在是 schema4。旧记录里没有的字段按"没有"处理，不要推断补上。

- schema3：`plannedLength`、`planned` 状态；可选的 `turnCandidateLength`、`turnReason`、`routePointCount`、`turnAngle`（即使转向被拦也记录实际偏离角）。
- launch manifest 里的 `routeAlgorithmRevision` 标明算法版本。
