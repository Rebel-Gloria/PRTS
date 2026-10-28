# 实测 DIAG 复盘与算法优化建议（2026-10-28）

证据等级标记：**[视频]** 在 dev-capture 视频帧中看到；**[DIAG]** 仅在 DIAG 记录中看到；**[回放]** 离线回放已验证；**[推测]** 假设，未验证。
所有"回放"只重跑规划，不重建缺失的 10 Hz 帧，不是真机验证。

## 1. 数据清单

设备：`xcrun devicectl list devices` 只看到 iPhone 17 Pro Max "PRTS"（00008150-001928591AC0401C，已连接）和两个模拟器。**iPhone 15 Pro "Gloria"（build 17–25 的主要外场数据）未连接，其数据未获取，本报告不涉及。**

数据拉取到 `scratchpad/diag/pull-17pm-1028`（846 MB，仅本地，未上传）。共 3 次启动，均为 build 25 / commit c1361ac / Release：

| Run | 启动 UTC | 内容 | 视频 |
|---|---|---|---|
| A `2026-10-28T11-20-33Z-020FD331` | 11:20:33 | 约 80 s，3 个 epoch；epoch2 50 s、epoch3 6 s；**坐姿静止测试**（玻璃茶几、膝盖），非步行 | 1 段，70 样本（约 14 s） |
| C `2026-10-28T11-22-21Z-DBE04E67` | 11:22:21 | 只有 events/heartbeat，无相机数据 | 无 |
| B `2026-10-28T11-28-26Z-54463EA9` | 11:28:26 | 约 850 s 启动期内 4 个 epoch，实际相机运行 ≈ 28.9 / 71.1 / 75.7 / 32.9 s | 4 段 |

Run B 的 4 个 epoch：
- B1 = epoch1，29 s，**室内住宅**，杂物多，视频 132 样本。
- B2 = epoch2，71 s，**夜间小区道路**，光线很暗，视频 265 样本。
- B3 = epoch3，76 s，**夜间人行道步行**（共享单车、电动车、行人、地铁站入口台阶），视频 310 样本（约 68 s）。这是最有价值的一段。
- B4 = epoch4，33 s，视频只有 3 样本。

视频限制：dev capture 达到 256 MiB 上限后停止（status.json 写明），B3 最后约 8 s 和整个 B4 没有视频。样本 5 Hz，丢弃 227–292 帧。
健康度：thermal 全程 nominal；分析 10.0 Hz、采集 60 Hz；sourceAge p95 47.8 ms；规划耗时 p95 0.5 ms；常驻内存峰值 732 MB。diag 写入丢弃 mesh 289/2753、capture 21/12778，无失败。`summarize_session.py` 只支持 metrics.csv 格式，对这些目录不能运行；本文数字来自 `read_diag.py` 及对 jsonl 的直接统计。

局限：只有 1 台设备、1 位测试者、约 3 分钟真实户外步行、没有独立真值、没有语音记录（见 §4.6）。结论是"线索"，不是统计结论。

## 2. 发现

### F1 步行时方向稳定门几乎常关（[DIAG]，已用位姿离线复现 100% 吻合）
`DirectionGate`（`Vendor/SpatialCore/Sources/SpatialCore/Ground.swift`）要求 60 Hz 位姿的**单帧**角速度 ≤ 30°/s 且连续 0.5 s。手持步行时手机晃动，角速度 p50 = 15.9°/s、p90 = 35.3°/s，任何一帧超限就清零。

| epoch | 场景 | directionStable 占比 | 角速度 p50 / p90 |
|---|---|---|---|
| B1 | 室内慢走 | 48% | 13.2 / 39.4 |
| B2 | 夜间小区 | 47% | 13.5 / 33.1 |
| B3 | 人行道步行 | **17%**（91 次开关） | 15.9 / 35.3 |
| B4 | 步行 | 23% | 16.2 / 34.5 |

