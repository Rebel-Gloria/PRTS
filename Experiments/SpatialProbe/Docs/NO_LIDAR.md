# 无 LiDAR 分支 — build 6

## 模式与使用

设置 → **模拟无LiDAR设备**。

- 支持 `sceneDepth` 的设备：默认关闭，可以打开以测试无 LiDAR 数据分支；用户选择保存在应用偏好中。
- 不支持 `sceneDepth` 的设备：强制开启、控件禁用，Engine 同样不能将它关闭；不靠设备型号猜测。
- 切换时停止并重建 ARSession，清空帧、模型结果、场景网格、平面和历史几何，不跨模式共享证据。
- 无 LiDAR 分支配置 `.horizontal`、`.vertical` 平面检测，不请求 `sceneDepth`、`smoothedSceneDepth` 或场景网格重建；处理器拒绝读取旧 sceneDepth。
- `ARWorldTrackingConfiguration.isSupported` 仍是运行前提。模拟器不假装提供 ARKit 传感器数据。
- LiDAR iPhone 上的开关模拟的是**应用数据/API分支**；公开配置不能证明 ARKit 内部完全没有使用硬件辅助。最终仍需在真正的无 LiDAR iPhone 上验收。

每次启动自动 DIAG；点击开始才申请相机／运行 ARSession。没有网络推理、模型运行时下载、麦克风或定位权限需求。

## 模型来源、许可与真实接口

采用用户指定的 `apple/coreml-depth-anything-v2-small`，选择官方 `DepthAnythingV2SmallF16.mlpackage`，未转换为别的权重，也没有改成 Metric 或 DA3。

- 固定仓库版本：`cfef6f6f2a70783dedc0bfae40cecbc2052285d3`。
- 实际包约 49.8 MB；SHA256 清单：`App/Models/provenance.json`。
- 实际 Core ML 描述：RGB/BGRA 输入 `image` **518×392**；输出 `depth` **518×392、OneComponent16Half**。
- 编译后的 MIL 确认末端是 `predicted_depth / reduce_max(predicted_depth)`：输出为按帧归一化的相对逆深度，**不是米**。
- Apple 模型卡文字中的 518×396 与实际包描述不一致；运行代码读取模型描述，不照抄文本尺寸。
- Apple 模型卡中的 abs-rel 是转换结果相对 PyTorch 输出的差异，**不是对真实距离的误差保证**。
- Apache 2.0 许可全文和 Apple 模型卡随工程保存。模型使用范围不等于 Apple 对本应用的安全背书。

官方来源：
- https://huggingface.co/apple/coreml-depth-anything-v2-small
- https://github.com/DepthAnything/Depth-Anything-V2
- https://developer.apple.com/documentation/arkit/understanding-world-tracking
- https://developer.apple.com/documentation/arkit/arplaneanchor

## 显示与坐标

1. 取当前 ARFrame 的 RGB、相机内参、位姿和时间；同一帧参与推理和反投影。
2. 根据界面方向将 RGB 转正，等比例留边送入实际 518×392 输入，不裁掉完整摄像头视野。
3. 读取浮点输出，逆转留边与旋转变换，映射到原始相机方向的 256×192（具体高度按输入比例计算）分析图。没有把 8 位热图用作几何。
4. 显示深度或 RGB＋深度叠加时使用对应**推理输入帧**的 RGB，显示其源时间；不能把旧深度贴到更晚的 RGB 上。
5. 仅看 RGB 时保持实时摄像头画面；世界几何用显示帧的新位姿重投影。
6. 未确认尺度：热图标为“相对深度／无单位／相对近远”。确认尺度：标为“预测轴向深度 m”。
7. 模型没有传感器 `confidenceMap`。置信度层显示不可用，不把模型数据伪装成等级 2。
8. 冻结时保存匹配的输入帧与预测结果。无图像落盘；冻结仅驻留内存。

## 原生平面参考

