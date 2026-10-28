# 坐标、几何与运行架构

## 1. 模块

|模块|责任|
|---|---|
|`App/ProbeEngine.swift`|唯一 ARSession、权限以外的传感器生命周期、能力检测、帧／网格有界调度|
|`App/Snapshots.swift`|同帧元数据及 CVPixelBuffer 保留、按行拷贝、网格索引读取、共享状态锁|
|`App/ProbeRenderer.swift`、`ProbeShaders.metal.txt`|统一 aspect-fit 渲染、YCbCr 转换、分类／栅格投影、GPU 完成时释放纹理|
|`App/ProbeApp.swift`、`ProbeContentView.swift`、`ProbeSettingsView.swift`|主线程 UI、相机授权、设置、后台撤销、文件导出|
|`Core/Sources/SpatialCore`|无 ARKit 依赖的几何、地面、三态栅格、通道、方向门控、有界 mailbox|
|`App/SessionRecorder.swift`|串行磁盘写入、配额、手动样本、会话快照导出|

## 2. 坐标链

- 原始 RGB／depth 坐标：u 向右、v 向下，使用原始采集方向，不先转成竖屏像素。
- ARKit 相机坐标：x 右、y 上、前向 **−z**。深度 d 是轴向深度，不是斜距。
- 代码以整数索引表示像素中心。分辨率变化 `sx=depthWidth/rgbWidth`、`sy=depthHeight/rgbHeight`：
  `fx'=sx*fx`，`fy'=sy*fy`，`cx'=sx*(cx+0.5)-0.5`，`cy'=sy*(cy+0.5)-0.5`。
- 反投影：`p_camera = ((u-cx')*d/fx', -(v-cy')*d/fy', -d)`。
- `p_world = cameraTransform * [p_camera,1]`；世界坐标采用 `.gravity`，+y 为上。
- 地面平面 `n·p+b=0`，n 朝上；参考原点是相机在平面上的正交投影。
- 将相机 −z 在平面上投影、归一化为前向 f；横向 r 与 n、f 正交。局部点 `p=origin+x*r+h*n+z*f`。
- 局部栅格 z 表示沿参考前向，不是屏幕纵坐标；存储顺序为近到远的行、左到右的列。

像素中心约定及内参缩放已有往返测试，但**不把合成往返一致当作 ARKit 实测对齐证明**。M1 必须检查实际目标的全画面边界差异并保存样本；不得通过随意偏移热图“调好看”来隐藏传感器差异。

### 完整视野显示

根据窗口实际 `UIInterfaceOrientation` 决定旋转后图像宽高；先建立与它等比例的虚拟 viewport，再取 `ARFrame.displayTransform(for:viewportSize:)`。这样避免把 aspect-fill 变换直接用于宽高比不同的整屏。最外层再按 FitRect 映射到 drawable，保留黑边。RGB 和 depth 采样共用 raw UV；世界顶点先相机投影，再用同一显示变换。置信度使用 nearest，不混合类别。停止后不绘制旧帧；冻结帧有独立非实时标记。

RGB 根据 CoreVideo 色彩矩阵附件处理 BT.601/709 和 full/video range。网格、栅格为**诊断叠加**，没有用实时深度实现真实世界遮挡；不是逼真的遮挡渲染。网格内部使用深度测试，地面候选层不以遮挡真实感为目标。

## 3. 首版几何

### 深度与平面

肯定性证据只接受：Float32、finite、0.15–5m、高置信度2。置信度缺失或等级低不会被当成空闲。分析永远读取原始 sceneDepth，显示可单独选择平滑版本。

RANSAC 使用固定种子，最多96个深度三点假设，并加入部分 floor 面先验。法向与重力夹角≤12°、相机在平面上方0.45–2.3m。候选面需当前深度支持，经三次内点最小二乘精修；默认内点阈值3cm、至少40点、25cm支持格估计面积≥0.3m²。该面积是分布检查，不是可通行填充面积。

floor 先验只有在法向一致、面高差<7cm、先验中心附近35cm内有当前深度内点时才确认；无先验的水平面只显示为未确认参考。连续至少3次一致平面才允许候选格、沿地面距离和通道输出。优先使用先验并不代表 ARKit floor 分类可靠：误分类仍可能导致错误，必须独立评测。

### 地面支持、障碍、净空