后果：`pathHeading` 要求 directionStable，所以方向触觉在 B 全程 468 次 feedback 记录中有 332 次是"振动暂停"；guidanceGate 在 6105 次里 3579 次为 `current_direction_unstable`。

### F2 地面/模型失败帧被当成"前方畅通"，并清空障碍确认（[视频]+[DIAG]+[回放]）
`Analysis.swift` 在地面拟合失败/待确认时提前返回，结果**没有 grid、没有 plane**。`TemporalOccupancyGrid.apply` 对这种帧遍历空格网：
1. 没有障碍 → `ObstacleWaypointPlanner` 输出 `front_clear / scenario=clear`；
2. `previous = current` 把所有 300 ms 确认轨迹清零。

B3 中 modelState=blocked 的帧：`ground_fit_failed` 75 + `ground_confirmation_pending` 54 + 44（均被报为 front_clear）。B3 全程 front_clear 约占 96%。

最典型的一次（B3，视频 idx 205/209，f2545/f2593，t=42.4/43.2 s，见 `evidence/field-2026-10-28/B3_205.jpg`、`B3_209.jpg`）：电动车尾箱离镜头约 0.3–0.5 m、占满画面。DIAG：f2593 深度 min 0.25 m / mean 0.28 m，modelState=blocked(ground_fit_failed)，路线状态 `front_clear`。更早的 f2281（t=38.0 s，`B3_185.jpg`）报 nearObstacle 距离 0 → blocked，随后 f2323（38.7 s）又回到 front_clear，此后约 5 s 内电动车仍在路径上（idx 193–209）却一直 front_clear（f2401–f2557 取样帧 nObs=0）。
语音策略 `ObstacleRouteAnnouncementPolicy` 在场景稳定 0.6 s 后对 `.clear` 播"前方无障碍"，且 `activeWaypointUpdate` 不检查 directionStable 或地面是否当前确认。**语音没有被记录，所以"实际播了"是按代码推断，未被 DIAG 证实。**

### F3 行人/障碍确认稀少（[DIAG]，与 F1/F2 相关）
B3 前 36 s 分析帧里仅 8 帧有确认障碍（`nObs>0`），而视频中同一时段有迎面行人（idx 97，t=19.3 s，含人脸，不入库）、停放电动车/自行车贴着路沿（idx 121–169）。路线始终 front_clear。其中一部分是物体在侧面、确实不挡路；但 F2 的轨迹清零使 300 ms 确认很难在 20–25% 的失败帧下完成。尚无法分清"漏检"与"不在车道内"（缺车道内真值）。

### F4 室内/静止时场景抖动（[DIAG]，Run A、B1）
B1 29 s 内场景段 18 段，其中 <0.6 s 的 5 段、<1.5 s 的 11 段（clear↔near 在 0.1 s 内翻转，如 693.87→693.97）。Run A 坐姿 50 s 内出现 8 次 `no_detour obsD=0`（膝盖挡镜头）。语音策略已有 0.6 s 稳定与 2.5 s 间隔，实际打扰程度未知。

### F5 夜间户外：深度置信度很低（[DIAG]）
平均"高置信像素"占比：B1 室内 69%、B4 77%，B2 夜间小区 45%，**B3 仅 16%**（低置信 60%）。ARKit 只接受 high。B3 中 `current_confirmed` 地面仅 401/768 帧，其余为 retained 或 unconfirmed。原因（运动模糊/路面纹理/过暗）未确定。

### F6 台阶/落差没有任何检测逻辑（[视频]+代码检索，[推测]）
B3 视频 idx 289/301（f3733/f3943，t=62.2/65.7 s，`B3_289.jpg`、`B3_301.jpg`）：地铁站入口台阶，边缘黄色防滑条。同时段 DIAG 路线为 front_clear（t=65.7 有 5 个确认格，dmin=0.91 m，f3967 起又为 0）。`SpatialCore` 全源码检索 dropoff/curb/stair/ledge/step 无结果。台阶是上行还是下行无法从单视角确定，故只能说"没有该类逻辑"，不能说漏报。

