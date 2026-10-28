#!/usr/bin/env python3
"""Generate the Chinese review from the replay's actual measured results."""
import json,pathlib,re
H=pathlib.Path(__file__).resolve().parent;ROOT=H.parents[1]
m=json.loads((H/'results/metrics.json').read_text());a=json.loads((H/'results/audit.json').read_text());inv=json.loads((H/'results/inventory.json').read_text())
v=m['all'];d=m['drawing'];dm=d['metrics'];f=m['freshness']
def num(x,n=3):return '—' if x is None else f'{x:.{n}f}'
def table(head,rows):
    cell=lambda x:str(x).replace('|','\\|')
    return '\n'.join(['| '+' | '.join(map(cell,head))+' |','| '+' | '.join(['---']*len(head))+' |']+['| '+' | '.join(map(cell,r))+' |' for r in rows])
def risk(name):
    s=v[name];return [s['near1']['missFrames'],num(s['near1']['missSeconds']),s['near0.5']['missFrames'],s['falseProxy']['1.5'],num(s['falsePerMinute']),s['flips']]
def ms(x):return num(x*1000,1) if x is not None else '—'

parts=[]
parts.append(f'''# PRTS 第二轮算法审查：误报／漏报取舍与地面轨迹

实测日期：2026-10-28；报告完成：2026-10-29（北京时间）。结论与实验针对当前 worktree，不修改产品源码。第一轮报告已读；下文明确撤回或收紧其中的过度建议。

**先说结论**

- 保留占用连续确认、一次未命中重置和恢复 clear 的去抖。撤回“≤0.5 m、6 点即可单帧告警”的上线建议：本批数据的状态误报代理从 **{v['baseline']['falseProxy']['1.5']} 次变成 {v['fast6_1']['falseProxy']['1.5']} 次**，而按 N=3 持续证据口径，近障 clear 漏报代理减少 **{v['baseline']['near1']['missFrames']} 帧、{num(v['baseline']['near1']['missSeconds'])} s**。较严格的 12 点／3 帧档可进入人工复核，不能据此宣称真实误报为零。[R2–R4]
- 危险语音例外增加单独的近距持续证据门，不对每次 blocked 无条件抢播。该档近距事件无障碍语音请求由 **{v['baseline']['near1']['noSpeechEvents']}→{v['speechProof']['near1']['noSpeechEvents']}**，代价是危险语音请求 **{v['baseline']['speechRequests']}→{v['speechProof']['speechRequests']}**、语音误报代理 **{v['baseline']['speechFalseProxy']}→{v['speechProof']['speechFalseProxy']}**；需要听感与标签验收。[R3]
- 最有数据支持的几何修正仍是地面参考更新。B3 的脚下双平面差中位数 **{num(d['footPlaneError']['3']['baseline']['median'])}→{num(d['footPlaneError']['3']['plane004']['median'])} m**，同批状态误报代理没有增加。这是参考一致性改善，非真实地面误差证明。[R3]
- 撤回“默认直接硬加宽到 0.90 m”：先统一到配置的身体宽 0.60 m，并把舒适余量与硬身体约束分开定义。0.90 m 档 blocked 帧 **{v['baseline']['blockedFrames']}→{v['width090']['blockedFrames']}**、状态误报代理 **{v['baseline']['falseProxy']['1.5']}→{v['width090']['falseProxy']['1.5']}**，代价不能忽略。[R3–R4]
- 撤回当前就用“下一段当前帧净空覆盖”替换可见性门的建议：两个替换档位均提交 **0 条路线**。先修地面，再建设能覆盖近身盲区的观测证据；不能把 unknown 偷换成 free。[R3–R4]
- 绘制原型改善贴地和拐角，但**未全面改善抖动，且有显示覆盖损失**：原有 {d['counts']['pathFrames']} 个可绘制分析帧仅保留 {d['counts']['accepted']} 个。完整保留负面结果，不能直接视为生产替换方案。[R3]

**任务 A：数据、口径与七条建议**

**A.1 回放做到了什么，缺了什么**

数据取 B 段 `2026-10-28T11-28-26Z-54463EA9-A18F-4F39-9FEC-576427AAA156`。所有深度逐份验证二进制长度、身份和 SHA256；保留附件内的置信度、位姿、内参、floor priors、参数、版本、方向标志及时间戳。不是把旧 `AnalysisResult` 当新感知结果。[R1–R2]

{table(['段','分析记录','有效深度附件','Dev Capture 视频帧'],[[f'B{e}',inv['epochs'][str(e)]['analysis'],inv['epochs'][str(e)]['depth'],m['annotation']['epochs'].get(str(e),0)] for e in range(1,5)])}

主 DIAG 总计 **{sum(x['analysis'] for x in inv['epochs'].values())} 条分析记录、{sum(x['depth'] for x in inv['epochs'].values())} 份附件、{m['annotation']['total']} 个配对视频帧**。无附件的是 B1 f1/f7/f13，均为 tracking 未正常、且记录声明不期待深度；不是障碍阴性样本。`path.jsonl` 还记录了主 analysis.jsonl 缺失的 B2 f3643、B3 f3751/f3931/f4021；交叉检查 Dev Capture 后，**f3751/f3931 有完整深度、置信度、位姿、内参、参数和 floor priors**，按真实时间戳接回，见 `results/recovered_frames.json`。这不是插值，也不是用旧分析输出顶替感知。最终回放 **{m['frames']} 帧，其中 {m['frames']-m['missingDepth']} 帧从真实深度重算**；仍缺 B2 f3643、B3 f4021，连同初始化无深度帧显式列在 `results/missing_frames.json`。不能把主 DIAG 的 768 条 B3 记录误当全部可恢复观测。[R1–R2]

以下多数是单项消融；第七项明确以 4cm 地面更新档为共同基线。单项收益不可相加，本轮没有把所有推荐值组合成已验证的产品默认配置。

回放链：`DepthObservation → SpatialAnalyzer（含地面、GridBuilder、SurfaceModel）→ PathPredictor → TemporalOccupancyGrid → ObstacleWaypointPlanner → RoutePublicationPolicy → 语音/触觉策略`。所有方案共享同一份重新计算的原始结果；宽度、参考平面和可见性方案各有独立的有状态规划器，确实重新搜索／确认，不只复查旧路线。跟踪中断和 epoch 重置依据 capture 记录执行。实验副本逐帧与生产 `PathPredictor` 对照，**{m['experimentalMatch']}/{m['frames']} 一致**。[R2]

与设备当时存的预测相比，**{m['baselineMatch']}/{m['frames']} 帧的 reason、scenario、路线点一致**（点坐标容差 0.1 mm）。参与回放索引的原日志有路线 {a['recordedPathsInAnalysisIndex']} 帧，基线回放 {v['baseline']['pathFrames']} 帧；匹配结果在 audit.json 中可查。把未恢复缺失点后 0.75 s 及所有不一致帧隔离，共 {a['quarantineFrames']} 帧，主结论仍成立：基线／严格快速档 FN1 为 {a['quarantine']['baseline']['near1']['missFrames']}／{a['quarantine']['fast12_3']['near1']['missFrames']} 帧，FP1.5 为 {a['quarantine']['baseline']['falseProxy']['1.5']}／{a['quarantine']['fast12_3']['falseProxy']['1.5']} 次。隔离不证明反事实状态已经完全消除剩余历史缺失影响；所有数字仍以“只处理已保存观测”的回放条件为前提。[R4]

发布策略使用录制的完成时间、源帧 tracking/版本门及本次候选，未重建并发中的每次 UI 调度、hazard watermark 抢占或 AVSpeechSynthesizer 完成回调。反馈每个发布样本调用一次，假定 `canSpeak=true`；它是**假定音频随时空闲的请求策略模拟，不是实播声音**。当前反馈源码含工作区原有修改，不能冒充设备录制版本的音频。绘制也只在保存的分析帧计算，非真实屏幕逐帧录像。B 为测量深度；本轮没有单目尺度冲突样本。[R1–R2]

**A.2 可计算指标与边界**

固定审计身体带为相机投影前方总宽 0.60 m；障碍格方形与带边界相交即纳入，距离用格近缘的前向距离，不是光轴深度或欧氏距离。高置信点是生产代码 `confidence == 2`、有效测距范围内、按保存 samplingStep 采样的点；高度分类沿用这次 `SpatialAnalyzer` 的地面及身体高度。四邻域障碍格（包括单格不足 3 点的格）合簇，但只累计身体带内的支持点。[R2，`rawEvidence`]

- **FN1/FN0.5**：在相应距离内，同一簇每帧至少 6 个高置信采样点，相邻保存帧间隔 <0.15 s、世界簇中心匹配 ≤0.25 m，连续达到 3 帧后，输出仍为 clear 的帧数、相邻有效时间间隔之和、受影响事件数。缺失、跟踪中断及 epoch 都断开；unknown 单列，不能算 clear。3 帧在本数据通常跨约 0.2 s，不是 300 ms 占用确认的同义词。[R2–R3]
- **FP-W**：从 clear 进入任一种障碍状态的事件，在随后 W 秒内没有上述 3 帧持续支持（支持搜索扩展到前方 4 m），且窗口末尾 0.3 s 没有至少 6 点的簇。主表 W=1.5 s，同时给 1/2 s 敏感性；窗口遇缺口或尾部不足记 censored，绝不记误报。每分钟用有效相邻观测间隔总和 **{num(v['baseline']['observedSeconds'])} s** 作分母，非整次 App 启动时间。[R3]
- **语音 FP**：对危险语音请求时刻应用同一未来窗口判据；另统计请求总量。它的窗口随播报时刻移动，晚播可能因前面的支持已消失而被标为 FP，不能仅凭这个指标排名等待参数。[R3]
- **抖动**：连续有效样本之间 clear↔任一障碍状态的切换次数，不是 near↔blocked 切换总数，也不是切换对数。路径／语音状态分开。[R3]
- **时延**：对应持续事件首次原始合格观测至首次告警发布／语音请求的差；事件开始前同一未恢复 clear 的告警已经存在则记 0；未告警事件单列，不能从延迟分布中悄悄删除。无障碍语音事件与“没有升级到近障/blocked 级”分别计数。[R3]

这些全是**代理，不能直接叫真实漏报率/误报率**。高传感器置信度不保证物体真实，错误地面可把地面判成障碍；同一相机坐标带不等于实际身体行进带。动态物体离开、用户成功避开、手机转开或遮挡都会制造“证据消失”；持久鬼影反而可能通过持续性指标。宽度/参考方案改变路线朝向，固定相机带会产生额外评估偏差。空间匹配会合并相邻物体、因地面跳变拆分同一物体。严格 N=3 会排除真实但短暂的横穿障碍；因此必须报告敏感性，不能只挑最有利的 N。[R2–R4]

尤其是：这个 FN 代理根本抓不到“深度自己没有测到物体”或“没有可用地面/grid，因而没生成原始障碍簇”的漏报。那些帧未进入合格障碍分母，不等于安全。必须标注背景/原始证据为空的帧，不能只标本代理已找到的事件。

{table(['持续门 N','≤1m 合格帧','基线 clear 帧','≤0.5m 合格帧','基线 clear 帧'],[[n,a['rawNSensitivity'][f'N{n}_D1']['baseline']['qualified'],a['rawNSensitivity'][f'N{n}_D1']['baseline']['missFrames'],a['rawNSensitivity'][f'N{n}_D0.5']['baseline']['qualified'],a['rawNSensitivity'][f'N{n}_D0.5']['baseline']['missFrames']] for n in [1,2,3,4]])}

主口径有 ≤1m 持续事件 **{v['baseline']['near1']['episodes']} 个/{v['baseline']['near1']['qualifiedFrames']} 帧**，≤0.5m **{v['baseline']['near0.5']['episodes']} 个/{v['baseline']['near0.5']['qualifiedFrames']} 帧**。基线从首次原始观测到事件结束始终 clear 的事件为 **{v['baseline']['near1']['entirelyMissedEvents']} 个**；FN1 的 {v['baseline']['near1']['missFrames']} 帧来自 {v['baseline']['near1']['affectedEvents']} 个事件，不能全部归为短延迟。包含恢复的 B3 f3931 后，f3919–f3937 的持续证据才连通，形成了这个整段 clear 的事件，说明逐帧完整性直接影响结论。第一轮的“原始近障而 clear”仍不能直接升级成真实漏报事件数。[R1、R3]
''')

