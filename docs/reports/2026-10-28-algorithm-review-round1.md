# 算法调优审查（GPT-6-Astra xhigh，2026-10-28）

- 来源：`codex exec -m gpt-6-astra -c model_reasoning_effort="xhigh" -s read-only`，只读审查，约 36 分钟。任务说明见文末附录。
- Claude 复核（2026-10-28）：逐一核对了下列代码引用，均与源码一致——`TemporalOccupancyGrid.swift` 首个平面永久锁定（第 45 行）、300 ms 确认且一次未命中即重置（第 92–131 行）；`Geometry.swift` 身体宽 0.60 m + 单侧余量 0.15 m 与 `PathPrediction.swift` 规划总宽 0.50 m 相互矛盾；`PathHapticPolicy.swift` 未锁定时超过 alignment（5°）即开始左右振动；`FeedbackPolicy.swift` 被冷却挡住的升级仍会更新 `lastSeverity`；`ObstacleRouteAnnouncementPolicy` 的 0.6 s 场景等待和 2.5 s 统一冷却。
- **未独立复算**的数据：B3 的 34/31 帧近距观测、平面高度差表、宽度冲突比例、`no_visible_target` 比例。这些数字来自 Astra 对 DIAG 的统计，采用前应先用回放复现。
- 报告中提到的"反馈层未提交修改"指本轮的语音文案和两档障碍改动；第 2 条的策略复算基于新代码。

---

**优先修三件事：近障告警不应等待路线确认；危险升级不应等待普通语音冷却；规划不能永久沿用首次拟合的倾斜平面。** 这三项都有代码依据，其中前两项能在现有时序记录中找到触发机会，第三项已有明显的几何偏差证据。

本次全程只读。通读了指定链路、历史报告，并核验 DIAG、Dev Capture 和已有候选回放；源码一致性检查 **9 项通过**。没有运行会生成构建文件的 Swift/Xcode 测试。

以下代码位置指当前工作区。核心算法与实测 commit `c1361ac` 一致；**反馈层已有未提交修改**，因此语音策略复算代表当前代码，不能冒充实测时实际播放的声音。时间均相对各 epoch 首帧；B3 起点为 AR 时间 `1383.610046416`。

原始证据见 [本机 DIAG 目录](/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028)。下文不重复现有报告 P1–P6，仅补充其边界或列出独立问题。

**一、按风险排序的问题**

**1. 高风险：300 ms 占用确认同时充当告警许可，会压住已有近距观测的警告。**

对用户的影响：传感器已经检出近物，用户仍可能听不到警告；短暂遮挡、窄小移动物体尤其值得关注。

**证据：[代码] [数据]**

- [TemporalOccupancyGrid.swift:92](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/TemporalOccupancyGrid.swift:92) 接纳原始障碍样本，但只有持续满 300 ms 才进入规划障碍；第 131 行在一次未命中后丢弃轨迹。
- [PathPrediction.swift:358](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift:358) 默认链路只使用该确认模型；原始深度没有独立的近距告警出口。
- [ContentView.swift:139](/Users/kyf/Documents/PRTS/PRTS/UI/ContentView.swift:139) 有航点状态时不再消费原始中心障碍反馈。
- B3 的 **768 条分析记录中，34 帧在相机前向宽 0.50 m、距离不足 1 m 的带内存在原始 obstacle 格，31 帧规划仍为 clear**。这 31 帧全部是 `modelState=built`、`retained_world_reference`，所以现有 P1 的“无 grid 失败帧”修复不会直接覆盖它们。
- 例如 f2257–f2269，t=37.615–37.815 s，原始近缘距离 **0.6→0.5→0.4 m**，确认障碍仍为 0；f2275 才进入 blocked。

这些是“观测与输出不一致”的证据，**不能当作 31 次真实漏报**：保留地面可能分类错误，也没有逐帧真值。

**修改方案**

把“是否提醒危险”和“是否提交绕行”分开。保留 300 ms 路线确认，新增当前深度的近距告警分支。建议初始试验值：