### F7 被正确处理的对照（[视频]+[DIAG]）
B2 t=19.2 s（f1153）路边平板车：DIAG 在 st=1 时转 nearObstacle，确认格 3→23，距离 1.5→0.95 m，视频 idx 91/96 中平板车确实侧挡路径。检测和时机与画面一致，说明管线在深度质量好、方向稳定时可用。

## 3. 优化建议（按优先级）

### P1 `PathPredictor.occupancyUpdate`：失败帧不再当"畅通"，且不清轨迹（证据：[视频]+[DIAG]+[回放]）
文件/函数：`Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift`，`occupancyUpdate`，在 `occupancyFilter.apply` 之前加分支。
做法（已在一次性 worktree 里实现并回放）：当 `result.grid == nil && modelState == "blocked"` 且原因不含 `tracking_not_normal`：
- 不调用 `apply`（保留确认轨迹，最大间隔仍 0.75 s）；
- 若上一个未失败帧是非 clear 且 ≤ 0.75 s，则沿用（`model_blocked_held`）；
- 否则若深度 mean < 0.6 m，输出 `scenario=.blocked`、距离 = 深度 min（"前方障碍约 0.3 米，暂无绕行路径"）；
- 否则输出 `reason=model_blocked` 且 `waypointGuidance=nil`（不播"无障碍"）。

回放结果（基线与候选均用 5 Hz 样本，基线重放与线上记录一致率 308/310）：

| 段 | 变化帧 | 内容 |
|---|---|---|
| B3 | 20/310 | 17 帧 front_clear→model_blocked；3 帧（t=43.0–43.4 s，即 `B3_209.jpg` 附近）front_clear→no_detour/blocked，距离 0.25–0.28 m |
| B2 | 5/265 | f4135 起 4 帧 front_clear→nearObstacle（沿用） |
| B1 | 1/132 | nearObstacle→model_blocked_held |
| 确认障碍帧数 | B3 9→12，B2 89→91，B1 121→122 | 轨迹不再被失败帧清空，略有增加 |

单测：`swift test -j 2`（worktree，候选已含）326 个全部通过，0 失败。也就是说现有测试**没有**覆盖 blocked 帧，需要新增 3 个测试：blocked 帧不输出 clear；blocked 前后障碍确认轨迹保留；近距 blocked 输出 `.blocked`。
风险：开机约 2 s 地面确认期、以及步行中约 20% 的失败帧会从"clear"变成"静默"，用户会少听到"前方无障碍"；"沿用"可能把已离开的障碍多保留 0.75 s。语音层是否需要在静默超过若干秒时播"请缓慢转动手机"需另行设计。
还需真机：确认不会造成更多"暂无绕行路径"的误报（0.6 m 阈值来自 B3 的一个事件）。

### P2 `DirectionGate`：用短窗平滑代替单帧阈值（证据：[DIAG] 位姿级离线模拟，行为影响为[推测]）
文件：`Ground.swift`，`DirectionGate.update`。
离线模拟（用 `capture.jsonl` 的 60 Hz 位姿重跑门控，基线 100% 复现记录值）：

| 方案 | B1 稳定% | B2 | B3 | B4 | B3 开关次数 |
|---|---|---|---|---|---|
| 基线 30°/s、0.5 s | 46 | 47 | 17 | 22 | 91 |
| 阈值 45°/s | 79 | 81 | 67 | 72 | 61 |
| 仅偏航 45°/s | 73 | 82 | 87 | 89 | 25 |
| 0.3 s EMA、30°/s、0.5 s | 75 | 85 | 84 | 89 | 15 |
| 0.3 s EMA、40°/s、0.3 s | 87 | 92 | 96 | 92 | 5 |