parts.append('''**A.3 建议 1：近障快通道——撤回单帧弱支持，保留确认主链**

占用仍按生产 0.30 s 确认、一次未命中即清计时；仅增加警告分支，不用它搜索左右绕行。快速分支用最近最多 3 份保存观测、最长 0.26 s、空间匹配 0.25 m，告警保留 0.2 s；缺失不会贡献命中。生产 association gap 是 0.75 s，并不是架构历史段落写的 0.20 s；不要用旧文档覆盖当前代码。[R2、R7]

'''+table(['档位','FN1帧','FN1秒','FN0.5帧','FP1.5次','FP/分钟','切换次'],[[label]+risk(name) for name,label in [('baseline','原链'),('fast6_1','6点；≤0.5m单帧，≤1m二取三'),('fast6_2','6点；全部二取三'),('fast12_3','12点；全部三取三')]])+f'''

基线／严格档的状态时延 p95 为 **{ms(v['baseline']['near1']['stateLatency']['p95'])}／{ms(v['fast12_3']['near1']['stateLatency']['p95'])} ms**。严格档减少 **{v['baseline']['near1']['missFrames']-v['fast12_3']['near1']['missFrames']} 个早期 clear 帧**，仍留 **{v['fast12_3']['near1']['entirelyMissedEvents']} 个整段 clear 事件**；时延只覆盖两档各 {v['baseline']['near1']['stateLatency']['n']} 个已告警事件。危险语音请求仍为 {v['fast12_3']['speechRequests']} 次；它本身没有绕过语音门。宽松档的状态 FP1/FP2 为 {v['fast6_1']['falseProxy']['1']}/{v['fast6_1']['falseProxy']['2']}，基线为 {v['baseline']['falseProxy']['1']}/{v['baseline']['falseProxy']['2']}，增加的代价不是只出现在单个窗口选择。[R3]

这里的状态 FP 也不等于用户听到的假警报。沿用语音限频后，单帧宽松档危险语音请求仅 {v['baseline']['speechRequests']}→{v['fast6_1']['speechRequests']}，语音 FP 为 {v['baseline']['speechFalseProxy']}→{v['fast6_1']['speechFalseProxy']}。这正说明现有限频确实在挡短暂状态噪声；不能用状态计数冒充听觉体验。[R3]

**推荐：严格档作为待标注候选，发布默认暂留原链；明确撤回单帧档的上线建议。** 如果真值证明短横穿被 N=3 排除，应改进空间/运动证据，而不是把本表当成短障碍不重要的证明。严格档 FP 少一次也可能是提前延长同一个事件、改变事件边界，不能解释为传感器变准。[R3–R4]

**A.4 建议 2：危险语音升级——必须有近距证据，不能只认 scenario 升级**

原策略来自 `PRTS/Feedback/ObstacleRouteAnnouncementPolicy.swift:30–63`：后续场景等待与播报间隔。三档都保留普通恢复/重复语音的限频。实验升级事件最短间隔取 0.75 s，同级不连续抢播；“立即”指可绕过普通等待，不等于绕过所有限频或正在播音。[R2、R7]

{table(['档位','≤1m无任何障碍语音事件','无近障/blocked升级事件','危险请求','语音FP1.5','已覆盖事件语音时延p95(ms)'],[[label,v[name]['near1']['noSpeechEvents'],v[name]['near1']['noCloseSpeechEvents'],v[name]['speechRequests'],v[name]['speechFalseProxy'],ms(v[name]['near1']['speechLatency']['p95'])] for name,label in [('baseline','原链'),('speech0','所有危险升级绕过等待'),('speechProof','仅12点/3帧近距证据允许升级')]])}

三个档位的规划状态 FN1/FP1.5 均为 **{v['baseline']['near1']['missFrames']} 帧/{v['baseline']['falseProxy']['1.5']} 次**；上表变化发生在反馈层。≤0.5m 无障碍语音事件：原链 {v['baseline']['near0.5']['noSpeechEvents']}，证据档 {v['speechProof']['near0.5']['noSpeechEvents']}。额外试验“仅等 0.2 s 就允许全部升级”，危险请求 {v['speech020']['speechRequests']}、语音 FP {v['speech020']['speechFalseProxy']}、≤1m 无语音事件 {v['speech020']['near1']['noSpeechEvents']}，不优于证据门。[R3]

**推荐证据档进入受控听感测试；撤回对任意 blocked 的无条件抢播。** 即便证据档，语音误报代理仍增加 1 次，不能直接上线。把已观察危险等级与已成功播报等级分开仍是正确的状态机修复；备用 `FeedbackPolicy.swift:40–44` 的被冷却阻止却更新 lastSeverity 问题，本次默认航点链没有使用，不能声称在 B 上带来额外收益。未测量近距退出 1.25m/持续 0.5s 迟滞和真实取消旧方向的声学效果，不把它们混入该表。[R2–R3、R7]

**A.5 建议 3：地面更新——更新已确认局部参考，保留世界水平意图与障碍计时器**

实验副本只在 `groundConfirmed=true` 时重设参考。两个档位分别在脚下高度差超过 4/12 cm 或法向差超过 3° 时更新；保持路线、目标和预备段的 x/z，改 y，并让完整身体扫掠重新进入现有阻挡/重规划逻辑；不重置障碍关联计时。初始未确认平面只作暂时参考，后续可替换。并未实现第一轮另提的“8°大改动暂停”完整产品生命周期，所以不宣称其效果。[R2]

{table(['档位','FN1帧','FP1.5','切换','blocked帧','有路线帧','重设次数'],[[label,v[name]['near1']['missFrames'],v[name]['falseProxy']['1.5'],v[name]['flips'],v[name]['blockedFrames'],v[name]['pathFrames'],a['widthAndPlane'][name]['rebases']] for name,label in [('baseline','首次永久锁定'),('plane004','4cm/3°'),('plane012','12cm/3°')]])}

以下只比较当前确认地面的帧，数值是 `abs(currentPlane.height(planningPlane.project(camera)))`，不是世界原点处两个 offset 的差。[R3]

{table(['段/确认帧','原链中位/最大(m)','4cm档中位/最大(m)','12cm档中位/最大(m)'],[[f"B{e}/{d['footPlaneError'][str(e)]['baseline']['n']}"]+[f"{num(d['footPlaneError'][str(e)][n]['median'])}/{num(d['footPlaneError'][str(e)][n]['max'])}" for n in ['baseline','plane004','plane012']] for e in range(1,5)])}

**推荐 4 cm/3°，但保证原子重投影＋碰撞复核后才恢复方向。** FN 两档都没有减少，FP 主代理没有增加；改善的是坐标一致性和部分可提交路线，不应包装成已减少真实碰撞。B1 原参考本来较好，中位误差并非各段都下降。坡道、台阶、参考失效后的重建仍需新数据。[R3]

**A.6 建议 4：反馈新鲜度——区分新分析与有效障碍检查**

`Snapshots.swift:263–273` 只用最新相机帧新鲜度授权航点反馈；`PathPresentation.make` 也对 obstacleVeto 放宽路线年龄。用真实 capture 时间重查记录中已完成的回放结果：最新分析源年龄最大 **{num(f['ages']['max'])} s**，没有重现分析完全停顿；但只把“当前存在可分类地面且有高置信深度点”算有效障碍检查，年龄最大 **{num(f['successfulEvaluationAges']['max'])} s**。后者是有分析但缺少有效模型的间隔，不是 CPU 卡顿证据。[R3、R7]

{table(['源年龄上限','仅按最新分析：被挡capture样本','按有效检查：被挡样本','其中clear','其中有路线方向许可'],[[f'{t}s',f['profiles'][str(t)]['suppressedTicks'],f['successfulEvaluationProfiles'][str(t)]['suppressedTicks'],f['successfulEvaluationProfiles'][str(t)]['suppressedClearTicks'],f['successfulEvaluationProfiles'][str(t)]['suppressedDirectionTicks']] for t in [.15,.25,.5]])}

分母是 **{f['ages']['n']} 个合格 capture 样本**，不是用户听到的次数。这个门不改变规划器的 FN1/FP1.5（仍 {v['baseline']['near1']['missFrames']} 帧/{v['baseline']['falseProxy']['1.5']} 次）；它撤销 clear/方向许可，输出应是“证据过期/未知”，绝不能转成“有障碍”。所以不能把 abstention 算作修复漏报，也不能声称不影响可用性。[R3]

`audit.py` 还在每段实际 clear／有路线的捕获窗口，注入 0.3s 和 1s 分析暂停，共 **{len(a['stallExperiments'])} 个重放窗口**：相机仍继续，最新已发布路线保持，按每个真实 capture tick 检查门是否到期；明细见 audit.json。相对于“成功检查后立即停止”的理想时刻，0.25s 门最多让 1s 暂停的后 0.75s 失去许可；这段是合成故障，不是现场故障发生率。[R4]

**推荐 0.25 s，但时钟必须来自成功障碍检查的 source timestamp。** 同时输出 unknown 和取消旧方向，不重播“看不清”造成另一种噪声。0.15s 会多拒绝正常工作间隔，0.50s 则容忍更久旧证据。epoch/参数/坐标代次保持原硬门；单目尺度冲突仍属本次无样本，不能给出现场误报/漏报数字。[R3–R4]

**A.7 建议 5：宽度统一——物理身体约束与舒适偏好分开**

以下是分别重跑整条确认/搜索链的结果；碰撞项还把近身连接纳入扫掠，使用该帧确认方格的精确碰撞方法。[R2–R4]

{table(['硬总宽','FN1帧','FP1.5','blocked帧','有路线帧','按0.60m复核冲突帧','按0.90m复核冲突帧'],[[label,v[name]['near1']['missFrames'],v[name]['falseProxy']['1.5'],v[name]['blockedFrames'],v[name]['pathFrames'],a['widthAndPlane'][name]['collision060'],a['widthAndPlane'][name]['collision090']] for name,label in [('baseline','0.50m'),('width060','0.60m'),('width090','0.90m')]])}

0.60m 消除本回放原有的 **{a['widthAndPlane']['baseline']['collision060']} 帧身体几何冲突**，代价是 blocked 增加 **{v['width060']['blockedFrames']-v['baseline']['blockedFrames']} 帧**、危险语音 **{v['baseline']['speechRequests']}→{v['width060']['speechRequests']} 次**、语音 FP **{v['baseline']['speechFalseProxy']}→{v['width060']['speechFalseProxy']}**。0.90m 的 FN1 少 {v['baseline']['near1']['missFrames']-v['width090']['near1']['missFrames']} 帧（{num(v['baseline']['near1']['missSeconds']-v['width090']['near1']['missSeconds'])}s），并消除对应包络冲突，但使状态 FP 增加 **{v['width090']['falseProxy']['1.5']-v['baseline']['falseProxy']['1.5']} 次**、blocked 增加 **{v['width090']['blockedFrames']-v['baseline']['blockedFrames']} 帧**。有路线帧数非单调：宽度会改变绕行侧、目标可见性、路线驻留和告警时长，不能只看绝对有路线数量。[R3–R4]

**推荐当前配置下先用 0.60 m 硬身体宽度，舒适余量另作为可退让搜索偏好；撤回默认强制 0.90 m。** 这是对 sideMargin 产品语义的明确改写，不是悄悄降低一个已定义的安全要求。若 sideMargin 被规定为必需安全裕度，就必须保持它并接受更多不提交，而不能宣称 0.60m 满足该要求。身体实际宽度、持机偏心及定位误差尚无真值，0.60m 不是安全认证；0.90m 的拒绝也未被证明全是假拒绝。固定 0.60m 审计带对宽包络的舒适区告警不利，需人工单列“真障碍但只在舒适区”的标签。[R4]

**A.8 建议 6：方向迟滞——减少细小角度催促，不改变障碍识别**

回放采用实时分析位姿计算 heading，保留方向稳定门、目标 ID 变化重置和对准确认；这里的请求频率是发布采样频率，不冒充当时硬件脉冲日志。两候选改变未锁定状态的入向阈值为 8°/12°，已对准状态的重启仍为 12°，对准阈值 5°、确认 0.3s。[R2]

{table(['初始入向阈值','左右脉冲请求','其中|θ|<12°','障碍FN1帧/FP1.5次'],[[label,a['haptics'][name]['turnPulses'],a['haptics'][name]['smallAnglePulses'],f"{v['baseline']['near1']['missFrames']} / {v['baseline']['falseProxy']['1.5']}（规划不变）"] for name,label in [('baseline','现状>5°'),('entry8','8°'),('entry12','12°')]])}

**推荐 12°/5°。** 小角度请求消失，代价是主动要求修正的角度区间缩小；没有身体朝向与转向完成真值，不能称减少 {a['haptics']['baseline']['smallAnglePulses']} 次“真实错误振动”。语音“直走”应只在已播转向后、对准确认且当前危险/路线仍有效时发一次；本次未新增这段产品语音，因此不把它的收益计入数字。对准不等于前方畅通。[R2–R4]

**A.9 建议 7：可见性——暂不替换为当前帧身体净空硬门**

为不让旧平面混淆该消融，三个档都采用已述 4cm/3° 地面修正。候选允许终点出画，取消出画强制重选；但提交前沿下一段每 5cm、横向整个身体宽度每 5cm 取样，要求原始当前 grid 的 candidate 覆盖。candidate 在生产中包含整段身体高度的可见净空检查，比“图像里看到地面”强得多。[R2、R7]

{table(['提交条件（同为4cm参考）','FN1帧','FP1.5','blocked帧','no_visible_target帧','有路线帧'],[[label,v[name]['near1']['missFrames'],v[name]['falseProxy']['1.5'],v[name]['blockedFrames'],v[name]['noVisibleFrames'],v[name]['pathFrames']] for name,label in [('plane004','保留目标FOV门'),('visibility060','下一段0.6m，覆盖≥80%'),('visibility100','下一段1.0m，覆盖≥95%')]])}

这两个原型的提交候选覆盖统计均为 0；导出的 coverage 还会保留上次尝试值，**不能把它的样本数当搜索次数**。近身区域、身体高处及地面缺确认，使这批当前帧 candidate 证明无法满足下一段许可。在未知可搜的 obstacle-veto 产品上突然加入该门，会造成严重不可用性。这里 blocked 主要是 `no_visible_target`，当前文案是“转动手机”，不是全都播“无法绕行”。[R2–R4]

**推荐目前保留目标 FOV 门，撤回立即替换建议。** 长期可把世界目标保持与图标可见性分开，但必须先引入有时效、有遮挡更新的局部观测覆盖，证明覆盖率确有提升后再消融。不能用“放宽到很低覆盖比例”掩盖全零证据，更不能无条件删除门。[R3]
''')

