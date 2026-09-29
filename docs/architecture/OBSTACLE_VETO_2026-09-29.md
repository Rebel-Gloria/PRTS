# Build17：obstacle-veto 与滚动路线缓存

## 范围与入口

基线 `26ed8cc`（main/build16），开始时工作区干净。本轮不移动目录、不新增包、
不替换 ARKit/DA 链路或现有搜索器。产品规划按项目定义采用 obstacle-veto：
**只有当前时序障碍模型确认的占用禁止通过，其余栅格全部允许搜索。**

`PRTSRuntimeProfile.routePlanningPolicy = .obstacleVeto`，普通/Dev 构建一致。
`PathPredictor()` 同样默认此策略；`.verified` 仅供显式离线对照。录像开关不选策略。

## 删除或降为诊断的 gating

| 环节 / 实际符号 | build17 行为 |
|---|---|
| `TemporalOccupancyGrid.apply` | 原始 unknown、groundSamples、净空分类不限制私有规划栅格；非确认障碍全部 candidate |
| `PathPredictor.occupancyUpdate` | 不要求 `RouteEvidenceMap.prefix`、证据前沿或正向 free-space certification |
| 地面 / `ForwardRoutePlanner.update` | 地面未确认、短暂丢失、地面参考 TTL 或拟合变化不清路线 |
| `ForwardRoutePlanner.held` | 世界固定路线不受 retentionSeconds 截断 |
| `RoutePublicationPolicy.decide` | veto 候选不因处理年龄或证据年龄拒绝；新候选未完成保留现有路线 |
| `PathPresentation.make` / `RouteEvidencePresentation.validPrefix` | 不因证据 TTL、局部终点到达、目标角度或未验证近身连接隐藏主路线 |
| `ProbeEngine.enqueueMeshes` | 网格更新丢弃可以撤传感器图层，不撤 veto 主路线 |
| `PathDrawing` / `ProbeRenderer` | 主线与近身连接为黄色实线；历史证据虚线不影响主线；地面网格不遮掉线 |
| 参数宽度 | 路线用配置总宽（默认 0.50 m），不再与身体宽度＋余量取大值 |
| `remainingVerifiedLength` / evidenceAge | 仅诊断；veto 的 verified length 为 0，另记实际 plannedLength |

原始 `AnalysisResult`、深度、地面、身体净空分类仍按原算法记录，未伪造测量值。
共享 `RoutePlanningGrid` / `PathClearance` 的 candidate 检查接收的是适配后的栅格，
不会重新把原始 unknown 引入主路线限制。严格对照策略的测试保留并显式选择 `.verified`。

保留的是坐标与生命周期一致性：停止/冻结、tracking 失效、epoch/reset、参数版本、
乱序、未来时间戳、已撤销候选的障碍水位。展示仍需最新有效 AR 相机位姿；这与地面或路线证据 TTL 分开。

## 连续路线和障碍策略

1. `PathOptions.forwardBufferLength` 默认 **8 m**，Dev 设置可调 **2–20 m**；这是滚动计算窗口。
2. `RouteProgressWindow` 在上次弧长附近裁剪走过的部分，保留世界前缀、路线 ID 与既定绕行侧。
3. `ForwardRoutePlanner` 在窗口随人前移时贪心补尾，不等抵达局部目标。
   追加长度常规超过 0.30 m 就提交，接近续接预算时降为 0.15 m；旧前缀不移动。
   原有速度/预算续接启发式继续生效，预算值仍是初始配置，不是实测 P95。
4. 同一串行 worker 计算完整候选，`RoutePublicationPolicy` 一次提交几何及元数据。
   普通迟到/未完成候选不先清空旧线；障碍冲突先提高 watermark，再搜索，旧候选不能恢复被否决路线。
5. 障碍固定世界锚点确认 **300 ms**，关联间隔容许 **750 ms**，空间匹配半径 0.16 m。
   改用 0.10 m 键避免相邻 10 cm 格合并导致障碍宽度缩小。当前检测消失立即退出输入，不等待 free 确认。
6. 确认世界锚点投到保留路线方向的栅格；手机 yaw 不再使绕行栅格随相机旋转。
7. 保留直线贪心、快速贪心绕行、原 Dijkstra 兜底。可用绕行保持；原侧被堵、同侧修复失败时
   再比较左右方案，避免卡在旧侧。障碍消失后可立即回归原直线。
