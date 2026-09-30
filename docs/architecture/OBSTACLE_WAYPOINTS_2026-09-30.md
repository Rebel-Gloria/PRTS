# Build24：三态障碍引导与逐点交接

## 范围和基线

基线 `71d4f9a`（main / build23）。沿用单一 ARSession、LiDAR/DA 输入、现有
300 ms 障碍模型、0.50 m 默认规划宽度及后台有界处理链。未移动目录、未新增依赖，
普通包与 Dev 包使用同一算法；Dev tag 仍只控制开发选项和采集。

本次替换产品默认的“空旷时持续向远处画线”调度。障碍模型未否决的栅格仍可搜索，
不添加地面支持、未知状态或净空证明门槛。空旷时不画线是明确的产品状态，
不是分析失败或候选未准备好。

## 三种情形

| 情形 | 目标与显示 | 语音 |
|---|---|---|
| 当前前向通行带无确认障碍 | 清除当前线、目标圈及预备点；不画远向投影 | 进入状态时一次“前方无障碍” |
| 前方障碍距离 >2 m | 在障碍前设置接近点，默认间距 0.55 m，最小可配 0.50 m | 障碍距离 |
| 前方障碍距离 ≤2 m | 复用贪心绕行、图搜索和侧向兜底，逐点引导 | 障碍距离＋当前点的转向 |

进入近障后，在距离回升超过 2.15 m 才返回远障，抑制边界往返切换。
“前方”是沿当前保留方向、默认 0.50 m 宽的通行带。正在绕行时，微小相机转动不旋转
已选路线参考。空旷时则持续更新相机前向参考。

距离是沿路线参考方向、从相机地面投影到前向通行带内障碍近缘的米制距离；不是
RGB 像素深度或三维欧氏距离。连通障碍侧面的近点不会把远处正前方墙面误报为近障。
远障接近点另外按二维圆形间距检查周围障碍，避免只满足轴向 0.55 m 而贴近侧面凸起。
路线仍使用配置的总宽度进行整段扫掠检查。

## 当前点与预备点

- `PathUpdate.goal` 和 `path.points` 只包含当前目标及其路线。
- `waypointGuidance.nextTarget` 是诊断预备点，没有路线身份，不参与绘制、语音或振动。
- 距当前点默认 1.2 m 内开始准备后续段。通常每 250 ms 更新；预备段被障碍否决时立即重算。
- 默认到达半径沿用 0.35 m。到达时复核预备段与脚下连接，成功后一次提交新目标和完整路线；
  失败则基于最新模型重新搜索，不直接发布先前草稿。
- 近障优先采用首个可见绕行拐点。若前面的拐点不在画面内，选择后续可见点但保留中间折线，
  不以直线切掉拐角。没有可见目标时记录 `no_visible_target`，提示调整手机方向。
- 正常替换候选尚未就绪时，仍保留未受阻的当前段；明确空旷、受阻或会话重置时可提交无路线状态。
- 下一点变化不能触发转向播报。切换当前点会取消旧点正在播放的转向提示。

## 三个重规划条件

1. 相对当前路线方向偏离至少 45°，在半径 0.12 m 内保持静止且朝向稳定 3秒。
   行走位移会重置计时；使用已有朝向稳定和时间缺口规则，浮点时间比较允许 1 μs 误差。
2. 当前目标离开真实 RGB 图像范围。使用同帧相机内参和位姿投影到未旋转完整图像；
   横竖屏的 aspect-fit 旋转不改变是否在画面内。缺少内参的旧回放记为 unavailable。
3. 当前目标或整条当前路线被确认障碍否决；远障接近点不再满足配置间距时也重新选择。

从远障进入近障时会及时改为绕行规划。绕行侧只在仍可行时保持；一侧受阻可以换侧。
跟踪失效、epoch/reset、参数版本和异步旧结果防覆盖沿用原机制。

## 实际调用链和职责

```text
ProbeEngine / FrameSnapshot（同帧 pose + RGB intrinsics）
  → PathPredictor（epoch、顺序、障碍水位）
    → TemporalOccupancyGrid（300 ms 确认；消失退出模型）
    → ObstacleWaypointPlanner（场景、当前点、可替换预备点、重规划）
      → ObstacleWaypointSearch
        → ForwardObstacleTrigger（laneOnly 距离）
        → GreedyDetourSearch / ForwardPathSearch / FanPathSearch
  → RoutePublicationPolicy（原子提交，区分 clear 与 candidate_not_ready）
  → SharedSnapshot
    ├─ PathDrawing / ProbeRenderer（只画当前段）
    └─ FeedbackCoordinator / ObstacleRouteAnnouncementPolicy / PathHaptics
```