- 从当前 ARFrame 的 `ARPlaneAnchor` 读取水平平面边界、世界变换和分类。
- 平面分类能力与 LiDAR 网格分类分开检测。
- 原生轮廓：蓝色表示 Apple floor 分类，黄色表示其他／未确认平面。只画有界轮廓，不把无限平面填成蓝色已观测地面。
- 地面参考候选：法向向上且倾角约 ≤12°，相机到平面法向高度 0.45–2.3 m；floor 面积至少 0.3 m²，未分类平面至少 0.7 m²。
- 优先 floor；否则选择较低的稳定未分类平面作为**待确认参考面**。已分类桌面等不作地面参考。
- 相同平面至少稳定 0.4 s；局部高度突变 >5 cm 或法向变化约 >3°重置。会话、追踪、参数、方向图像映射切换重置。
- build 7 增加独立地面状态：未初始化／确认中／floor参考／待确认水平面／短时参考／失效。短暂缺少合格原生平面快照时，参考最多保持2 s，位移≤1 m、法向位移≤0.35 m；不会用保持操作刷新截止时间。冲突、重分类为桌面或新平面重新确认时不保留旧实面。
- 短时参考只可配合**当前、已校准预测深度**显示几何，不能提供新的尺度拟合样本，不产生净空或通道。缺少当前尺度时只显示有限轮廓／现有≤1 s历史线框，不冻结为实心当前模型；已知尺度／地面冲突立即清掉历史。保留轮廓用橙色并标明状态。
- `ARFrame.anchors` 中平面快照时间**不是该表面刚被实际看见的时间**。平面可能包含历史估计，只能作参考，不能证明当前地面支持或净空。
- 初版未分类平面仍可能是桌面等。UI 不把它称为已确认地面；不由其授权任何通道。

## 相对深度的尺度校验

无固定持机高度常量，无 LiDAR 深度偷用，也不拿深度模型自身输出作为米制真值。

独立参考：
- ARKit `rawFeaturePoints` 的世界点，投影到对应输入帧，取得相机轴向深度与模型输出的配对。
- 稳定、被原生分类为 floor 的平面，在实际边界内做射线相交，生成辅助配对。没有地面分类时不从猜测平面生成尺度配对。

模型采用 `1/z = a × ((q - center)/spread) + b`，其中 q 为相对逆深度。RANSAC 加精修；并非直接 `z = q × 常数`。

初始门槛（全部是工程质量筛选，不是正确率概率）：
- 至少 16 个有效配对；至少 6 个 4×4 图像分区有支持。
- 参考深度 0.3–8 m；深度 P90−P10 >0.35 m；相对数值不可退化为常量。
- 正斜率；至少 65% 配对误差 <15%；拟合内点的中位相对残差 <8%。
- build 7：至少连续 3 次有效拟合；帧间隔 <0.5 s，位移 ≤0.75 m。用上一帧原生米制参考点的世界坐标投影到当前帧，在当前模型输出上检查米制残差，**不比较两帧相同 raw q**（模型逐帧归一化）。
- 旧参考必须是上一帧拟合的有效内点；同一目标像素只计一次。至少16个跨帧内点、覆盖4×4图像分区中的至少6区；至少65%的可评估参考相对误差 <20%，中位残差 <8%。
- 共享 ARKit feature ID 时，另外校验原生世界点漂移 ≤max(8 cm, 1.5%轴向距离)。旧日志没有 ID，可明确按世界点重投影分支回放，不补造 ID。
- 当前 q 范围外的像素保留未知；若其余充分分布的对应点通过检查，不因单个区间端点无法外推而全局归零。遮挡、真实尺度冲突或分布不足仍可拒绝整帧。
- 缺失当前拟合即撤销米制输出并重新确认，绝不复用旧系数；确认次数封顶3，追踪、会话、参数、方向映射障碍清空旧参考。
- 只保留拟合支持范围附近的深度（数值范围外扩最多10%），再限制到配置量程；其他像素无效。

尺度参考本身有误差，单平面可见性可能受遮挡影响，拟合误差不等于真实场景测距误差。需要卷尺实测，不能用这些门槛宣称已达到原 LiDAR 验收指标。

## 蓝红建模与未知保护

- 模型尺度与原生参考可用后，共用现有反投影、局部栅格及三角面构建，显示蓝色参考面附近和红色疑似突出物／阻挡柱。
- 未分类平面下的蓝色只是“参考面附近”，不是确认地面。
- `predictionSupport` 单独保存；它是应用几何筛选掩码，不是传感器置信度、网络正确率或观测真值。
- `VisibilityDepth` 显式拒绝用模型预测确认净空；`PredictedGeometry` 再次撤销所有候选格。
- 本版无 LiDAR 分支**不输出确定的左／中／右障碍距离，不生成候选通道**。这是校验版的明确边界；保留未知，待真正无 LiDAR 的误差和漏检评估后再设计推理质量政策。
- 未建立参考面时仍可以显示相对深度和原生平面轮廓，不要求先找到地面才显示 RGB。
- 不增加台阶／落差安全判定，不做无保护盲行测试。

## 性能与诊断