8. 原有偏转 45° / 连续 3 s 的前向重选继续使用；方向语音/振动消费同一提交状态。

绘图参考优先首次可用平面、栅格参考或 floor prior。都不存在时使用初始相机下方 **1.4 m**
的水平面，之后固定，避免路径随持机高度和地面拟合抖动。该高度只决定绘制，不阻断规划。

## 日志与旧格式

- 路线 prediction/publication/context schema **3**；`planningPolicy=obstacle_veto_v1`。
- context 增加可选 `plannedLength`，状态增加 `planned`；render 增加 `routeDisplayedPlannedLength`。
- `referenceSource`、`forwardBufferLength`、`maximumAssociationGap` 写入 filter 诊断。
- 旧 JSON 可缺少这些可选字段；旧 PathOptions 缺失缓存长度时取 8 m。
- 维持 frame / epoch / parameter / route / geometry / map / watermark 标识，DIAG 原始数据格式不变。
- 原字段 `blueCells` 是搜索器输入 candidate 数；veto 模式不能解释为测得的蓝色地面面积。

## 可复现验证

本地证据目录 `/tmp/prts-occupancy17/`；原始录制和视频不加入 Git。

| 检查 | 结果 |
|---|---|
| 基线核心 / Python | 270 / 46 通过，无基线失败 |
| 修改前新增回归 | unknown 无发布上下文、尾部不续接两项失败；被堵绕行侧另有失败复现 |
| 核心 Debug / Release | 各 285 项通过（新增 15 项） |
| PRTSCore contracts-only | 8 项通过 |
| Python | 46 项通过 |
| iOS 普通 Release（未签名） | 编译通过 |
| Dev Debug 模拟器 App 测试 | 14 项通过 |
| 签名 / 设备安装 | 见下方交付记录 |

新增测试覆盖：全 unknown 151 帧、2 m/s 连续走 30 m 的滚动路线；尾部提前续接；
没有初始地面/栅格；证据和结果 TTL 不撤线；固定世界高度；原子保留与乱序；
确认障碍抢占、全占用封闭、绕行、被堵绕行侧重选、消失后在 unknown 上恢复；
210 ms 节奏、epoch/停止隔离、宽度与身体证据分离、旧 JSON 兼容。
这是确定性合成输入，未模拟真实步态。

```sh
swift test --package-path Vendor/SpatialCore
swift test -c release --package-path Vendor/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath /tmp/prts-occupancy17/normal \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -derivedDataPath /tmp/prts-occupancy17/simulator -xcconfig configs/DevCapture.xcconfig \
  CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
```

### 旧记录只读回放

使用与上一轮相同的 `2026-09-29-latest-2041/compact-epoch4-input.jsonl`，
110 个真实处理时间戳（约 10.90 s），不补帧。build16 对照 **0/110** 输出主路线；
本轮 **110/110**。初版修改为 105/110，末尾旧绕行侧被新占用阻断且未切换；修复后消除该回放空窗。
这些是规划器输出计数，**不是设备屏幕显示率**。输入是 compact 栅格重建，缺少原始逐格
样本与同步完整传感器输入，不能据此评估实时功耗或几何精度。

```sh
swiftc -O -I Vendor/SpatialCore/.build/arm64-apple-macosx/debug/Modules \
  scripts/replay_route_snapshots.swift \
  Vendor/SpatialCore/.build/arm64-apple-macosx/debug/SpatialCore.build/*.swift.o \
  -o /tmp/prts-occupancy17/replay
/tmp/prts-occupancy17/replay /absolute/path/compact-epoch4-input.jsonl
/tmp/prts-occupancy17/replay /absolute/path/compact-epoch4-input.jsonl --verified
```

## 剩余算法与体验项

- 无初始平面时 1.4 m 绘图高度可能与实际地面不齐，后续可单独改善高度校准，不作为规划门槛。
- 栅格量化、障碍临界进出仍可能引起折线拐角变化；300 ms / 750 ms 和绕行舒适度尚待新版本实测。
- 有限横向搜索窗口可能遗漏窗口外的绕行；走到窗口边缘时可通过转向再规划。
- 本轮不改相机朝向与人体朝向近似，也未重新标定真实行走语音节奏。

## 交付记录

待最终编译与设备安装后补充。安装保留现有应用容器，不卸载、不清除录制。