```text
在身体通行带内聚合空间相邻的高置信深度点，允许跨栅格：
距离 ≤ 0.5 m 且簇支持 ≥ 6 点：本帧告警
距离 ≤ 1.0 m，最近 3 帧中至少 2 帧命中，时间跨度 ≤ 250 ms：告警

该分支只提升危险等级、撤销冲突方向提示；
不据此生成左右绕行，也不证明前方畅通。
```

不要直接把所有占用确认改成 100 ms：B1 的 132 个 Dev 样本中，5572 个确认方格实例里，有 **718 个（12.9%）在原始栅格中仅有 1–2 个障碍点、状态为 unknown**。它们未必是假障碍，但说明单纯缩短时间门会同时放大弱证据。

**预算与验证**

复用已有点云/栅格，新增聚类预算目标 **≤0.5 ms/分析帧**，尚未真机测量。用完整 DIAG 回放检查首次合格近距观测到告警状态的延迟；真机补窄杆、横穿行人、黑色物体和地面误报场景。新增 `rawLaneMinDistance`、`clusterSupport`、`trackHitCount`、`trackResetReason`、`fastHazardReason`。

---

**2. 高风险：危险升级受 0.6 s 场景等待和 2.5 s 普通播报间隔限制，短危险可以完全没有语音。**

对用户的影响：刚听到普通提示后障碍迅速逼近，紧急提示仍被限频；“无法绕行”短暂出现也可能不发声。

**证据：[代码] [数据／策略复算]**

[ObstacleRouteAnnouncementPolicy.swift:34](/Users/kyf/Documents/PRTS/PRTS/Feedback/ObstacleRouteAnnouncementPolicy.swift:34) 对后续场景变化统一等待 0.6 s，第 46 行对所有后续播报统一限频 2.5 s。[FeedbackCoordinator.swift:36](/Users/kyf/Documents/PRTS/PRTS/Feedback/FeedbackCoordinator.swift:36) 又要求当前感知语音不在播放。

B3 实际发布过：

- t=37.915–38.115 s：blocked，约 **0.20 s**；
- 随后 nearObstacle，约 **0.60 s**；
- 再回 clear。

按实际 publication 时间、每次发布调用一次当前策略，假定 `canSpeak=true`、无方向输入，**整段 B3 只产生初始 clear，没有障碍语音**。这是有利于发声的离线假设，仍不是实际音频记录。

另一个确定性漏洞在备用 [FeedbackPolicy.swift:40](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/FeedbackPolicy.swift:40)：危险升级若被 2 s 冷却挡住，第 44 行仍更新 `lastSeverity`，之后同等级持续存在也不会补报。

**修改方案**

单独维护危险等级及“已播等级”：

```text
危险升级，或当前路线被新障碍否决：
    取消过时方向语音
    绕过普通 2.5 s 冷却和场景 0.6 s 等待
    同一危险事件只播一次
普通方向重复、危险降级、恢复 clear：
    保留现有去抖与限频
```

“障碍很近”增加迟滞：建议进入 `≤1.0 m`，退出 `≥1.25 m` 持续 0.5 s。备用策略只在真正生成事件时更新“已播等级”，不能把被抑制升级记作已播。

**预算与验证**

常数状态操作，预算目标 **<0.05 ms/反馈 tick**。测试“普通提示后 100 ms 出现近障”“blocked 只持续 200 ms”“正在播左转时路线受阻”。真机验证实际声音开始时间、取消和 VoiceOver 并发。扩展既有 P6：记录 requested/started/cancelled/completed、抑制原因、危险事件 ID，不能只记录 cue 文案。

---

**3. 高风险：首次未确认的倾斜平面被永久固定，走远后偏差达到米级，并影响规划与反馈。**

对用户的影响：障碍距离、脚下投影、目标到达和可见性使用不一致的地面参考；可能造成异常选点或引导消失。

**证据：[代码] [数据]**