建议先试"0.3 s EMA、30°/s、0.5 s"：保持原阈值语义，只滤掉手臂摆动的瞬时尖峰，B3 稳定率 17%→84%，开关 91→15 次。
风险：这是安全相关闸门，放宽后方向触觉会在手机真实快速转向时晚几十毫秒才暂停；`ProbeParameters.maxAngularSpeed/stableDuration` 的含义改变。需改测试：`SpatialCoreTests.testDirectionChangeAndTrackingLossInvalidateImmediately`（"立即失效"的断言必须保留快速真实转向的路径）、`MotionPresentationTests`。本项未跑 planner 回放（回放读取已保存的 stable 标志，无法重现闸门）。
还需真机：不同行走速度、手臂姿态下方向触觉是否跳变。

### P3 语音层：`.clear` 只在"当前确认地面 + 方向稳定"时播报（证据：代码阅读，[推测]）
文件：`PRTS/Feedback/FeedbackCoordinator.swift`/`ObstacleRouteAnnouncementPolicy.swift`、`Snapshots.swift` 的 `activeWaypointUpdate`。
`activeWaypointUpdate` 不检查 directionStable 与 groundReferenceMode。P1 完成后 clear 已更可靠；P3 是第二道保险：对 `.clear` 加 `groundReferenceMode == current_confirmed` 条件，不满足则不播也不当作 spoken。风险：长时间静默。属 App 层，不在 SpatialCore 单测内；本次未做回放（语音不在回放范围）。

### P4 近距台阶/落差检测（证据：[视频]+代码检索，[推测]）
目前无任何逻辑。建议先在 DIAG/回放里用 B3 idx 285–301 的深度附件离线评估"地面高度突变 / 地面平面缺失"特征，再决定是否实现；这是新功能，需要真机上下台阶数据，不应直接合入。

### P5 夜间户外深度置信度（证据：[DIAG]，原因[推测]）
可检验：在离线脚本里用保存的深度+置信度重跑 `SpatialAnalyzer`，对比"仅 high"与"high+medium"（仅用于障碍占据确认，不用于地面拟合）的地面拟合成功率和假障碍。未做，因为回放脚本直接读取已保存的 AnalysisResult，不重跑分析器，需额外脚本。

### P6 记录/工具改进（证据：[DIAG] 缺口）
- 语音 cue 与触觉请求没有写入 DIAG（只有 path.jsonl 的 feedback 触觉）。新增 `speech_cue` 事件（文案、场景、帧号），否则无法核对 F2 的语音。
- dev capture 256 MiB 上限在 B3 之后耗尽：B4 无视频，B3 缺最后 8 s。建议降低深度附件频率或按"非 front_clear"优先保留。
- `summarize_session.py` 不支持 DIAG 目录，`scripts/README.md` 里应说明。

## 4. 仍需真机步行验证
1. P1 的静默策略对用户的实际影响（需要盲人/蒙眼测试者）。
2. P2 放宽闸门后方向触觉的稳定性与误导风险。
3. 步行时真实前方障碍的漏检率：需要有独立标注的路线（本次无）。
4. 台阶/路缘/落差（P4）。
5. 白天户外与夜间的置信度差异（F5），以及 iPhone 15 Pro 上的同类表现（Gloria 数据未拿到）。
6. 重复性：本次只有一次人行道步行。

## 5. 证据文件与复现
- 图片（仅含物体/地面，无人脸）：`docs/reports/evidence/field-2026-10-28/B3_185.jpg`（f2281，38.0 s）、`B3_205.jpg`（f2545，42.4 s）、`B3_209.jpg`（f2593，43.2 s）、`B3_289.jpg`（f3733，62.2 s）、`B3_301.jpg`（f3943，65.7 s）。已旋转为竖屏，上方标注样本序号/帧号/PTS。含行人的帧（B3 idx 13/61/97、B1 idx 1–3 附近）仅留在本地 scratchpad，未入库。
- 原始数据与回放输出：`/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/`（`diag/`、`replay/base_*.jsonl`、`replay/candA_*.jsonl`、`gate.py`、`blk.py`、`tl3.py`、`cmp.py`）。
- 候选改动只存在于已删除的一次性 worktree；仓库 `/Users/kyf/Documents/PRTS` 除本报告与证据图外未修改。
