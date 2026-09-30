# 当前代码库审计 / build25

审计日期：2026-09-30（Asia/Shanghai）。基线：`main`，`2a2c7ffc5dd91547b13a637c52dd3e96b0e4b7c6`。

## 1. 范围与结论

本轮是结构整理、静态审计及现有测试复核，不改规划、语音、渲染或录制策略，不删除疑似未用代码。
开始时已有 `PRTS/InfoPlist.xcstrings`、`PRTS/Localizable.xcstrings` 两个本地改动；保留，未纳入本轮提交。
未发现适用于本仓库的 AGENTS.md；相邻 MiniCPM 项目规则不作用于本仓库。

- 现有模块边界合理，无需移动目录或再拆出一套并行架构。
- 当前产品是 **ObstacleWaypointPlanner 三态引导**，并非早期“空旷也一直画线”的连续路线策略。
- 有可清理的无调用入口，但必须区分兼容预留、离线对照与框架回调。
- 高优先级待处理：会话启动/停止的跨队列时序；已有 Dev 录制完成超时；日志枚举/导出与写入共用队列。
- 性能机会主要是重复数据整理、主线程网格上传、碰撞几何中重复投影。没有本轮 Instruments 数据，不声称已测得瓶颈或优化百分比。

## 2. 代码树与真实运行链

完整逐文件树及统计见 [CODE_INVENTORY](CODE_INVENTORY.md)，职责见 [CODE_STRUCTURE](CODE_STRUCTURE.md)。

```text
PRTS/App                         组合入口、产品规划策略
  ├─ UI + Capture               页面、权限、CameraManager / ProbeViewModel
  ├─ Spatial/Runtime            ProbeEngine 单一 ARSession、最新帧邮箱
  │    ├─ LiDAR                 sceneDepth + confidence + mesh floor priors
  │    └─ No-LiDAR               CoreMLDepthModel → MonocularDepthProvider → 尺度标定
  ├─ Vendor/SpatialCore          感知、确认障碍模型、规划与发布规则（纯 Swift）
  ├─ Spatial/Rendering           SharedSnapshot → Metal；不负责规划
  ├─ Feedback                    已发布状态 → 语音 / 触觉
  ├─ Spatial/Diagnostics         自动指标、原始深度及网格附件、手动样本
  ├─ Spatial/DevCapture          PRTS_DEV_CAPTURE：手动低帧率 RGB + 同源证据
  └─ PhotoDescription            按键 → 拍照/识音 → 云端回答 → 独立朗读
Vendor/PRTSCore/PRTSContracts     工程实际链接的兼容契约
Vendor/PRTSCore/PRTSAppleModels*  可选完整/Lite模型层；不是当前 App 运行链
Experiments/SpatialProbe         历史验证工程；不作为主程序源码重复统计
```

主链符号：
`ProbeEngine.session(_:didUpdate:)` → `LatestMailbox` → `drainAnalysis()` →
`SpatialAnalyzer.analyze` / `PredictedGeometry.analyze` → `PathPredictor.update` →
`TemporalOccupancyGrid.apply` → `ObstacleWaypointPlanner.update` →
`RoutePublicationPolicy.decide` → `SharedStore` → `SharedSnapshot.activePath/activeWaypointUpdate` →
`ProbeRenderer.draw` / `FeedbackCoordinator.consumeDirection` / `PathHaptics.tick`。

`RouteEvidenceMap`、`ForwardRoutePlanner` 仍供 verified/legacy 分支和回放对照使用；
`GreedyDetourSearch`、`ForwardPathSearch`、`FanPathSearch` 由当前绕行复用。不能整批当作旧代码删除。
`SceneSnapshotAdapter.measuredResult` 仍由 `CameraManager.poll` 调用，并供应反馈 fallback，也不是悬空模块。

## 3. 问题清单（代码确认 ≠ 真机复现）

### A1 / P1 — 启停请求缺少同一请求代次的取消屏障

**位置：** `PRTS/Spatial/Runtime/ProbeEngine.swift`：`start(device:)`、`stop(reason:)`。

**代码确认：** start 把启动闭包排入 sessionQueue；stop 在调用线程立即设 `running=false`，但排入 sessionQueue 的闭包只 pause/reset/finish，不再次收敛运行状态；start 没有取消令牌。

**可导致问题的调度：** start 入队但尚未执行 → stop 清空状态并排入 pause → 旧 start 执行，写 `running=true` 并 run → pause 执行，状态仍可能为 running。权限完成后快速退后台是需要验证的场景。NSLock 保护单次读写，不能消除这个逻辑竞态。

**状态：** 已核实代码存在该调度路径，未通过可控队列或真机复现；不认定它是之前路线抖动的根因。

**建议：** 保留 stop 的立即撤销显示，添加启停请求代次；待启动闭包执行前核验请求代次/期望运行状态。所有 sessionQueue 尾部状态操作也核验所属请求，防止旧 pause 清掉新 start。先测试 start→stop、start→stop→start、后台权限回调，再实现。