[TemporalOccupancyGrid.swift:45](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/TemporalOccupancyGrid.swift:45) 仅在 `referencePlane == nil` 时赋值，接受任何 `result.plane`，不要求当前确认，后续不校正。

该平面进入：

- [ObstacleWaypointPlanner.swift:38](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/ObstacleWaypointPlanner.swift:38) 的脚下投影、到达判断；
- 第 68 行的触发坐标；
- 第 143 行的目标可见性选择。

B3 在 **f91** 锁定的平面 `floorPriorConfirmed=false`，法向为 `[-0.07044, 0.99725, 0.02283]`，随后一直沿用。只统计 `current_confirmed` 帧，计算：

```text
abs(当前地面.height(固定规划平面.project(相机位置)))
```

| 段 | 当前确认地面帧数 | 两平面在脚下的高度差中位数 | 最大值 |
|---|---:|---:|---:|
| B1 | 225 | 0.016 m | 0.052 m |
| B2 | 538 | 0.315 m | 0.800 m |
| B3 | 401 | 0.729 m | 1.857 m |

B3 有 **348/401 帧（86.8%）超过 12 cm**。f3757 时，相机相对当前地面高约 1.325 m，相对固定规划平面却为 **−0.532 m**。

这是两个算法参考之间的差异，不是独立测量的真实地面误差；但足以反驳历史文档中“固定高度只影响绘制”的适用范围。

**修改方案**

- 首次未确认平面不升级为永久导航参考。
- 世界方向和目标的水平位置保持；高度参考采用当前确认的局部地面。
- 局部高度差超过 **4 cm** 或法向差超过 **3°** 时，重投影路线、目标和预备段，并重新检查全部扫掠足迹。
- 超过 **12 cm / 8°** 时，暂停方向提示，完成坐标重建和碰撞复核后恢复。
- 障碍关联身份与地面高度修正解耦，避免修正平面导致所有计时器重置。

**预算与验证**

参考比较是常数操作；重投影和复核预算目标 **≤0.3 ms/帧**，重规划另计。回放验证上述高度差收敛、障碍投影和净距不退化；真机验证长走廊、缓坡、持机高度变化。新增 `planningPlaneSourceFrame`、`planningPlaneConfirmed`、`localPlaneHeightDelta`、`planeRebaseReason`。

---

**4. 高风险但本次未复现：新鲜相机帧可以持续授权陈旧的规划语音和振动。**

对用户的影响：分析暂停或变慢时，相机仍在采集，旧方向可能继续输出。

**证据：[代码]；发生频率未证实**

- [RouteContinuity.swift:85](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/RouteContinuity.swift:85) 明确豁免 obstacle-veto 候选的结果年龄。
- [PathPrediction.swift:125](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift:125) 豁免该策略路径的保留时限。
- [Snapshots.swift:263](/Users/kyf/Documents/PRTS/PRTS/Spatial/Runtime/Snapshots.swift:263) 的航点反馈只检查最新相机帧年龄，没有检查 `context.timestamp`；方向反馈沿用同样的路径有效性。

现有测试甚至明确要求“TTL 不撤线”。保留路线意图可以成立，**持续授权声音和振动需要另一个时效条件**。

本次 B 的 publication 源年龄最大约 **54.9 ms**，没有该类停顿证据。

**修改方案**

保留世界路线缓存，但反馈必须满足：

```text
now - lastSuccessfulObstacleEvaluationSourceTime ≤ 0.25 s
且 epoch、参数版本、坐标代次一致
```

不要用发布时间刷新这个时间。超时撤销方向提示和 clear 播报许可。

单目分支还需把 `metric_world_reference_conflict` 当作硬失效：[ProbeEngine.swift:277](/Users/kyf/Documents/PRTS/PRTS/Spatial/Runtime/ProbeEngine.swift:277) 已产生该标志，但默认规划在 [PathPrediction.swift:291](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift:291) 不处理这些参考冲突。现有 P1 的“沿用 0.75 s”不能跨越尺度冲突。