纯几何新增三个文件，均位于 `Vendor/SpatialCore/Sources/SpatialCore`：
`ObstacleWaypointState.swift`、`ObstacleWaypointSearch.swift`、`ObstacleWaypointPlanner.swift`。
反馈策略位于已有 `PRTS/Feedback`。主页布局、配色和拍照问答保持不变。

旧 `ForwardRoutePlanner` 保留给 verified 离线对照及 build18 连续路线回归；内部
`legacyContinuousOccupancy` 测试入口不暴露给 App 设置或编译条件。
原“空旷时必须画 8 m 线”的断言仅适用于该历史对照，不用于宣称新产品行为正确。
产品三态、交接和新重规划测试集中在 `ObstacleWaypointTests.swift`。

## 反馈

新场景播报消费已提交的 `PathUpdate`，不再与原中心扇区障碍播报同时触发，
也不以“必须有最新蓝色地面”作为入口。距离变化至少 0.5 m 且距上次至少3秒才重复距离提示；
场景改变、新当前目标或当前转向事件不受此距离重复间隔限制。
方向提示复用已有角度迟滞；照片回答、设置播报继续使用独立取消所有权。
找不到绕行路线时提示“暂无绕行路径”，无可见目标时提示“请调整手机方向”。

## 记录与回放

`path.jsonl` prediction/publication 与新产品 `RouteContext` 升为 schema4；新增字段均不要求
旧日志具备。原 `planningPolicy=obstacle_veto_v1` 保留，manifest 的算法修订为
`obstacle_waypoints_v1`。空旷渲染原因是 `front_clear_no_route`，不要统计为意外断线。

- `waypointGuidance`：scenario、obstacleDistance、nextTarget、nextPreparedAt、replanReason、
  targetInView、stationaryTurnSeconds、referenceForward。
- prediction 保存实际 `cameraView`，publication 分别保存候选与提交后的 guidance。
- `goal.id`/`continuity.routeID` 是当前点身份；预备点没有可播报 ID。
- 设置通过 `PathOptions.waypoints` 记录；旧设置缺失该对象时使用新默认值。
- `scripts/replay_route_snapshots.swift` 接受可选 cameraView；`replay_routes.swift` 优先用
  Dev Capture 中的 RGB 内参，否则使用深度内参。两者都缺失时不伪造画面范围。

低频录制缺少的处理帧不能靠插值补成真实障碍观测。回放只验证已有输入的几何与状态，
不声称重现完整实时 300 ms 确认、真实显示连续率或人体行走效果。

## 回归与实机复测

修改前核心基线296项通过；最初两项三态回归在旧实现上失败，证明空旷画线及远障目标仍到8m。
新增确定性测试覆盖空旷、远障间距、近障绕行、预备点重算、到点原子切换、出画、静止转向、
障碍出现/消失、未知栅格、无地面输入、epoch/乱序和参数兼容。语音测试使用合成状态，不播放音频。
最终命令、通过数量、构建和安装证据另附交付记录。

```sh
swift test --package-path Vendor/SpatialCore
swift test -c release --package-path Vendor/SpatialCore
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -xcconfig configs/DevCapture.xcconfig CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
```

实机按以下顺序观察并开启 Dev 采集，不需要冒险穿过障碍：

1. 空走廊：进入状态一次播报，无黄线、目标圈或远向投影。
2. 正前方约3m纸箱：卷尺检查目标在障碍前至少0.5m；靠近2m时进入绕行。
3. 缓慢走近当前点：下一点可在日志改变，画面和转向仍针对当前点；到达后再换段。
4. 停住偏转并保持3秒；对比边转边走。将目标转出画面，观察独立的出画重规划。
5. 用纸箱改变当前段或预备段：分别观察立即改当前路线、只调整下一点。移走障碍后回到空旷状态。

仍待实测：相机相对身体的位置近似、持机俯仰下的可见目标选择、0.35m到达半径、
0.12m静止半径、2.15m退出近障门限、真实语音节奏，以及连续运行与图搜索开销。
本轮不修改传感器或深度模型，也不把合成回归和安装成功记作实走验收。

### 最终离线回归（2026-09-30）

- 核心 Debug、Release：各317项通过（基线296＋本轮21）。
- 模拟器 App：47项通过（含本轮9项播报测试），0失败、0跳过。
- PRTSCore契约8项、Python46项通过；代码清单重新生成，未改变目录树。
- 两个 Swift 回放工具编译通过；18帧明确标识的合成输入产生 clear 12帧、远障3帧、近障3帧，
  并验证空旷无路径和远障目标间距。该分布只是夹具测试，不是真机连续性指标。
- 普通/Dev iOS Release构建与设备安装记录将在成功后追加；以上测试没有启动真机传感器。

本地命令、XCResult与合成回放保存在 `/tmp/prts-route24/`，不将现场影像、密钥或传感器原始文件提交到Git。