### A2 / P2 — 诊断读操作可能阻塞同队列写入

**位置：** `Vendor/SpatialCore/Sources/SpatialCore/DiagnosticJournal.swift`：`listRuns`、`export`、`size`。

**代码确认：** 最近30个目录的递归大小统计及整个目录复制都在日志串行队列中执行。采集仍在工作时，写入可能等待且有界队列可能丢记录；export 仅停止 Dev recorder，不等于停止 ARSession/自动 DIAG。

**建议：** 列表用已完成会话的大小索引，后台重算；导出先在写队列确定一致的文件/分段边界，再交给独立 I/O 队列。不能直接复制仍在追加的附件而宣称是完整快照。增加并发导出时的配对完整性和丢弃计数测试。

### A3 / P2 — Dev 录制结束路径与已知测试超时需单独排查

**位置：** `PRTS/Spatial/DevCapture/DevCaptureRecorder.swift`：`append`、`finish`、`stop`；`PRTSTests/DevCaptureTests.swift`：`waitIdle`、`stop`。

**代码确认：** AVAssetWriter.finishWriting 的完成回调决定 busy/finalizing 清除和 stop completion；测试 stop 的 continuation 本身没有超时。不能仅通过增加 waitIdle 的10秒期限修复。

**既有证据：** build25报告记录过 `uncalibratedModelOutputIsSavedWithoutInventedMetricDepth` 超时；本轮未重新运行该模拟器测试，根因尚未确定。不要把超时直接断言为死锁或手机录制失败。

**建议：** 分别记录预处理、附件压缩、视频append和finish耗时；注入 writer/clock，测试重复 stop、编码失败、epoch变化、后台截止及 completion 恰好一次。设备集成测试与确定性状态机测试分开。

### A4 / P2 — 每帧新网格版本可导致显示缓存反复清空

**位置：** `PRTS/Spatial/Rendering/ProbeRenderer.swift`：`updateMeshBuffers`。

**代码确认：** 一次 draw 会移除所有 revision 不匹配的旧 GPU buffer，但只上传一个 anchor，并优先最新 callbackTime。持续有更多更新时，未轮到上传的 anchor 暂时没有 buffer；主线程还负责面循环和数组生成。

**判断：** 可解释“网格层短时缺块”的候选机制，未证明是路线抖动原因。网格显示与路径数据源不同。

**建议：** 按 anchor 合并最新待上传版本、加入公平预算，后台生成顶点，GPU资源更新后原子替换；anchor删除/epoch变化仍立即处理。若保留旧版本供显示，明确记录显示版本和年龄，不让显示缓存回流到感知。

### A5 / P3 — 库存统计与注释落后于实际产品

**代码确认：** 原库存脚本完全漏列 `Vendor/PRTSCore`；Xcode 工程实际链接 `PRTSContracts`。旧 CODE_STRUCTURE 把它写成仅可选契约，也把历史预测虚线叙述成当前产品链。`CoreMLDepthModel` 的注释指向主项目不存在的 `scripts/smoke_coreml.swift`。

**本轮处理：** 补充契约、可选模型、契约测试树；统计按源码类别而非宣称全部编入App；修正架构入口说明。模型注释问题列入后续小型注释清理，未改运行文件。

## 4. 悬空方法核查

方法：扫描声明名在 App 与 SpatialCore 主源码中的引用，再交叉核查测试、协议及回调。不是 Swift 编译器级全程序可达性证明；同名方法、条件编译、扩展和动态回调均会影响结果。

| 符号/位置 | 核查结果 | 处理建议 |
|---|---|---|
| `ProbeEngine.freeze()` | 当前 App 未发现调用入口；frozen 消费逻辑仍在 | 核对是否要恢复开发工具按钮；否则成组删除，不只删入口 |
| `FeedbackCoordinator.suspendResultFeedback()` | 当前 App 未发现调用 | 可列入小型清理提交，保留缺帧时不重置方向latch的现有行为 |
| `HapticManager.obstacleWarning`、`candidateObserved` | 当前 App 未发现调用；方向触觉由 PathHaptics负责 | 可删除的高置信候选，不删除整个 HapticManager |
| `SpeechManager.localizedInterfaceString` | 当前 App 未发现调用 | 可单独移除薄包装，回归设置语言 |
| `SpeechManager.enqueueBackendSpeech`、`cancelBackendSpeech` | 当前 App 未发现外部调用；内部队列/expiry/delegate仍互相关联 | 兼容后端预留簇；如移除必须连同字段与delegate分支审查 |
| `SceneRGBFrameProviding.rgbFrame` | 只有协议要求，未找到产品实现/调用 | 明确标为未来检测器接口，暂保留 |
| `UnavailableObstacleDetector.detect` | 兼容预留，有App测试 | 非当前模型检测器；不能把测试通过当作已接入检测模型 |
| `NativeGroundTracker.select` | 核心库测试使用的兼容入口 | 保留，或显式弃用迁移；不按主App引用量删除 |
| `ImageOrientation.imageUV` | 坐标往返与单目测试使用的公开方法 | 保留 |
| UIViewRepresentable、MTKViewDelegate、ARSessionDelegate、URLSessionTaskDelegate方法 | 框架调用 | 不是死代码 |
| `ForwardRoutePlanner` / `RouteEvidenceMap` / `RouteProjection` | 历史对照、测试及条件路径 | 标明非默认分支，不无依据裁剪 |