**预算与验证**

预算目标 **<0.05 ms/tick**。注入“采集继续、分析停 300 ms/1 s”“迟到旧结果”“单目尺度冲突后恢复”。必须真机覆盖 Core ML 慢帧及热降频。新增 `feedbackSourceAge`、`lastObstacleEvaluationFrame`、`coordinateGeneration`、`feedbackBlockReason`。

---

**5. 历史宽度风险的新量化证据：0.50 m 路线确实不能容纳配置中的 0.60 m 身体。**

这不是新发现：build16/17 报告已记录宽度策略变化。本次补充当前数据中的实际影响。

**证据：[代码] [数据／几何复算]**

[Geometry.swift:123](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/Geometry.swift:123) 默认身体宽 0.60 m、单侧余量 0.15 m，总宽 0.90 m；[PathPrediction.swift:13](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift:13) 默认规划总宽只有 0.50 m。取两者最大值只出现在 verified 分支。

对 B 的 **518 个有路线预测帧**，按日志中的完整世界障碍方格复算同一条路线：

| 扫掠总宽 | 与已确认模型冲突的帧数 |
|---|---:|
| 0.50 m | 0 |
| 0.60 m，仅身体宽 | **21，4.1%** |
| 0.90 m，身体加余量 | **150，29.0%** |

这不是实际碰撞次数，也不是加宽后重新规划的结果。

**修改方案**

统一一个有效宽度：

```text
effectiveWidth = max(path.minimumWidth, bodyWidth + 2 * sideMargin)
```

搜索、当前路线复核、触发带和反馈许可使用同一值；舒适余量只能在此基础上增加，失败时不能回退到低于身体宽度。默认配置对应 **0.90 m**。

**预算与验证**

宽度增加会扩大 mask 查询范围，并可能增加无路时的图搜索，不能承诺耗时不变。建议规划 p95 预算 **2 ms**，记录搜索次数、节点扩展和超预算原因。回放检查重新规划后的净距及无路比例；真机用已知宽度通道和实际持机偏置验证。新增 `requestedWidth`、`effectiveWidth`、`minimumRouteClearance`。

---

**6. 中风险：方向反馈的实际启振阈值接近 5°，且“直走”语音分支没有正常产生入口。**

对用户的影响：细小偏角也要求左右修正；关闭触觉时，用户可能缺少“已经转够”的声音确认。

**证据：[代码] [数据]**

[PathHapticPolicy.swift:43](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathHapticPolicy.swift:43) 的 12° 阈值只用于退出已对准状态；未锁定时，只要超过 alignment=5° 就进入左右模式。

B 的 **59 次脉冲请求中，5 次角度仅为 5.23°–6.47°**，低于配置的 12°。这些记录证明请求发生，不证明用户实际感受到振动。

[FeedbackCoordinator.swift:106](/Users/kyf/Documents/PRTS/PRTS/Feedback/FeedbackCoordinator.swift:106) 对准时返回 nil，其余只返回 ±1，因此 `.obstacle(distance, 0)` 的“直走”文案没有正常生成路径。航点语音还在 [ObstacleRouteAnnouncementPolicy.swift:39](/Users/kyf/Documents/PRTS/PRTS/Feedback/ObstacleRouteAnnouncementPolicy.swift:39) 硬编码 alignment=5，可能与用户设置不同。

**修改方案**

采用明确的三态迟滞：

- 中立状态达到 **12°** 才进入左右提示；
- 已进入左右状态，回到 **5°** 内并持续 0.3 s 才确认对准；
- 5°–12° 保持已有状态，中立状态不主动催促修正；
- 语音和触觉使用相同 alignment 参数；
- 从已播左右转向进入已对准状态时，可产生一次“直走”，前提是当前路线和危险检查仍有效。

**预算与验证**