范围 x∈[−1.5,1.5)m、z∈[0,4)m，10cm平面格；初始全部未知。

- 地面格：至少3个直接地面样本，分布在格内至少2个象限，平面分类确认。平面本身不生成支持，格之间不补洞。
- 非地面占用：参考地面上方超过3cm且在人体高度范围内的点；3个以上记障碍，1–2个保持疑似／未知，不因去噪变空闲。
- 身体净空：从距地面6cm到配置身高，以10cm高度分层；所有体积都需有效深度可见性。地面上方0–6cm区域的可靠微小障碍检出**不在保证范围**，是本版限制。
- 体积8角投影须在视野内。先用含无效值的最小深度金字塔尝试保守快速认证；必要时按每个深度像素的整个像素足迹构造射线方向区间，对正交体积的三个 slab 求潜在交点深度上界。观测深度必须超过该上界及5cm余量。方向区间只会扩大需检查的区域，不缩小。
- 深度孔洞、低置信度、越界、遮挡、落在体积前的表面都会阻止认证。不能用“没检测到点”代替净空。
- 有限像素与网格依然无法证明连续真实体积绝对为空，尤其薄杆、细绳、透明表面和低反射物体。该算法是可解释的实验候选证据，不是安全保证。

只在地面直接支持和全高度净空都满足时标候选。按人体半宽＋单侧余量计算圆足迹；足迹覆盖障碍、未知或窗口外任一格均不通过。采用圆与单元方块相交关系，而不是仅比较中心距离，以免斜向欠膨胀。

### 距离和通道

- 热图：相机轴向深度，米。
- 三维距离：相机到三维点的 Euclidean distance（用于算法范围检查，非左／中／右主读数）。
- 主障碍距离：相机地面投影到可信障碍簇占用格中心在地面上的距离。4邻接聚类，区域内至少6个支持样本，取10%分位前缘；日志包含样本数、支持格数和10–90%分位差。10cm格量化误差单独计入实测，非最近像素深度。
- 通道长度：候选中心线累计长度；宽度是路径各行连续候选带宽的最小值，**不是已测得的真实墙面间净宽**。卷尺必须在对应截面比较，斜向边界有量化误差。
- 左中右按相对前向角度±15°划分。每扇区从最近可认证行开始前向搜索；不跨未知行，不在断裂后重新接到更远区域，对角转移要求两侧角格也可用。优先最远连续行、较宽带、较小偏离。
- 起点允许在近身盲区之后，但明确显示距相机投影的起点距离；不画从脚下跨未知到起点的线，不宣称从人当前位置就能安全进入该段。

## 4. 时间、方向与生命周期

- 使用相机前向在地面的投影，假设胸前朝前持机，未估计人体朝向。
- 分离几何与通道门控：正常追踪的移动帧继续计算、发布蓝／红表面和红色阻挡柱；世界坐标顶点使用显示帧姿态重新投影，不保留旧屏幕图层。
- 全旋转角速度含 roll，默认30°/s；稳定至少0.5秒。该条件只门控候选通道及左／中／右方向距离；不再要求手机静止才建模。通道要求分析源帧和最新帧均稳定，且源帧晚于最近一次方向失效。
- 前向地面投影长度<0.5仍撤销方向通道，但不再阻断表面建模。几何使用地面切向基；接近完全竖直时使用上一次世界前向或确定性世界切向，不把它当作人体方向。追踪非normal、临界热状态或生命周期屏障仍撤销当前几何及历史线框。
- `ResultPresentationGate` 供发布／绘制／UI／日志共用。结果最大250ms，源帧不得晚于显示帧，必须匹配当前 epoch、参数版本、递增 frameID；绘制时再次检查，旧屏幕折线从不复用。追踪／冻结／临界热状态失效设最小几何帧屏障，方向失效另设最小通道帧屏障，迟到结果不能重新开启失效前的输出。
- 本版**不跨帧累积占用／空闲格**；每次格证据来自当前原始深度，严格于计划中的1s地面／0.5s净空缓存。只允许地面一致性、受限时效的世界地面参考、短暂历史线框以及mesh结构先验跨帧保留。
- mesh 的 callbackTime 是回调接收时间，不是三角面的观测时间。来源 ID/revision/time 可追溯。旧 mesh 只能支持结构先验，当前净空必须重新取证。
- 停止、离开前台、会话中断／失败、重定位立即清空；恢复需明确点击开始，新 epoch 和重置世界追踪，不拼接旧世界坐标。
- 方向和追踪门控变化写事件；停止后迟到的分析不得发布、不得继续写该会话记录。日志结束会使有效写入 epoch 失效。
- 无 sceneDepth 独立硬件时间戳；HUD 的帧年龄、分析显示帧差、mesh 回调年龄有明确含义，**不标成 RGB/LiDAR 物理同步误差**。