`FeedbackCoordinator.consume(...haptics:)` 参数在当前方法体中没有使用；这是接口残留，不代表触觉功能整体未接入。
本轮没有删除上述任何符号，避免审计变成无回归的行为变更。

## 5. 可优化部分与等价性要求

| 优先级 | 位置与事实 | 可实施优化 | 验证门槛 |
|---|---|---|---|
| P2 | `ProbeEngine.session(didUpdate:)` 每个分析提交都排序、展开全部 floorPriors | 在网格集合版本变化时缓存不可变先验数组，仍保存原 callbackTime/revision | 同帧输入、先验顺序与数值一致；删除、逐出、reset失效正确 |
| P2 | `DevCaptureRecorder.submit(frame:...)` 先整理planes/features/mesh列表，再在submit(packet)做5Hz/busy准入 | 先原子预留采样槽，获准后才整理packet | stop不能越过已接受样本；失败释放槽；同输入保持采样帧ID和时间门限 |
| P2 | `OccupancyFootprint.stamp` 对每个目标格/轴重复 corners.map及min/max | 每个footprint预计算每轴投影区间 | 原epsilon/浮点运算顺序保持；旋转、贴边、零面积重叠测试 |
| P3 | `CoreMLDepthModel.prepareInput` 每次分配输入buffer | 固定尺寸CVPixelBufferPool，串行worker复用 | 图像四方向、letterbox、像素/推理误差对照；不能修改尺度标定 |
| P3 | `ProbeRenderer.updateMeshBuffers` 仅选一个mesh却全量排序 | 单遍选择待处理anchor并定义同时间戳tie-break | 对原先无确定顺序的tie需先确立契约，不宣称逐帧完全等价 |
| P3 | `ProbeViewModel.poll` 多个Published属性每tick重新赋值 | 先比较标量展示字段，降低无变化状态的UI更新 | 不能跳过实时位姿/反馈tick；用Instruments测主线程与重绘 |
| P3 | `FanPathSearch.plan` 与绕行分支可能重复搜索/简化 | 先计每次规划搜索次数、节点扩展与segment检查次数，再考虑局部缓存 | 固定地图版本/width/policy；同分数tie和绕行侧保持；不先换搜索器 |

前3项有较明确的消除重复计算方向，但“输出等价”仍需对应回归证明。缓存必须基于正确版本，而不是通过延长TTL隐藏变化。
避免本轮直接优化：修改300ms确认、缩短语音间隔、改变绕行评分、删状态门控。这些是产品语义变化，不是性能整理。

## 6. 测试与检查结果

本轮实际执行：

```sh
swift test --package-path Vendor/SpatialCore -j 2
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore -j 2
python3 -m unittest discover -s scripts -p 'test_*.py'
python3 scripts/code_inventory.py --write
```

- SpatialCore Debug：326通过，0失败。包默认对Debug核心启用 `-O`，不是未优化调试回归。
- PRTSContracts：8通过，0失败。
- Python：修改前47通过；修改库存脚本及新增测试后48通过，0失败。
- 新库存测试覆盖：实际契约、可选模型、契约测试分类；构建目录剪枝与符号链接排除。
- 原库存使用rglob后置过滤，仍遍历构建子树；现改为限定源码根目录 + os.walk预剪枝，不读取被排除树或符号链接。
- 未在本轮重跑App/UI测试、Release核心测试、TSan、真实云服务、传感器/热负载实测。前轮结果不混算为本轮通过。
- 本地日志：`/tmp/prts-audit-20260930/{core,contracts,python,python-final}.log`；临时目录不是永久CI归档。

## 7. 建议实施顺序

1. 独立提交会话请求代次修复及可控队列回归；不碰规划算法。
2. 录制writer边界测试与阶段耗时，确认既有超时的实际停滞位置。
3. 单独做floorPriors缓存和Dev准入前移；同一输入帧对照，再跑设备持续采集。
4. 单独做几何投影缓存；回放比较每条路线、确认障碍集和目标点，不只比路线数量。
5. 在主线程实测证明需要后做网格顶点后台构建与原子上传。
6. 对无调用入口做小型删除提交；公开库、协议、历史回放分支先标明用途/弃用策略。

本轮交付仅脚本、测试、代码树及报告；App源文件、工程配置、build号及既有本地本地化改动保持不变。未把静态扫描或核心测试称为真机算法验收。