- 复用“一个执行中＋一个可替换最新待处理帧”的有界 worker；加载模型、预处理、推理、读取输出和尺度拟合都在后台。
- Core ML 使用 `.all` 让系统选计算单元；不声称所有设备均运行在 ANE。
- `modelLoad`、`modelPreprocess`、`coreMLPrediction`、`modelOutputRemap`、`nativePlane`、`scaleAlignment`、`modelDisplayBuffer`、`modelPipeline` 分开记录。
- 结果遵守当前源帧年龄、会话／参数代次和追踪门控；严重发热降频、临界暂停。冷加载可能使第一帧过期，不能发布过期几何。
- `prediction.jsonl`：模型及版本、相对深度附件、原生平面快照、尺度配对、拟合结果、状态、分阶段耗时。build 7 增加可选 featureID、provisionalFit、scaleDecision、groundReference、relativeCoverage；即使未通过最终确认也保留单帧拟合与具体拒绝原因。
- 保存的是完整相机视野的分析分辨率预测图，不是原始 518×392 网络张量；分辨率和映射方向明确写入日志。
- 经过尺度校验的分析深度仍写入 `analysis.jsonl`，明确来源为预测，附独立 `predictionSupport`，没有伪造 confidence。
- 模型、RGB、ARFrame 大对象不进入磁盘待写队列；该队列只捕获空间数据和值类型元数据。
- 不保存原始 RGB、视频、音频；不上传。模型推理只在本机内存中读取 RGB。
- 原有每次启动512 MiB、总计2 GiB额度继续有效，不自动删除。两类预测附件会增加写入量；以实测磁盘量和丢弃计数判断可记录时长。

```bash
python3 scripts/read_diag.py <DIAG目录> --verify-data
python3 scripts/read_diag.py <DIAG目录> --extract-prediction 1:123 --output <新导出目录>
python3 scripts/read_diag.py <DIAG目录> --extract-depth 1:123 --output <另一个新导出目录>
```

旧 `replay_diag.swift` 是测量深度回放器，会拒绝预测来源；不得改来源字符串使其冒充 LiDAR 数据。预测日志能够重建输入到几何的数值条件，但没有 RGB，不能重新执行神经网络推理。

## 必须实测的清单

1. LiDAR iPhone：关闭开关后旧分支正常；打开后配置事件中 sceneDepth／smoothed／mesh 均不启用。
2. 真正无 LiDAR iPhone：开关开启且不可关闭，世界追踪和可用的原生平面工作。
3. 横竖屏、完整画面边缘及冻结：预测热图与对应 RGB 一致，旋转不镜像、不卡住旧米制结果。
4. 初始化移动、静止、转向、遮挡、低纹理、弱光／室外：区分原生追踪失效、无平面、尺度未确认及模型错误。
5. 卷尺测量地面高度、障碍位置、突出物高度，至少三次重复；Apple 分类和 LiDAR 仅作对照，不作无误差真值。
6. 后台、停止、开关切换、追踪受限、热状态和配额：旧结果撤销，DIAG 可解释。
7. 至少30分钟连续运行与日志导出。模拟器和合成图推理不替代上述项目。

## build 7：连续性回放

本次不更换模型、不预加载模型、不修改初始化流程，也不改变 LiDAR 检测阈值或预测净空禁用政策。HUD 分开显示“相对输出”“米制预测”和“地面参考”；停止时撤销尺度成功文案，无LiDAR模式不再把不生成通道误写成方向不稳定。模型三角面构建耗时独立记录。

离线重放脚本只读取空间数据，不读RGB、不执行推理、不模拟新增传感器证据：

```bash
swift build --package-path Core --scratch-path build/CoreTests
BIN=$(swift build --package-path Core --scratch-path build/CoreTests --show-bin-path)
swiftc -parse-as-library -I "$BIN/Modules" "$BIN/SpatialCore.build/"*.swift.o scripts/replay_monocular.swift -o build/replay-monocular
build/replay-monocular /absolute/path/to/Diagnostics/run > build/scale-replay.json
```

脚本校验每个预测附件的长度与SHA256，使用原始相对深度、内参、位姿和尺度配对执行生产 `MetricScaleTracker`。回放指标是**算法确认可用性，不是测距正确率，也不是实际绘制帧率**。旧日志缺少feature ID的分支与新真机分支必须分别实测。

## build 8 预测线补充

已校验尺度、原生floor确认且连续蓝地面足迹满足条件时，可生成一条**实验几何预测线**及朝向触觉反馈。它不同于原有经过身体净空证明的候选通道；后者在模型分支仍不授权，未知栅格仍为未知。强振只代表朝向对准，不代表可安全行走。详见 PATH_PREDICTION.md。