常数状态操作，目标 **<0.05 ms/tick**。测试 ±4/6/10/13°、缺帧恢复、同方向目标换号及“仅语音”模式；真机验证左右辨识和修正频率。新增 `feedbackLogicalState`、`effectiveAngleThresholds`、`rearmReason`。

---

**7. 中风险：把地面目标是否出现在 RGB 画面内，作为盲人导航路线能否提交的硬条件。**

对用户的影响：几何绕行已经找到，却因持机俯仰或目标出画失去方向引导。

**证据：[代码] [数据]**

[ObstacleWaypointPlanner.swift:140](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/ObstacleWaypointPlanner.swift:140) 提交路线必须通过 `visiblePlan`；失败产生 `no_visible_target`。

B1 的 300 个预测帧中，**38 帧（12.7%）为 no_visible_target**，最长连续约 **3.10 s**。该原因表示搜索产生了候选，但提交未通过可见性要求；不能据此认定候选在真实世界安全。

**修改方案**

先修第 3 项的地面参考，再区分“目标图标可见”和“导航下一段有足够当前观测”。允许终点出画，但导航入口应检查下一段约 **0.6–1.0 m** 的观测覆盖、身体足迹和当前障碍；无需为了图标出画立即更换世界目标。

**预算与验证**

额外局部检查预算目标 **≤0.3 ms/帧**。回放统计可见性拒绝减少多少、是否增加未观测段；真机验证不同俯仰、左右转向和相机偏离行走方向。新增 `geometricPlanAvailable`、`targetVisibilityRejected`、`nextSegmentObservedFraction`。

**二、可以删除或简化的逻辑**

目前能安全等价简化的主要是重复计算；没有证据支持直接删除生命周期、追踪、障碍水位或完整足迹检查。

- **延迟构建第二张相机朝向规划栅格。** [PathPrediction.swift:371](/Users/kyf/Documents/PRTS/Vendor/SpatialCore/Sources/SpatialCore/PathPrediction.swift:371) 每帧生成 `cameraResult`，实际只在重定向／目标出画分支使用。改为按需生成，必须使用同一帧、同一确认模型，不重复摄入观测。
- **对保守栅格拒绝做精确复核。** 旋转方格 stamp 后再膨胀可能扩大禁区。对 mask 拒绝的候选，用已有世界方格做精确圆盘碰撞复核；只有精确检查无交才放行。不要通过缩小身体宽度解决量化拒绝。
- **两层 clear 去抖可以合并，但需先补传感器有效性。** 场景层已有 0.6 s，语音层再等 0.6 s。增加明确的 `clearConfirmedSince` 后，语音可消费该证明，省去重复等待。当前不能直接删除第二层。
- 第 7 项的可见性硬门应替换为导航观测条件，**不宜无条件删除**。

不建议删除 `ForwardRoutePlanner` 或 `ObstaclePersistence`：前者仍用于历史对照，搜索模块还被当前航点链复用；后者不是当前默认链路额外叠加的一次 300 ms 等待。

**三、默认参数中需要纠正的地方**

| 参数／实际行为 | 判断与建议 |
|---|---|
| 规划宽 0.50 m，身体宽 0.60 m | 配置自相矛盾；默认有效宽应统一为 0.90 m |
| 所有占用统一等 300 ms 才能影响反馈 | 绕行稳定性参数不应同时约束紧急告警 |
| 语音统一 2.5 s 冷却、场景统一等 0.6 s | 危险升级应例外，恢复和普通重复保留 |
| nearMeters=1，无迟滞 | 建议进入 ≤1.0 m，退出 ≥1.25 m 持续 0.5 s |
| deviation=12°，初始却在 >5° 提示 | 修正状态机，统一语音／触觉参数 |
| 首次规划平面永不更新 | 1.4 m 只能是初始化占位，未确认斜面也不能永久固定 |
| obstacleTriggerDistance=1 等旧参数 | 默认 `laneOnly` 航点分支不使用三角触发距离；调它不能解决当前近障时机问题 |

方向稳定门的 30°/s、0.5 s 已属现有 P2，本次不重复建议。