## 5. 并发与性能

AR 回调串行队列仅保留同帧对象／少量元数据并投递。分析队列：一个正在处理＋一个可替换待处理帧；没有逐帧无界 Task。深度／地面／通道在后台。网格更新按 anchor 合并，待处理最多32，缓存最多64个或32MiB，过载删除证据并计数；不每帧全量复制整个场景网格。

Metal shader 源码后台编译一次。渲染最多2个 in-flight command buffer，GPU完成前保留 CVMetalTexture 和源帧。渲染每帧至多上传一个变更 anchor，显示每 anchor 约6000面抽样；上传／overlay vertex构建仍在绘制线程，须用实测CPU时间检查预算，不宣称全部渲染准备已后台化。

记录队列最多8项＋其中一个手动样本；满则丢记录并计数。会话512MiB配额包括指标和已保存样本（采样前保守估算、后计实际量）；磁盘错误可见但不阻塞采集。导出为串行队列中的一致快照复制，过程中可能导致记录丢弃；**精度/性能测试结束后先停止再导出**。多会话／导出副本总磁盘量需人工管理，没有自动删除证据。

计时：回调打包不是硬件采集时间；depthCopy、depth、groundGrid、mesh、channel、CPU draw提交、GPU、可获得的drawable呈现年龄、源结果年龄。serious 热状态分析≤5Hz；critical暂停几何并撤销输出。显示目标30FPS、分析10Hz、P95年龄≤250ms、30分钟持续性能均须真机实测，未保证。

## 6. API核实依据与边界

本机 iPhoneOS26.5.sdk 的 ARFrame.h、ARDepthData.h、ARCamera.h、ARConfiguration.h、ARMeshGeometry.h、ARSession.h；Apple 官方示例：

- `https://developer.apple.com/documentation/arkit/displaying-a-point-cloud-using-scene-depth`
- `https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene`
- `https://developer.apple.com/documentation/metal/mtldevice/makelibrary(source:options:)`

运行时分别探测 worldTracking、sceneDepth、meshWithClassification、sceneDepth＋smoothedSceneDepth组合。读取 mesh 顶点 offset／stride，分类按三角面、indices按2/4字节解析；每帧置信度允许缺失。模拟器强制不支持传感器，不喂合成数据伪装能力通过。

## 7. 限制与下一步

单局部平面不能可靠表达台阶／坡面切换；没有落差安全检测。玻璃、反光、光照变化、薄目标、过低障碍、ARKit分类误差、RGB／深度边界差异、手机与身体朝向分离都可能失败。当前帧保守全高度检查会产生大量未知或无候选，这必须记录而不是放松阈值美化。

先通过 M1，再做网格对齐和测量验证；根据真实失败样本决定是否引入可靠多帧带时效证据、独立人体前向估计、局部多平面／落差研究及语义模型。任何后续模型都不能直接把未知抹成安全区域。


## 7. build 3 自动DIAG

应用启动级 `DiagnosticJournal` 独立于ARSession与旧SessionRecorder。自动记录原始数值深度／置信度及网格更新，不保存RGB；空间数据无损压缩且有校验、限频、有界队列和磁盘配额。相机未启动、权限拒绝、后台／热暂停均有事件及状态记录。详见 `Docs/DIAGNOSTICS.md`。地面与输出门控只增加结构化诊断，未放宽判断条件。


## 8. build 4：地面参考与当前证据分离

ARKit的世界追踪本来就在使用视觉惯性里程计（VIO）；没有新增独立IMU积分或“惯性导航”。相机位姿始终来自当前ARFrame。看不到地面≠追踪失效，定位正常也≠深度/净空可靠。