parts.append(f'''**A.10 可执行人工标注方案**

已交付 `experiments/astra/results/annotation.html`、`annotation_manifest.csv` 和 `annotation_frames/`。已解码全部 **{m['annotation']['total']} 张**；逐视频帧数与 samples.jsonl 一致，解码 PTS 与索引最大偏差 **{num(max(x['maximumPTSDiscrepancySeconds'] for x in json.loads((H/'results/video_check.json').read_text()))*1000,3)} ms**。这些 JPG 来自原 MP4，没有画预测路线，没有伪造或补插帧。[R5]

样本库较小，建议**全量 {m['annotation']['total']} 帧由两名标注员独立标注，共 {m['annotation']['doubleReviewDecisions']} 份判断，再由第三人裁决**。先随机打散不同片段给两人，隐藏算法输出；对同一疑似事件允许回看视频前后文，标签仍绑定当前 frame ID，不向两个采样点之间插真值。现有研究分层为 raw_near_clear {m['annotation']['strata']['raw_near_clear']}、output_alarm {m['annotation']['strata']['output_alarm']}、background {m['annotation']['strata']['background']} 帧，UI 不显示分层。若人力不足，先全取前两层和所有候选分歧/切换邻域，再在剩余连续片段随机抽取背景；记录每层抽中概率 π，用 1/π 加权，不能只标错误案例。[R3、R5]

{table(['字段','允许值/含义'],[['sample_id,epoch,frameID,timestamp','与深度、路径和视频一一对应'],['video,pts_seconds','原视频及源PTS，不用jpg文件名猜时间'],['annotator,adjudication','独立标注员及第三人裁决'],['label_obstacle_1m,label_obstacle_05m','yes / no / uncertain / not_visible'],['body_band_visible','身体通行带可见性，手机朝向是否能代表身体方向'],['distance_certainty','independent_measurement / visual_estimate / uncertain'],['obstacle_kind,bbox_xyxy','物体类别与原始图像框，包含悬空物、细杆、地面误识别'],['reason,episode_id','遮挡、反光、距离边界、是否移动物；合并同一事件']])}

关键限制：**单张 RGB 不能保证“确实在 1 m 内”的米制真值。** 有明确独立测量/已知尺度与可复核相机几何时才进入 gold 距离标签；不能把被审计的深度或同一个地面平面的测距再当独立真值。边界距离、身体朝向或可见性不确定的帧进入 uncertain，不填 no。旧视频无法复核的场景需要现场距离标尺/独立测距及同步视频补采。对输出“有障碍但在 1m 外”应另标远距障碍，不能拿正确远距提示当近距假阳性。

`score_labels.py adjudicated.csv` 已可执行：按**完全相同 frame ID**，以非 clear 且输出距离 ≤1m 为近距预测阳性，算 TP/FP/FN/TN；unknown 的真实阳性计入端到端召回分母，另外报告 abstention。不确定真值排除且公布数量。加 `--gold-only` 只计独立米制依据的裁决；默认包含视觉估计，只能用于探索性评估。原“任何障碍状态漏报”代理与这个严格近距分类口径不同，不能用同一个名字混报。语音需另以事件 ID、真实请求/开始时间标记；现场无录音时仍只能报告请求级 precision/recall。[R5]

在预期 precision/recall=0.9、95% 近似区间半宽 0.05 的独立二项样本假设下，`ceil(1.96²×0.9×0.1/0.05²)` 为 **{m['annotation']['binomialN90pctPlusMinus5pct']}**；最坏 p=0.5 为 **{m['annotation']['binomialNWorstPlusMinus5pct']}**。召回要有这么多独立真实阳性事件，精确率要有这么多独立告警事件，不能用连续视频的 {m['annotation']['total']} 帧抵数。先完成全量标注，按连续障碍事件/行走片段聚类统计，再确定需要补多少；不足时报告宽区间，不宣称达到该精度。扩充样本优先正/负各 50 个独立事件做先导，随后补到目标类别数量；按采集日/路线做分组验证，不能把相邻帧随机拆进训练和测试。只有四个 epoch，现阶段 bootstrap 也不能制造跨环境置信度。[R3、R8]

B4 只有 **{m['annotation']['epochs']['4']} 个视频帧**，因此旧视频全量标注最多提供配对可见子集上的真值性能，不能代表整个 B4 或整套 {m['frames']} 帧；需明确报告覆盖率，补采缺覆盖片段。当前 CSV 留空，**本报告没有任何真实 precision/recall 结果**。[R1、R5]
''')

