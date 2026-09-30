# Build25 — 重绘、播报节奏与障碍几何

## 日志来源和限制

基线为 main `7ab0f6e`，设备实际测试包为 build24，内嵌源码
`b28d112d1886902cfa2f513ed23e0bbe699be7f6`。2026-09-30 只读复制：

- 14:49:57、14:52:18 两次 Sessions；
- 14:44:34 启动目录中的 Dev Capture（epoch2，187个配对样本，约57.6秒）；
- 采样的capture标记为 `arkit_scene_depth`，187份深度附件和校验和完整，非DA输出。

自动 DIAG 已触及2 GiB总配额：path、render、analysis等记录全部丢弃。
Dev Capture使用独立限额，仍保留低频RGB、深度、原始栅格及当时规划结果。
没有删除设备历史记录，也没有上传现场数据。此次无法还原完整10Hz时序、
精确音频播放次数或完整采集→显示延迟。采样间隔不能插值成额外障碍命中。
原始文件和执行证据仅保存在开发机 `/tmp/prts-route25/`。

## 核实与修复

### 1. 路线／播报反复变化

记录可见近障、远障和空旷的往返切换，以及0.3秒附近连续改变当前目标的片段。
`ObstacleWaypointPlanner`会因最近障碍成分变化切回远障接近路线，
`FeedbackCoordinator`又把目标ID当成音频取消身份；
`ObstacleRouteAnnouncementPolicy`的新目标／状态事件绕过了原有距离播报间隔。
这是代码确认的问题，实际听到多少次无法从本次缺失的音频日志确定。

改动：

- `WaypointScenarioLatch`：近障确认后立即进入；退出近障到远障须持续0.75秒，
  清空路线须连续空旷0.6秒。初始空旷不等待。此期间每帧检查**当前**确认障碍，
  没有延迟碰撞否决，也没有保留已消失的障碍占用。
- 已开始的绕行保持当前目标；另一个更远障碍成为最近成分，不再中途改回接近点。
  到点、受阻、明确出画和静止偏转3秒仍可换点。
- `WaypointVisibilityLatch`：边缘外4%的缓冲用于容忍抖动，轻微出画持续0.35秒才重选；
  明显出画（超过25%扩展范围／位于相机后方）立即处理。
- 若所有拐点在画面外，但已检查线段穿过画面，允许在线段内部插入可见目标；
  不连接跨越拐角的捷径，也不改变剩余绕行折线。
- 绕行优先尝试每侧多8cm的空间；无解则回退原0.50m总宽度。有效既定绕行侧优先，
  不为这点偏好改成另一侧。不是新增必需通行宽度。
- 播报按**语义方向**去重：同侧目标换号不重播、不打断。后续提示至少间隔2.5秒，
  场景变化稳定0.6秒，单独距离变化至少0.5m且间隔4秒。
- 当前转向失效或变为反方向时取消旧句，但不清除限频状态；被限频的方向不会排队，
  下一次仍读取当前目标。短暂缺帧只暂停，不重新武装“一次播报”。

### 2. 路线画进墙／障碍的几何漏洞

`TemporalOccupancyGrid`原先用固定匹配anchor当作障碍几何，并只将中心点写入规划栅格：

1. 相邻当前格可匹配旧anchor，确认计时没错，但几何位置仍在旧中心；
2. 旋转栅格的中心点重采样丢失原格面积；
3. 查询方向改变后，搜索窗口外的确认障碍被丢掉，而窗口外又允许规划。

前两项位置／窗口漏洞已用确定性输入在修改前复现失败。
Dev采样中有6帧细路线与原始占用格相交；原记录没有完整确认模型，不能将这些
全部归因到同一漏洞，也不能把原始短时命中直接当成已经确认的碰撞。

`OccupancyFootprint`现在保存**每个当前确认格**的完整世界坐标正方形，匹配anchor只做计时。
多个测量格落在同一关联bin时也不丢掉任何格的几何。搜索栅格按正方形面积重采样，
最终扫掠检查、接近点间距和已提交路线否决使用同一组世界坐标障碍，含窗口外部分。
不把unknown改为阻挡，不重新引入free-space/地面认证门槛，不修改300ms确认规则。

## 模块与记录

原目录树不变，新增纯Swift模块位于 `Vendor/SpatialCore/Sources/SpatialCore`：

- `OccupancyFootprint.swift`：障碍格面积投影和扫掠相交；
- `WaypointTransitionState.swift`：场景和画面边缘迟滞。

`PathUpdate.confirmedObstacles`保存当前真正用于规划的模型（可选；旧日志缺失为unavailable）。
`ObstacleWaypointGuidance`升为schema2，增加持久的`goalSelectedReason`和`transitionPending`；
路径外层schema4兼容不变，manifest算法修订为`obstacle_waypoints_v2`。
Dev样本仍低频保存，不伪称包含每个实际处理帧。

回放工具增加`confirmedModelFree`，比较脚本区分：