**四、验证路径和测试缺口**

一个重要补充：**现有数据并非只能做 5 Hz 航点回放。** B 的 DIAG 有 **2123 份深度附件／2126 条分析记录**；B3 的 **768 条分析记录全部有深度附件**。附件包含置信度、位姿、内参、参数、方向标志和 floor priors，可重跑已保存帧的 `SpatialAnalyzer`。丢失记录仍须显式标注，不能插值制造命中。

建议建立两层验证：

| 验证层 | 必须新增的检查 |
|---|---|
| 原始 DIAG 感知回放 | 近距簇、采样步长、地面重建、确认轨迹重置原因；按真实时间戳处理缺口 |
| 规划与发布回放 | 身体宽度净距、地面重投影、陈旧反馈许可、坐标冲突失效 |
| 反馈状态机测试 | 危险升级抢占、短 blocked、冷却期升级不丢失、对准后“直走”、语音忙碌 |
| 几何合成测试 | 长距离行走叠加初始 4° 平面误差；不同栅格相位／旋转；窄小移动障碍 |
| 真机测试 | 有标注的静态／移动障碍、窄通道、缓坡、不同持机姿态；实际发声和触觉时延 |
| 单目专测 | 尺度跳变、恢复确认、慢帧时旧方向撤销；本次 LiDAR 数据不能覆盖 |

现有回放的“确认模型零冲突”不能作为漏报验收：B3 基线 310 个样本只有 **3 个有路线的确认模型检查**，这 3 条路线的原始障碍检查均报告冲突。原始冲突可能包含噪声，但它说明必须同时报告**告警召回、原始／确认模型差异和检查覆盖率**。

对现有 P1 再补两点：