parts.append(f'''**任务 B：地面轨迹的数学管线、根因与原型**

**B.1 当前管线**

深度以相机坐标反投影：`((u-cx)d/fx, -(v-cy)d/fy, -d)`，再由 `RigidPose.world` 到 ARKit 重力世界坐标。地面 `n·X+b=0`，`GroundBasis` 的 origin 是相机在平面的正交投影，right/forward 是切平面正交基。搜索在该局部 x/z 栅格上完成，再转成世界 V3；路径点、目标、referenceForward 都是世界量，目标 ID/路线状态跨帧保持。不是每帧把所有路线锁到相机前方。[R7：`Geometry.swift:14–21,37–48,86–114`]

默认链 `TemporalOccupancyGrid → ObstacleWaypointPlanner` 使用首次锁定规划平面。clear 场景没有路线；近/远障碍时只发布当前目标段，预备段不画。`RouteProgressWindow.remaining` 给路线入口留约 20cm 的尾巴；`PathPresentation.make` 在每次展示时又把**当前脚下投影连接到路径首点**。因此近身连接会跟最新相机位姿更新，而路线主体可保持世界锚定。[R7：`ObstacleWaypointPlanner.swift:77–90,96–101,140–156`；`RouteContinuity.swift:213–247`；`PathPrediction.swift:119–148`]

`PathDrawing.meshes` 对 approach 和 path 分别生成宽 0.036m（未锁定连接 0.024m）的逐段矩形，每段两个三角形、六个顶点，沿单个 plane.normal 抬高 0.025m；端点另画 24 段圆环。没有公用角点连接，也没有弧长平滑。旧 `RouteProjection` 的平面延长线是另一个可视层，默认 drawDistance=20m，但当前航点分支的录制预测没有这个 projection；不能把历史文档的“20m延长线”误认为本次主路径。[R7]

`Snapshots.activePath` 以最新 capture pose 和 presentation gate 生成展示。Metal 每次 draw 都用最新 `worldToCamera` 与内参投影：`z=-p.z; u=fx px/z+cx; v=-fy py/z+cy`，加半像素，再经过与 RGB 相同的方向/fit 变换；shader 保留齐次 w=z 供近面裁剪。`ProbeRenderer.updatePathBuffer` 的 key 含 validatedFrameID、所有点及 approach.first，分析更新或脚下连接改变会重建网格；主体重投影无须重规划。[R7：`Snapshots.swift:253–261`，`ProbeRenderer.swift:179,257–265,381–403`，`ProbeShaders.metal.txt:55–67`]

`PredictedGeometry.swift` 是单目预测的 display-only 分支，使用原生地面并把 candidate 改 unknown；本批 B 的测量深度走 `SpatialAnalyzer`，不应把两条支路混作本次误差来源。`ROUTE_PROJECTION.md` 已注明历史设计，部分早期阈值与当前代码不同。[R1、R7]

**B.2 能证实的根因；不能证实的猜测**

1. **平面外推错误是量级最大的原因。** 固定倾斜平面的误差约随水平位移增长：小角度下 Δh≈Δb+Δnₓ·Δx+Δn_z·Δz。世界锁定消除了抖动，却能把错误高度稳定地保留。A.5 已复现 B3 脚下最大 {num(d['footPlaneError']['3']['baseline']['max'])}m 的参考差。不是加 2.5cm lift 能修的。位置：`TemporalOccupancyGrid.swift:45–63`、`ObstacleWaypointPlanner.swift:38,151`。[R3、R7]
2. **近身连接与保留尾巴构成折返钩。** 脚→身后保留点→前方路线，夹角可接近反向；而 approach/path 各画一个矩形，接缝既没有 miter 也没有 round join。在本次原型可输出的共同帧集合，原始最大折角的每帧中位数 {num(dm['beforeMaxAnglePerFrame']['median'],1)}°、p95 {num(dm['beforeMaxAnglePerFrame']['p95'],1)}°。这是包含连接线的中心线，不表示每个规划弯道都这么尖。位置：`RouteContinuity.swift:237` 的 `matched-0.2`，`PathPrediction.swift:148`，`PathDrawing.swift:65–87`。另对全部 {d['counts']['pathFrames']} 个输入帧的原始角点按原平面 lift 和对应相机投影后，>150° 的 {a['drawingVisibility']['sharpVerticesAbove150']} 个角点中，位于画面内的只有 {a['drawingVisibility'].get('sharpVerticesInImage',0)} 个。因此折返是世界几何缺陷，其对本批可见坏线的贡献**尚未证实**；后文折角改善不能直接冒充屏幕观感改善。[R3–R4]
3. **空间采样稀疏不均，切换是离散事务。** 同一共同帧集合，原线段长度中位 {num(dm['originalSegmentLengths']['median'])}m、最大 {num(dm['originalSegmentLengths']['max'])}m；这对直段本身没有几何误差，但使拐角处理、视觉淡出与时间对应难以按点下标做。`commit` 直接换目标/折线、出画重选、arrival/preview 提升均可造成跳变；不能用把前后顶点逐项平均来修，因为点数和语义都可能变了。[R2–R3、R7]
4. **遮挡被有意关闭。** 默认路线用 noDepth，worldFragment 直接返回颜色，没有把路线深度与 sceneDepth 作遮挡比较。好处是 noisy floor 不会交替遮线；代价是线可透过真实物体显示，视觉上像悬浮/穿物。位置：`ProbeRenderer.swift:244,261` 和 shader:67。没有实际遮挡真值，本次不能给“多少帧真实穿物”的数字；原型的原始格相交数只是另一个风险代理。[R7]

没有找到足以证实的通用“相机/世界坐标混用”错误：world→camera 的轴约定、像素中心与齐次近面处理在这条管线一致。**透视下屏幕宽度变化也不是本身的 bug**：现有 ribbon 已是等世界宽度，像素宽约随 1/z 变化；把所有屏幕距离强行画成同像素宽，会改变其物理含义。当前真正欠缺的是角连接、抗锯齿/远端呈现以及正确的地面参考。对这些不要凑一个不存在的“宽度投影公式错误”。[R7]

**B.3 已实现的离线方案及数学约束**

完整原型见 `experiments/astra/Drawing.swift`，在本轮深度重跑的每一条基线路线上执行。

**弧长与受约束圆角。** 按 `sᵢ=Σ||Pᵢ−Pᵢ₋₁||` 定义弧长，最终按 Δs=0.05m 重采样；执行顺序是入口修剪、局部圆角，再对候选曲线重采样。连接线先尝试修剪到入口段上的最近投影，避免倒退连接；保留所有后续拐点，不跨不同目标 ID 平滑。每个可圆角转折取距离 a=min(候选trim,相邻边长的1/4)，入口 A、角点 B、出口 C，使用二次 Bézier `Q(t)=(1−t)²A+2t(1−t)B+t²C`。端部与原直段切向一致；它并不保证 C² 连续，因此不声称是车辆级回旋线路径。候选 trim 按 0.12/0.06/0m 回退。这里选择局部二次曲线而不是无约束 Catmull–Rom：更容易界定每个角部的修改范围，且任何样条仍必须重新查碰撞。[R2]

二次曲线的分段弦误差上界为 `||A−2B+C||/(4 n²)`，采样到 ≤1mm 后再生成最终折线。最终渲染的每一条线段重新做扫掠圆盘—确认方格精确相交测试，半径 `max(path.requiredWidth,bodyWidth)/2+1mm`。所以不是“只查控制点”；原型实际画的是被检查的分段折线。所有候选失败就撤销该帧地面线，绝不把未查过的旧平滑线当当前结果。[R2、R6]

同时限制相对原规划/连接中心线的水平偏移 ≤0.05m。每 0.01m 取样、留 0.005m 的 Lipschitz 余量，给两取样点之间的偏差留界；平面修正的垂直位移不混进水平偏差。入口修剪不满足约束时，回退未修剪的连接，再尝试较小圆角；宁可留下难看的折角，也不越过偏差/碰撞约束。[R2]

**局部地面与世界时间滤波。** 仅接受确认地面/其有效 retained reference。固定 x/z、由 `y=−(b+nₓx+n_z z)/n_y` 求局部高度；不采用旧平面对相机的正交投影去拉动世界水平目标。参考距最后真实确认 ≤2s、相机位移 ≤1m；失效后隐藏地面线，不能回弹到首次错误平面。路线消失、ID 变化或帧间隔 >0.25s 时不继承滤波。[R2]

同 ID 下按世界曲线最近点关联，只滤高度：`yₜ=α y_measure+(1−α)y_prev`，`α=1−exp(−Δt/0.15)`；关联三维位移 >0.08m 时不混合。过滤后再按弧长取样、再查偏差和全线碰撞。这避免相机坐标滤波把真实相机运动误当路线抖动；但会引入地面更新滞后，不能承诺同时最小化地面误差和时间变化。[R2]

对坡道/局部起伏，更完整的后续方案是在世界水平瓦片内拟合加权局部平面或高度场 `h(x,z)`，法线由 `(-∂h/∂x,1,-∂h/∂z)` 归一化求得；只用有观测支持的邻域，不跨台阶/缺测插值。台阶或地面多值时保留断点、作为规划条件。**本次实现的是局部单平面，不是已经验证的高度场**；B 没有独立坡度/台阶真值，不给高度场改善百分比。

**带状网格。** 中心点抬高 0.025m，侧向 `b=normalize(t×n)`，两边为 `P±0.036/2·b`。原型生成等宽段矩形和外侧固定半径 round fan（每段角度≤15°），而非原来接缝裸露的独立矩形。一般 miter 可用 `m=normalize(b_prev+b_next)`、延伸量 `w/(2 m·b_next)`，分母很小时必须转 bevel/round，不能无限伸尖。原型选择 round；内侧三角形仍有重叠，远端透明混合可能更深，这是待生产 tessellator 合并边界的问题。圆环沿同一局部地面重建。[R2]

远端透明度采用距离 2–4m 的 smoothstep 淡出：`u=clamp((d−2)/2,0,1)`，`alpha=1−u²(3−2u)`。为防远端锯齿应使用覆盖抗锯齿；不把世界宽度直接偷偷钳成同像素宽。遮挡建议另做高置信 sceneDepth 比较，只有前景深度显著更近时淡出，并把地面噪声容差与真实障碍遮挡区分。**深度遮挡 shader 尚未实现或真机测量**，所以该建议不计入本轮改后收益。[R2、R8]

**B.4 改前／改后实测——包含退化项**

原型输入 {d['counts']['pathFrames']} 个有路径分析帧，保留 **{d['counts']['accepted']}（{num(100*d['counts']['accepted']/d['counts']['pathFrames'],1)}%）**；{d['counts']['local_ground_unavailable']} 帧缺有效局部地面、{d['counts']['body_sweep_rejected']} 帧未通过身体扫掠/候选约束而不画。不能把删除的帧误计为零误差。圆角选择：0.12m {d['counts'].get('radius0.12',0)} 帧，0.06m {d['counts'].get('radius0.06',0)} 帧，退回折线 {d['counts'].get('radius0',0)} 帧。[R3]

以下角度使用共同的 {d['counts']['accepted']} 帧；曲率是等弧长离散 `κᵢ≈θᵢ/((ℓᵢ₋₁+ℓᵢ)/2)`，不是原折线角点的解析曲率（后者不有限）。地面误差在同一组水平站点成对计算；线宽 lift 不计入中心线误差。时间差只比较同时可用的相邻曲线，去掉两端各 0.3m；用双向最近曲线距离的 RMS，排除相机运动造成的假屏幕位移。[R3]

{table(['量/共同样本','改前','改后'],[
['每帧最大折角，中位/p95(°)',f"{num(dm['beforeMaxAnglePerFrame']['median'],1)}/{num(dm['beforeMaxAnglePerFrame']['p95'],1)}",f"{num(dm['afterMaxAnglePerFrame']['median'],1)}/{num(dm['afterMaxAnglePerFrame']['p95'],1)}"],
['离散曲率p95/最大(1/m)',f"{num(dm['beforeCurvature']['p95'])}/{num(dm['beforeCurvature']['max'])}",f"{num(dm['afterCurvature']['p95'])}/{num(dm['afterCurvature']['max'])}"],
[f"对当前确认平面，中位/p95(m)，{dm['pairedBeforeGroundError']['n']}点",f"{num(dm['pairedBeforeGroundError']['median'],4)}/{num(dm['pairedBeforeGroundError']['p95'],4)}",f"{num(dm['pairedAfterGroundError']['median'],4)}/{num(dm['pairedAfterGroundError']['p95'],4)}"],
[f"对邻近原始地面点，中位/p95(m)，{dm['pairedBeforeObservedGroundYError']['n']}点",f"{num(dm['pairedBeforeObservedGroundYError']['median'],4)}/{num(dm['pairedBeforeObservedGroundYError']['p95'],4)}",f"{num(dm['pairedAfterObservedGroundYError']['median'],4)}/{num(dm['pairedAfterObservedGroundYError']['p95'],4)}"],
[f"世界帧间RMS，中位/p95(mm)，{dm['beforePairedJitter']['n']}对",f"{ms(dm['beforePairedJitter']['median'])}/{ms(dm['beforePairedJitter']['p95'])}",f"{ms(dm['afterPairedJitter']['median'])}/{ms(dm['afterPairedJitter']['p95'])}"],
[f"同ID帧间RMS，中位/p95(mm)，{dm['beforePairedStableJitter']['n']}对",f"{ms(dm['beforePairedStableJitter']['median'])}/{ms(dm['beforePairedStableJitter']['p95'])}",f"{ms(dm['afterPairedStableJitter']['median'])}/{ms(dm['afterPairedStableJitter']['p95'])}"],
['相对原中心线水平偏差，p95/最大(m)','0',f"{num(dm['xzDeviation']['p95'],4)}/{num(dm['xzDeviation']['max'],4)}"],
['确认模型0.60m冲突（全输入/保留输出，非成对）',str(a['widthAndPlane']['baseline']['collision060']),str(d['counts']['body060Collision'])]
])}

结论必须分开：贴地和极端折角改善，但**同 ID 抖动 p95 由 {ms(dm['beforePairedStableJitter']['p95'])} 增至 {ms(dm['afterPairedStableJitter']['p95'])} mm**，全体共同帧对 p95 也未改善。时间滤波相对“已贴地但未滤波”的同 ID p95 **{ms(dm['unfilteredPairedStableJitter']['p95'])}→{ms(dm['afterPairedStableJitter']['p95'])} mm** 有效，却没战胜原来的错误冻结平面；不应为追求更小 jitter 而重新冻结错误高度。重规划本就是可能的大幅合法变化，不能跨新目标 ID 强行渐变穿越障碍。[R3]

地面点误差使用当前高置信、距所选地面不超过 planeTolerance 的点，并只匹配水平半径 0.15m 内的观测；因此同样有选择偏差，不是独立地面真值。平面站点误差趋近零部分来自定义本身；邻近原始点的结果提供另一项一致性检查，仍不能取代人工/实测地面。[R2–R3]

输出路线在本帧确认模型上 **0 帧 0.60m 扫掠冲突**，但按未确认原始 obstacle 格做 0.50m 扫掠仍有 **{d['counts']['rawCollision']} 帧**相交。为对齐生产抗误报策略，这些原始格没有无条件硬否决绘制；不能据此声称“绝不穿真实障碍”。已做的保证严格限于**确认模型＋明示身体宽度＋每条最终线段**，并明确以隐藏帧换取约束满足。若要把原始相交也作为硬门，必须另做 A 类误报/可用性取舍。[R2–R3]

**B.5 复杂度、成本与可实施顺序**

设控制点 K、重采样点 M、确认障碍格 O：采样/局部曲线和网格 O(K+M)；现原型精确碰撞 O(MO)，世界最近点/偏差检查朴素实现最坏 O(M²) 或 O(MK)，并有候选回退倍数。产品实现应给障碍方格建空间桶，只查询扫掠包围盒；保留路线的弧长映射，避免每个点全线找最近。不要在显示每帧执行全部感知/搜索/碰撞重算；分析工作线程生成已复核中心线与网格，显示线程更新相机矩阵、短连接及深度遮挡。[R2]

M1 本次离线计时：整个绘制原型中位 **{num(dm['ms']['median'])}ms**、p95 **{num(dm['ms']['p95'])}ms**、最大 **{num(dm['ms']['max'])}ms**；其中构网格 p95 **{num(dm['meshMS']['p95'])}ms**。这些是观测耗时，不构成硬实时上界。顶点数原链最大 **{int(dm['beforeVertices']['max'])}**，改后最大 **{int(dm['afterVertices']['max'])}**（均含目标环）；改后段宽数值误差最大 **{num(dm['maxWidthError']['max']*1000,4)}mm**，只证明 CPU 网格横截面宽度，不是屏幕视觉宽度验收。[R2–R3]

建议 iPhone 预算（设计目标，不是测量）：分析 10Hz 的曲线+复核 p95≤2ms；显示 60Hz 的网格更新/上传 CPU≤0.2ms，路径及遮挡 GPU≤0.3ms，顶点上限 2048。超过预算回退上一份仍在有效期且已复核的几何或撤销，不回退到碰撞未验证的平滑线。必须补真机 GPU 时间、发热和长尾，M1 的浮点/缓存性能不能直接外推到 iPhone。[R8]

实施顺序建议：先纠正局部地面和近身折返连接；再在世界坐标做受约束圆角与圆连接；最后尝试有置信度的遮挡及更完整局部高度场。当前原型仍有显示覆盖损失、抖动退化、内侧透明重叠和未确认原始相交，**因此交付的是可复查实验，不是已经达到上线条件的渲染替换**。
''')