- 原始栅格／深度相交诊断（含未知与尚未确认占用）；
- 所选obstacle-veto策略的确认模型相交；
- 缺少模型的旧记录（unavailable，不能算通过）。

仅后者的已知冲突作为此策略的回放失败条件；verified历史策略保持原检查。
没有把全部unknown栅格错误统计为本策略规划失败。

## 验证与交付

最终命令、数量、回放摘要和设备安装结果见本文件末尾。
修改前核心基线317项通过；两个碰撞回归先失败再修复。
一个旧测试强制要求`world_route_preserved`原因串，现允许几何重采样后重新取得同一目标；
仍要求世界目标位置和绕行侧不变。三项“消失立即清空”测试改为检查模型立即清空、
路线经过0.6秒场景迟滞再清空，并保留旧结果不能恢复路线的断言。

复测建议：站定面向墙／门框缓慢左右转动；原地观察纸箱后移开；缓慢沿同侧绕行。
记录目标ID、选点原因、完整确认模型与语音节奏，确认不会因目标微调重复打断同侧播报。
无需沿穿墙路线行走。完整DIAG恢复需要释放旧记录空间（本轮未擅自删除）。

尚待实机复测：墙体表现、可见线段目标的持机体验、语音限频参数和持续功耗。
本轮修复的是可复现的软件漏洞，不宣称已经解释并消除了现场每一次穿墙显示。

### 本轮离线结果

- 核心Debug、Release各326项通过（原317项＋本轮9项）；契约8项通过。
- Python47项通过。传感器分析器仍有逐字节一致性测试，只剥离新增可选记录字段。
- App首轮51项通过；之后两轮完整串行回归各50通过、1失败：未标定DA录制测试触发10秒排空超时。
  延长的隔离重试未正常收尾，已中止，不计为通过。采集器代码未改、不放宽等待阈值；
  保留此间歇性失败，不能写成App最终全部通过。此前一次Release编译因测试源码在编译期间修改而中止，已重跑通过。
- 相同187帧稀疏回放：目标身份变化36→29；带路线样本126→159；确认模型检查159项，冲突0。
  修改前没有该模型字段，计为不可用，不能宣称原来检查通过。
- 原始深度占用诊断冲突32→7；这些数据包括尚未通过300ms确认的命中，不作为真值。
- 仍有15帧`no_visible_target`（原来2帧），本轮没有为了显示率放过已确认障碍。
  新旧规划模型的几何不同，不能只把“更多线”当成成功。实际可见目标体验仍需复测。

回放命令：编译 `scripts/replay_routes.swift`，以同一个Dev目录分别运行修改前保存的
可执行文件与当前文件，再执行 `python3 scripts/compare_route_replays.py before.jsonl after.jsonl`。
不重新运行传感器、不补造中间帧；回放耗时来自Mac，不作为iPhone性能。

### 构建、提交与设备

- 源码提交 `d0cb1430a2c4e0b008c56e75466f9a0f2aa64038`，包含分开的障碍几何、
  目标稳定性、语义播报、诊断及版本提交，已推送main。
- 普通iOS Release、签名Dev Release构建通过；签名严格校验通过。
  二进制检查确认两者都有修复，只有Dev包含DevCaptureRecorder。
- 2026-09-30 15:28:40已安装启动于Gloria iPhone 15 Pro（iOS27.0），设备确认1.0(25)。
  未卸载、擦除历史记录或自动启动摄像头。App内嵌上述源码commit；本交付文档晚于构建。
- 主路线真实墙体表现与语音体验仍待复测；模拟器录制超时仍为已知未解决项。

[校验记录](WAYPOINT_STABILITY_BUILD25_EVIDENCE.json)。

实际执行：

```sh
swift test --package-path Vendor/SpatialCore --scratch-path /tmp/prts-photo21/core-tests
swift test -c release --package-path Vendor/SpatialCore --scratch-path /tmp/prts-route24/core-release
PRTS_CONTRACTS_ONLY=1 swift test --package-path Vendor/PRTSCore --scratch-path /tmp/prts-photo21/contract-tests
python3 -m unittest discover -s scripts -p 'test_*.py'
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Debug \
  -destination 'platform=iOS Simulator,id=C6C8584E-5D03-4F9A-8B78-DD69BCC4194C' \
  -xcconfig configs/DevCapture.xcconfig CODE_SIGNING_ALLOWED=NO -only-testing:PRTSTests test
xcodebuild -project PRTS.xcodeproj -scheme PRTS -configuration Release \
  -destination 'generic/platform=iOS' -jobs 2 -xcconfig configs/DevCapture.xcconfig \
  PRTS_SOURCE_COMMIT=d0cb1430a2c4e0b008c56e75466f9a0f2aa64038 build
```

构建使用既有DerivedData目录，日志归档在`/tmp/prts-route25/`。普通包省略xcconfig、
增加`CODE_SIGNING_ALLOWED=NO`；App重试另含`-parallel-testing-enabled NO`的完整结果。
首次冷构建因主机负载主动中断，随后使用缓存和`-jobs 2`成功，并非编译错误被忽略。