- 初次地面仍需floor先验与连续3帧深度确认。未确认的桌面不能建立参考。
- 地面暂时丢失时保留**最后确认的世界平面**，最长2秒，相对确认时相机平移最多1米、法向位移最多0.35米；复用不刷新时间。新确认floor与旧平面相差>12cm或法向>8°则撤销。用于通道的当前平面仍需原来的3帧、4cm/3°一致性条件。
- 参考保留期间蓝/红实体表面和阻挡柱仍只由**当前高置信度深度**建立。无当前地面支持的格不补蓝；没有当前地面确认时全部候选格降为未知，方向距离/候选段为空。
- 深度或当前模型暂时不足时，最多保留一个模型，最长1秒且相机平移<=0.75米；以低透明度**历史线框**重投影到当前相机。历史模式不显示旧阻挡柱、旧栅格、旧方向距离或旧通道；当前有效空模型/地面矛盾会清掉历史。
- 250ms新结果寿命不变，历史有独立入口和明确UI标签（关闭HUD也显示）。最新相机帧仍必须及时且normal；没有新的位姿时，不以历史超时参数延长定位有效期。
- 停止、冻结、切后台、追踪受限、重定位、参数变化、critical热状态清空显示历史。分析线程同步捕获侧失效屏障，避免一次未被10Hz分析采中的短暂追踪异常留下旧地面参考。

实现：GroundReferenceTracker、GroundBasis.geometry、SurfaceHistory以及独立activeSurfacePresentation。所有参考来源帧/时间和渲染历史模式进入DIAG，不保存RGB。


## 9. build 5：有数据依据的微调

地面连续确认改为比较同一物理位置（当前相机位置）的平面有符号距离差：abs(oldPlane.height(camera)-newPlane.height(camera))<4cm，法向<3°、连续3次不变。不能用abs(old.offset-new.offset)替代：世界原点平移会改变这一系数差，即使手机附近测得的平面几乎相同。

表面三角面预算从12,000改为24,576，256×192深度的步长2可生成最多24,130面，不再被预算迫使退为步长3。仅影响蓝/红测量表面的细节；栅格采样步长、置信度/高度/净空/障碍膨胀及通道要求不变，不填补低置信度或遮挡孔洞。仍有明确面数上限。

DIAG改用完整二进制网格，减少大量坐标/索引逐数值JSON编码；增加事件字节预算保留而不扩大总队列。真机记录的分析队列没有丢帧，过载主要出现在DIAG持久化队列，两者分别统计。

本轮不增加处理频率、不延长2秒地面参考/1秒历史线框，不降低置信度和净空条件。台阶检测/深度模型属于下一阶段建议，详见Docs/STEP_DETECTION_PROPOSAL.md，并未实现。


## Build 6 双数据源

DepthBackendPolicy按sceneDepth能力与用户开关决定分支。ProbeEngine切换来源时重建会话。CoreMLDepthModel可独立运行预处理和推理；MonocularDepthProvider负责同帧原生平面／稀疏点、尺度拟合和质量筛选。PredictedGeometry独立于测量深度的SpatialAnalyzer，不授权候选区域。置信度与predictionSupport分离；VisibilityDepth禁止预测数据确认净空。具体坐标映射、原生平面边界、阈值和日志来源见NO_LIDAR.md。

### build 7：预测连续性

`MetricScaleTracker` 在核心包内，输入两帧独立原生参考、模型相对图、内参及位姿；比较同一世界参考重投影后的米制残差，而非相同归一化数值。三次确认、当前帧独立拟合、时间/空间/会话障碍均保留。共享原生point ID可额外否决地图漂移。真实冲突撤销历史线框，缺少证据不复用旧标定。

`NativeGroundTracker.update` 显式返回短时结构参考状态，不与当前模型尺度绑定；保留参考不生成拟合样本或可通行证据。`ResultPresentationGate` 按展示时钟限制原生参考最长2s。蓝红预测建模阈值及 LiDAR 分支不变。初始化/模型冷加载策略不改动。

## build 8: separate path prediction

`PathPredictor` (serial analysisQueue) consumes current blue SurfaceModel + obstacle grid/depth and publishes one world polyline into SharedStore, independent of the strict `CandidateSegment` clearance channel. `PathPresentation.make` shares lifecycle/epoch/fresh-live-frame barriers and bounds historical display separately from current sensor-result age. `PathHapticPolicy` is deterministic SpatialCore logic; main-actor `PathHaptics` adapts it to Core Haptics, using current pose rather than analysis-frame heading. See PATH_PREDICTION.md. No predicted line changes LocalGrid candidate states.