- “沿用 0.75 s”应保留危险状态或路线意图，不能自动延续方向授权。
- 全图深度 mean/min 不能代替身体通行带的近距簇；ARKit depth 本身是相机平面轴向距离，也不是地面通行距离。([developer.apple.com](https://developer.apple.com/videos/play/wwdc2020/10611/))

**五、实时预算与基线影响**

现有 iPhone 实测并未显示分析耗时紧张：

| 段 | 分析 worker p95 | 路径规划 p95 |
|---|---:|---:|
| B1 | 3.96 ms | 1.85 ms |
| B2 | 3.45 ms | 0.31 ms |
| B3 | 2.25 ms | 0.19 ms |
| B4 | 4.70 ms | 0.32 ms |

上述修改预算均是**工程目标，非实测承诺**。建议先保留现有搜索器，把新增工作限制在局部聚类、有效性判断和几何复核；整体 worker p95 可先以 **6 ms** 为验收目标，另看最坏耗时和热稳态。

依据当前 [一致性测试](/Users/kyf/Documents/PRTS/scripts/test_spatial_integration.py:9)，后续修改的同步范围如下：

| 修改位置 | 基线影响 |
|---|---|
| `Analysis.swift`、`Depth.swift`、`Grid.swift`、`Geometry.swift`、`Ground*.swift` | 同步 `Experiments/SpatialProbe/Core/Sources/SpatialCore/` 对应文件 |
| `PathHapticPolicy.swift`、`ResultPresentationGate.swift`、`DiagnosticMeasurements.swift` | 同步对应 Core 基线 |
| `PathHaptics.swift`、`MonocularDepthProvider.swift` | 同步 `Experiments/SpatialProbe/App/` 对应文件 |
| `TemporalOccupancyGrid`、`OccupancyFootprint`、`ObstacleWaypoint*`、`RouteContinuity` | 当前无对应冻结文件；增加主库回归测试 |
| `PathPrediction.swift`、App 语音策略、`Snapshots.swift` | 当前不做对应整文件字节比较；补行为测试 |
| `FanPathSearch` 的碰撞数学 | 若修改，需要同步其被单独固定比较的数学实现 |

不应通过扩大一致性测试的豁免范围让修改通过。此次已核验全部 **780 个 Dev 样本**及 DIAG 附件，无校验错误；这证明输入可用，不代表算法或真实避障效果已经验收。

---

## 附录：任务说明

你是资深的空间感知 / 路径规划算法工程师。请对 PRTS（给盲人用的 iPhone 避障导航 App）当前算法做一次只读审查，找出**可以调优的问题**，并给出可验证的修改方案。

## 背景

- 设备：iPhone 17 Pro Max（LiDAR），ARKit sceneDepth + 网格；无 LiDAR 时用 Core ML 单目深度并做尺度校准。分析 10 Hz，采集 60 Hz。
- 输出给用户的只有：语音（"有障碍 / 障碍很近 / 向左 / 向右 / 直走 / 无法绕行"）和方向振动。用户看不到屏幕，**漏报障碍比误报危险得多**，但频繁误报也会让用户不再信任。
- 纯算法在 `Vendor/SpatialCore/Sources/SpatialCore/`（约 5300 行，纯 Swift，无 UI）。App 侧运行时在 `PRTS/Spatial/Runtime/`（`ProbeEngine.swift` 负责帧调度），反馈在 `PRTS/Feedback/`（`PathHaptics.swift`、`ObstacleRouteAnnouncementPolicy.swift`、`FeedbackCoordinator.swift`）。
- 架构文档：`docs/architecture/`（`RUNTIME_DATA_FLOW.md`、`FORWARD_ROUTE_POLICY.md`、`ROUTE_PROJECTION.md`）。
- 已有的实测复盘：`docs/reports/2026-10-28-field-diag-review.md`（P1–P6），以及更早的 `docs/reports/` 下各报告。请先读它，**不要重复已有结论**，可以验证、补充或反驳。
- 实测数据（只读，本机）：`/private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028/`（DIAG jsonl + dev capture）。读取工具：`python3 scripts/read_diag.py --help`、`scripts/read_dev_capture.py`。已有回放结果：同目录上一级的 `replay/`、`replay-baseline/`、`replay-candA/`（`scripts/compare_route_replays.py` 可对比）。
- 约束：`Experiments/SpatialProbe` 是逐字节一致性基线，`scripts/test_spatial_integration.py` 会对比；改算法时需要同步更新基线，这是允许的，但请指出影响哪些文件。

## 你要做的

1. 通读关键路径：深度 → 地面拟合（`Ground.swift`、`GroundReference.swift`、`SurfaceModel.swift`）→ 占用栅格（`Grid.swift`、`TemporalOccupancyGrid.swift`、`OccupancyFootprint.swift`、`ObstaclePersistence.swift`）→ 前向触发与路径（`ForwardObstacleTrigger.swift`、`PathPrediction.swift`、`ForwardRoutePlanner.swift`、`ObstacleWaypoint*.swift`、`RouteContinuity.swift`）→ 反馈门控（`FeedbackPolicy.swift`、`PathHapticPolicy.swift`、`ResultPresentationGate.swift`）。
2. 结合 DIAG 数据找证据。能用数据说话的地方请给出具体数字（帧数、比例、时间段）。
3. 输出**按风险排序**的问题清单。每条包含：
   - 问题（一句话）和对盲人用户的实际影响；
   - 证据：代码位置（文件:行号）和/或 DIAG 数据；证据等级标注 [代码] [数据] [推测]；
   - 具体修改方案（参数值或伪代码，越具体越好），以及对实时预算（iPhone 上每帧几毫秒）的影响；
   - 怎么验证：回放能验证什么、必须真机验证什么、需要新增哪些 DIAG 字段。
4. 另外单独列出：可以安全删除或简化的过度保守逻辑（不影响安全的前提下）、参数里明显不合理的默认值、以及测试覆盖缺口。

## 规则

- 只读：不要修改、创建或删除任何文件。可以运行只读的 python 脚本和 grep。
- 不确定的地方写明"推测"，不要编造数据。
- 用中文回答，结构清晰，结论在前。篇幅以讲清楚为准，不要凑字数。