parts.append('''**复现命令与文件索引**

所有命令在 worktree 根目录执行。计数、代理和几何量来自以下流水线；设计阈值来自 design.json 或产品源码。时间戳时延采用录制数据，可重复；CPU 耗时属于本机本次测量，复跑会随负载变化，不能要求毫秒值逐位相同。生成文件并未改写原 DIAG。

```sh
# 一次性完整复跑（串行；只构建 SpatialCore 与本目录小工具）
zsh experiments/astra/run.sh /private/tmp/claude-501/-Users-kyf-Documents-PRTS/458323fc-5623-4807-ac7a-fa70db4beaf4/scratchpad/diag/pull-17pm-1028
```

- **R1 清单/缺失/源码哈希**：`python3 experiments/astra/prepare.py <上述DIAG根目录>`。输出 `results/inventory.json`、`missing_frames.json`、`recovered_frames.json`、`index.jsonl`、`samples.json`。实验副本在 generated/，生产源码不改动。
- **R2 全感知回放与原型**：run.sh 中唯一一次 `swift build ... -j 2` 后，执行其 `swiftc` 命令；再运行 `experiments/astra/bin/replay <inventory.json中的run> experiments/astra/results/index.jsonl > experiments/astra/results/replay.jsonl`。每行含所有方案、原始簇、确认方格、前后中心线和计时。附件校验失败即终止，不静默漏算。
- **R3 主数字**：`OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python3 experiments/astra/metrics.py experiments/astra/results/replay.jsonl`。主输出 `results/metrics.json`、事件 `events.csv`、标注 `annotation_manifest.csv`；stdout 有各档 FN/FP/切换/语音总表。JSON 的 all、epochs、drawing、freshness、annotation 对应报告各表。
- **R4 完整性/敏感性/故障注入**：`OPENBLAS_NUM_THREADS=1 OMP_NUM_THREADS=1 python3 experiments/astra/audit.py`。输出 `results/audit.json`；包括全部不一致帧、隔离集合、N敏感性、宽度复核、低角度脉冲、折角可见性及每个暂停窗口实际 capture 样本明细。
- **R5 标注**：`python3 experiments/astra/annotation.py --extract`，生成 `results/video_check.json`、JPG、annotation.html；`python3 experiments/astra/score_labels.py adjudicated.csv` 计算人工裁决后的近距分类指标。空标注表不会输出虚构精确率。
- **R6 检验**：`experiments/astra/bin/replay --self-test`；`python3 experiments/astra/tests.py`；下方 SpatialCore 命令。分别检查圆角穿障必须拒绝、水平偏差、圆连接有限性/宽度、缺帧不补命中，以及缺失窗口不能算 FP。生产路线/投影/稳定性相关测试通过情况见 core-tests.log。
- **R7 代码依据**：`rg -n 'referencePlane == nil|thresholdSeconds|previous = current|visiblePlan|matched - 0.2|approach:|minimumWidth|noDepth|worldVertex|worldFragment|lastSeverity' Vendor/SpatialCore/Sources/SpatialCore PRTS/Spatial PRTS/Feedback`；配合报告列出的文件行号直接阅读。旧设计说明为 docs/architecture/ROUTE_PROJECTION.md；第一轮报告为 docs/reports/ALGORITHM_REVIEW_ASTRA_2026-10-28.md。
- **R8 设计量/报告生成**：`cat experiments/astra/design.json`；`python3 experiments/astra/report.py`。样本量公式在 metrics.py 的 annotations() 中，报告表格由 metrics.json/audit.json 自动填充，避免手抄数字漂移。

```sh
CLANG_MODULE_CACHE_PATH="$PWD/experiments/astra/build/ModuleCache" \\
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/experiments/astra/build/ModuleCache" \\
swift test --disable-sandbox --package-path Vendor/SpatialCore \\
  --scratch-path experiments/astra/build -j 2 \\
  --filter 'PathPredictionTests|RouteProjectionTests|WaypointStabilityTests|OccupancyFootprintTests'
```

本次通过：Swift 原型断言 7 项，Python 指标测试 6 项，SpatialCore 相关测试 65 项。未执行 xcodebuild，未编译 App，未启动模拟器，未修改或上传实测数据。无人工真值、无实播音频、无 iPhone GPU 测量的部分均未伪装成已验证结果。
''')
(ROOT/'ASTRA_ROUND2.md').write_text('\n'.join(parts))
print(ROOT/'ASTRA_ROUND2.md')
