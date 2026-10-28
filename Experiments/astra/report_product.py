#!/usr/bin/env python3
"""Render the round-three report exclusively from archived complete replays."""
import collections,hashlib,json,pathlib,re,subprocess
import numpy as np
from metrics import resample,nearest,stats,contiguous
HERE=pathlib.Path(__file__).resolve().parent;ROOT=HERE.parents[1];OUT=HERE/'results/round3'
names=['baseline','step1','step2','step3','step4','step5','only1','only2','only3']
data={n:json.loads((OUT/n/'product_metrics.json').read_text()) for n in names}
manifest={n:json.loads((OUT/n/'product_manifest.json').read_text()) for n in names}
extra={}
planning_signatures={}
for n in names:
 rows=[json.loads(l) for l in (OUT/n/'product-replay.jsonl').open()]
 planning_signatures[n]=hashlib.sha256(json.dumps([{k:r['variants']['baseline'].get(k) for k in ['path','scenario','distance','reference','confirmedCount']} for r in rows],sort_keys=True,separators=(',',':')).encode()).hexdigest()
 extra[n]={'unknown':sum(r['variants']['feedback']['scenario']=='unknown' for r in rows),
           'smallPulse':sum(r['haptics'].get('baseline') in ('left_double','right_long') and abs(r['variants']['baseline'].get('heading',999))<12 for r in rows)}
 assert len(rows)==2128 and data[n]['depthFrames']==2125
 assert data[n]['drawing']['counts']['visible']==518
 assert all(v['source']==v['copy'] for v in manifest[n]['sources'].values())
 del rows
# Explain the one-tick population change against the round-two age-only audit.
base_rows=[json.loads(l) for l in (OUT/'baseline/product-replay.jsonl').open()]
captures=[json.loads(l) for l in (HERE/'results/captures.jsonl').open()]
actual={(t['epoch'],t['frameID']) for t in map(json.loads,(OUT/'baseline/product-ticks.jsonl').open()) if t['eligible']}
old=set();capture_difference=[]
for epoch in sorted({r['epoch'] for r in base_rows}):
 rr=[r for r in base_rows if r['epoch']==epoch];i=-1
 for c in captures:
  if c['epoch']!=epoch:continue
  while i+1<len(rr) and rr[i+1]['publishTime']<=c['receivedAt']:i+=1
  if i<0 or not c['trackingNormal'] or c['receivedAt']-c['timestamp']>.25:continue
  r=rr[i]
  if r['missingDepth'] or not r['tracking']:continue
  key=(epoch,c['frameID']);old.add(key)
  if key not in actual:capture_difference.append({'epoch':epoch,'captureFrameID':c['frameID'],'publishedFrameID':r['frameID']})
(HERE/'results/round3/capture-gate-audit.json').write_text(json.dumps({'round2Eligible':len(old),'productEligible':len(actual),'excluded':capture_difference},indent=2))
del base_rows,captures
# Compare jitter on the EXACT shared frame pairs, including the pre-drawing product.
curves={}
for n in ['baseline','step4','step5']:
 compact=[]
 for line in (OUT/n/'product-replay.jsonl').open():
  r=json.loads(line)
  compact.append({k:r[k] for k in ['epoch','frameID','timestamp','missingDepth','tracking','drawing'] if k in r})
 curves[n]=compact
common_jitter=collections.defaultdict(list)
for i in range(1,len(curves['baseline'])):
 pairs={};eligible=True
 for n,rr in curves.items():
  a,b=rr[i-1],rr[i];da,db=a.get('drawing'),b.get('drawing')
  if not da or not db or not contiguous(a,b) or da['routeID']!=db['routeID']:eligible=False;break
  aa,bb=resample(da['after']),resample(db['after'])
  if len(aa)<=14 or len(bb)<=14:eligible=False;break
  pairs[n]=(aa,bb)
 if eligible:
  for n,(a,b) in pairs.items():
   ds=np.r_[nearest(a[6:-6],b)[1],nearest(b[6:-6],a)[1]]
   common_jitter[n].append(float(np.sqrt(np.mean(ds*ds))))
common_jitter={n:stats(v) for n,v in common_jitter.items()}
effect_audit={n:planning_signatures[n]==planning_signatures['step2'] for n in ['step3','step4','step5']}
assert all(effect_audit.values()),effect_audit
(HERE/'results/round3/planning-effect-audit.json').write_text(json.dumps({'sameAsStep2':effect_audit,'signatures':planning_signatures},indent=2))
series=json.loads((HERE/'round3-patches/series.json').read_text())
log=subprocess.check_output(['git','log','--format=%H%x09%s'],cwd=ROOT,text=True)
commits={line.split('\t',1)[1]:line.split('\t',1)[0] for line in log.splitlines() if '\t' in line}
labels={'baseline':'基线','step1':'+1 地面','step2':'+1+2 宽度','step3':'+1+2+3 新鲜度','step4':'+1+2+3+4 触觉','step5':'+1+2+3+4+5 绘制','only1':'基线只加 1','only2':'基线只加 2','only3':'基线只加 3'}
def f(v,d=3):return '—' if v is None else f'{v:.{d}f}'
def m(n,key='baseline'):return data[n]['metrics'][key]
def fn(v,d):return f"{v['near'+d]['missFrames']} / {f(v['near'+d]['missSeconds'])}"
def table(headers,rows):return '\n'.join(['| '+' | '.join(headers)+' |','| '+' | '.join(['---']*len(headers))+' |']+['| '+' | '.join(map(str,r))+' |' for r in rows])
def main_table(ns,key='baseline'):
 return table(['版本','FN1 帧/秒','FN0.5 帧/秒','FP1.5','FP/分钟','clear↔障碍','blocked 帧','有路线帧','0.60 m 冲突帧'],[[labels[n],fn(m(n,key),'1'),fn(m(n,key),'0.5'),m(n,key)['falseProxy']['1.5'],f(m(n,key)['falsePerMinute']),m(n,key)['flips'],m(n,key)['blockedFrames'],m(n,key)['pathFrames'],m(n,key)['body060ConflictFrames']] for n in ns])
def voice_table(ns):
 return table(['版本','危险语音请求','语音 FP1.5','状态时延 p95 ms','语音时延 p95 ms','规划 CPU p95 ms'],[[labels[n],m(n)['speechRequests'],m(n)['speechFalseProxy'],f((m(n)['near1']['stateLatency']['p95'] or 0)*1000,1),f((m(n)['near1']['speechLatency']['p95'] or 0)*1000,1),f(m(n)['planningMS']['p95'])] for n in ns])
b=m('baseline');g=m('step1');w=m('step2');last=m('step5');draw=data['step5']['drawing'];dm=draw['metrics'];cf=data['step3']['captureFreshness']
committed=all(commits.get(c['subject'])==manifest['step'+str(c['number'])]['commit'] for c in series['changes'])
commit_note=('五项产品改动已按顺序独立提交，每项提交后均从对应产品源快照重新编译并完整重放；提交 hash 列在后文。' if committed else '**交付限制：本会话 `.git` 被环境设为只读，`git add` 创建 `.git/index.lock` 返回 Operation not permitted，且不允许提权。因此没有创建本轮 Git 提交，不能给出不存在的提交 hash，也未完成“每项提交后再测”的时序要求。** 以下测量基于五个逐项冻结、可独立重建的产品源码快照；补丁与工具分开保存，完整编译、测试和重放都已执行。')

text=f'''# PRTS 第三轮：产品实现与完整重放

日期：2026-10-29。已读取两轮报告；本轮不实施单帧快告警、0.90 m 硬加宽、可见性门替换或危险语音抢播。

## 结论与采纳建议

五项改动已实现到产品代码；最终组合完整重放 **2128 帧，其中 2125 份真实深度重算**，全套 SpatialCore **340 项测试通过**。确认/去抖/限频保留。代理结果不能当作人工真值。

{commit_note} 当前分支仍为 main；没有 push、没有修改 remote。

- **1 地面：建议采纳。** FN1/FN0.5 与状态 FP1.5 不变；blocked {b['blockedFrames']}→{g['blockedFrames']}，路线 {b['pathFrames']}→{g['pathFrames']}，危险语音 {b['speechRequests']}→{g['speechRequests']}。改善的是参考一致性，不是证明真实漏报减少。B1 原参考较好，中位地面差可能略增。
- **2 宽度：建议接受身体宽硬约束，但需负责人确认可用性/语音代价。** 累积在 +1 上，身体冲突 {g['body060ConflictFrames']}→{w['body060ConflictFrames']}；同时 blocked {g['blockedFrames']}→{w['blockedFrames']}，切换 {g['flips']}→{w['flips']}，危险语音 {g['speechRequests']}→{w['speechRequests']}，语音 FP {g['speechFalseProxy']}→{w['speechFalseProxy']}。不据此自动作出上线决定。
- **3 新鲜度：建议采纳，并接受 unknown 的可用性代价。** {cf['eligible']} 个符合旧反馈门的 capture tick 中，撤销 {cf['suppressed']} 个许可（原 clear {cf['clear']}、有路线 {cf['directions']}）。这是弃答，不是告警，也不能叫修复漏报。语音仍走原限频。
- **4 触觉：建议采纳。** 见下方请求计数。入向门收窄到 12°，代价是未入向的 5°–12° 区间不主动催促修正；没有身体朝向/触感真值。
- **5 绘制：几何与覆盖率达标，抖动代价需负责人决定。** 共同帧显示 **{draw['counts']['visible']}/518**；回退 {draw['counts']['fallback']} 帧。最大折角中位/p95 从 {f(dm['beforeMaxAngle']['median'],1)}°/{f(dm['beforeMaxAngle']['p95'],1)}° 到 {f(dm['afterMaxAngle']['median'],1)}°/{f(dm['afterMaxAngle']['p95'],1)}°，但同 ID RMS 抖动 p95 从 {f(common_jitter['baseline']['p95']*1000,2)} 到 {f(common_jitter['step5']['p95']*1000,2)} mm。**不声称整体稳定性改善。**

## 累积结果

下表状态与“有路线”采用规划/发布层口径，沿用第二轮；语音列已经应用该版本的反馈门。规划意图允许保留，反馈过期则 unknown，二者在后文分别报告。逐帧核对 +3/+4/+5 的路线点、ID、场景、距离、参考及确认格数量均与 +1+2 完全一致，结果在 `planning-effect-audit.json`。

{main_table(names[:6])}

{voice_table(names[:6])}

时延为 ≤1 m 持续证据事件的首个原始合格观测到发布/请求，使用录制完成时间；CPU 耗时是本次 M1 实测，随负载浮动，不是 iPhone 承诺。没有模拟新增计算耗时改变 iPhone 并发调度的效果。时延分布只含已覆盖事件，未覆盖数量见下一表，不能悄悄删掉未告警事件。

{table(['版本','≤1m 事件','状态时延有值事件','整段 clear 事件','无危险语音事件','语音 FP 被截断窗口'],[[labels[n],m(n)['near1']['episodes'],m(n)['near1']['stateLatency']['n'],m(n)['near1']['entirelyMissedEvents'],m(n)['near1']['noSpeechEvents'],m(n)['speechFalseCensored']] for n in names[:6]])}

## 单项消融：基线只加 1、2、3

每行重新复制相应产品源树、编译和重跑全部深度。不是把第二轮的实验开关结果拿来填表；`only1` 与 `step1` 源码一致仍独立复跑。不可将单项收益相加。

{main_table(['baseline','only1','only2','only3'])}

{voice_table(['baseline','only1','only2','only3'])}

## 反馈 unknown 与触觉

下表为**经过反馈许可门**的状态，nil/过期明确记为 unknown。与规划表的差别是撤销许可，不能解读为障碍变少；unknown 不计入 clear 漏报，也不计入 clear↔障碍切换。

{main_table(['baseline','step3','step5','only3'],'feedback')}

{table(['版本','unknown 分析帧','unknown 秒','旧门合格 capture tick','撤销 tick','其中 clear','其中方向'],[[labels[n],extra[n]['unknown'],f(m(n,'feedback')['unknownSeconds']),*[data[n]['captureFreshness'][k] for k in ['eligible','suppressed','clear','directions']]] for n in ['baseline','step3','step5','only3']])}

capture tick 分母与第二轮的 {len(old)} 不同：本轮执行产品门，额外遵守 context 的 frame/epoch/参数匹配。差异帧（epoch、captureFrameID、publishedFrameID）为 `{capture_difference}`：产品拒绝当时 frameID 尚在未来的结果。核对结果另存 `results/round3/capture-gate-audit.json`，由本报告脚本重算。分析发布样本和 capture tick 是两套分母，不能相加。基线 unknown 包含跟踪/发布无许可帧；这些帧不进入有效相邻观测时长，因此帧数非零而秒数为零。

{table(['版本','左右脉冲请求','其中角度绝对值<12°','对准一次请求'],[[labels[n],data[n]['haptics'].get('left_double',0)+data[n]['haptics'].get('right_long',0),extra[n]['smallPulse'],data[n]['haptics'].get('aligned_once',0)] for n in names[:6]])}

触觉与语音按每个保存的发布样本调用一次；触觉不是硬件脉冲日志。已有转向可继续到 5°，进入对准带后保持原 0.3 s 确认；已对准后明显偏离仍保留原重启停留门。中间 5°–12° 不能偷偷累积对准时间。

## 绘制与地面

固定旧基线的 **518 帧路线意图及 ID/x/z**，在各版本的新产品绘制函数上重放，以免路线有无变化污染显示覆盖率。高度取当前产品规划局部平面；不是直接强贴每帧感知平面。另对当前实际产品路线单独统计。绘制只在保存的分析帧重算，非 60 Hz 屏幕全帧或截图验收。折角按 5 cm 等弧长重采样；同 ID RMS 使用世界曲线双向最近距离、去两端各 0.3 m，不跨 ID/缺失/epoch 平滑。下表 RMS 只使用三版本共同满足长度条件的帧对，不用不同分母比较。

{table(['版本（共同518帧）','最大折角中位/p95 °','平面差中位/p95 m','同ID RMS中位/p95 mm','同ID帧对','显示','回退折线'],[[labels[n],f(data[n]['drawing']['metrics']['afterMaxAngle']['median'],2)+' / '+f(data[n]['drawing']['metrics']['afterMaxAngle']['p95'],2),f(data[n]['drawing']['metrics']['afterGroundError']['median'],4)+' / '+f(data[n]['drawing']['metrics']['afterGroundError']['p95'],4),f(common_jitter[n]['median']*1000,2)+' / '+f(common_jitter[n]['p95']*1000,2),common_jitter[n]['n'],str(data[n]['drawing']['counts']['visible'])+'/518',data[n]['drawing']['counts']['fallback']] for n in ['baseline','step4','step5']])}

为控制水平采样位置，另外在最终输出的相同水平站点成对比较高度：原基线平面的误差中位/p95 为 **{f(dm['pairedBeforeGroundError']['median'],4)}/{f(dm['pairedBeforeGroundError']['p95'],4)} m**，当前绘制为 **{f(dm['pairedAfterGroundError']['median'],4)}/{f(dm['pairedAfterGroundError']['p95'],4)} m**，共 {dm['pairedAfterGroundError']['n']} 点。仅统计 groundConfirmed 帧；不含 2.5 cm 渲染 lift。这是两个估计参考间的一致性，**不是独立真实地面误差**。

当前实际产品路线：**{data['step5']['actualDisplay']['visible']}/{data['step5']['actualDisplay']['input']}** 全显示，回退 **{data['step5']['actualDisplay']['fallback']}** 帧，0.60 m 确认模型冲突 **{data['step5']['actualDisplay']['collision']}** 帧。固定旧意图样本有 **{draw['counts']['collision']}** 帧折线回退仍与当前确认模型相交；这来自保留旧基线路线的对照输入，不是新产品规划输出。最终平滑输出的冲突数 **{draw['counts'].get('smoothedCollision',0)}**。必须保留这一区分：按要求回退原折线时，显示不构成安全许可。

绘制 CPU 中位/p95/max：{f(dm['drawingMS']['median'])}/{f(dm['drawingMS']['p95'])}/{f(dm['drawingMS']['max'])} ms。工具为统计 shape 和实际 mesh 各调用一次中心线算法，属于本机保守计时；App 调用一次 meshes。未测 iPhone GPU、热稳态或屏幕观感。圆连接使用不透明路线材质；不增加遮挡 shader、高度场或跨 ID 时间平滑。

脚下规划平面相对当前确认平面：

{table(['段','确认帧','基线中位/最大 m','+1中位/最大 m'],[[f'B{e}',data['baseline']['footPlaneError'][e]['n'],f(data['baseline']['footPlaneError'][e]['median'],3)+' / '+f(data['baseline']['footPlaneError'][e]['max'],3),f(data['step1']['footPlaneError'][e]['median'],3)+' / '+f(data['step1']['footPlaneError'][e]['max'],3)] for e in sorted(data['baseline']['footPlaneError'])])}

## 实现与语义变更审计

1. `TemporalOccupancyGrid` 仅在 `groundConfirmed` 且局部差超过 0.04 m 或法向超过 3° 时替换已有参考；初始化仍可临时使用原有 fallback。障碍世界关联 tracks 不清空、不改计时。`ObstacleWaypointPlanner` 用值状态事务重投影路线、目标、continuation、preview、旧脚点及参考方向，只改 y；完整近身连接和身体扫掠先复核，失败进入原有重规划/blocked 流程，不能把旧方向发出去。prepared 段仍在提升时再次检查。
2. 产品运行时由 `ProbeParameters.bodyWidth` 决定硬宽，本批配置 0.60 m；旧 `minimumWidth` 键保留解码，产品不再用其 0.50 m 值覆盖身体宽。`sideMargin` 用于先尝试舒适宽度、失败后硬身体宽搜索；保留确认、场景去抖与可见性门。`ProbeParameters.requiredWidth` 现在表示身体硬宽，另有 `comfortableWidth`。verified 对照的硬宽也统一；几何专用测试 seam 仍可显式测 0.50 m 合成体，不是运行时开关。
3. `ObstacleCheckStamp` 仅在有可分类平面、同源 grid、有效采样点和位姿时记源时间；无模型/空采样不续时。stamp 随 PathUpdate 发布，并受 epoch、参数、帧屏障和 hazard watermark 检查。`SharedSnapshot.activeWaypointUpdate` 过期返回 nil，`waypointFeedbackState` 返回 unknown；`pathHeading` 同时撤销，现有 FeedbackCoordinator 取消旧语音，PathHaptics 停止旧模式，不重置语音限频、不新增“看不清”。保留视觉路线不等于保留方向授权。
4. 未入向时到 deviation（默认 12°）才开始方向触觉；对准带仍为 5°。同步 SpatialProbe 冻结基线中的 `PathHapticPolicy.swift`。
5. `GroundRouteDrawing` 只生成显示中心线；连接投影到入口段最近点，尝试 0.12/0.06 m trim 的二次圆角，限制相对原线水平偏移 5 cm、弦近似误差 1 mm，逐条检查最终线段身体扫掠。候选失败保留原折线；模型不可用也回退，不隐藏。`PathDrawing` 对连接和路线统一做 round join，renderer 传入同次已确认模型，并把障碍帧/身体宽纳入缓存 key。

**sideMargin 的旧语义确有冲突，已明确改写：** 设置页原名“单侧安全余量”；`VerifiedContinuityTests.testVerifiedComparatorUsesBodyEnvelope` 原断言身体宽加双侧余量是必需包络；`OccupancyContinuityTests.testBodyEvidenceDoesNotOverrideConfiguredVetoWidth` 原允许 1.2 m 身体按 0.5 m 规划。这不是仅改名称：本轮按产品负责人授权放弃把余量当不可退让安全要求，UI 改成“单侧舒适余量（可退让）”，取消与身体宽割裂的路径宽滑块，相关测试改为新契约。历史架构文档明确标为历史，不拿旧 0.50 m 说明覆盖当前产品。身体实际尺寸、持机偏心和定位误差没有真值，0.60 m 不构成安全认证。

`Experiments/SpatialProbe` 同步了 `Geometry.swift` 的宽度契约及 `PathHapticPolicy.swift`；未扩大一致性测试豁免。`scripts/test_spatial_integration.py` 的 9 项通过。新增核心测试分别覆盖地面确认/阈值/计时/坐标/碰撞、宽度与舒适回退、新鲜度过期/恢复/异常时钟/epoch/屏障、触觉入向和对准中断、显示回退/最终弦碰撞/round join/高度与偏移约束。App 文件只做调用点检查，**没有编译 App，仍需负责人自行编译验证**。

## 数据与计数边界

输入是 B1–B4 的完整可恢复记录：主 DIAG 2126 条分析，恢复 Dev Capture 的 B3 f3751/f3931 后为 2128 条，2125 份深度逐个校验长度、身份和 SHA256 后重跑 SpatialAnalyzer。B1 f1/f7/f13 无深度且 tracking 异常；B2 f3643、B3 f4021 无可恢复深度，保留在缺失清单，绝不插值制造观测。

有效相邻观测间隔总和 **{f(b['observedSeconds'],6)} s**，固定相机前向身体审计带总宽 0.60 m。FN1/FN0.5：同簇至少 6 个高置信采样点、相邻 <0.15 s、中心匹配 ≤0.25 m、连续 3 帧后仍 clear 的帧数/时间。FP1.5：新告警后的 1.5 s 内无持续支持，末尾 0.3 s 无合格簇；缺失/尾部不足 censored。主表与第二轮相同 `metrics.summarize` 函数，1 s/2 s 敏感性仍保存在各 JSON 的 falseProxy 中。

高置信深度不是人工障碍真值；平面错误、物体移动离开或成功避让均可能改变代理，传感器完全没看到的障碍不进入 FN 分母。回放保留原录制相机位姿，未模拟不同绕行引导改变用户行走轨迹的后续观测。语音假定 `canSpeak=true`，没有重建 AVSpeechSynthesizer 完成回调、完整并发抢占和每次 UI 调度；是请求策略重放，不是听到的次数。动态、坡道、玻璃、手机偏心和单目尺度冲突仍需补数据；本轮没有给它们编造结果。

## 版本、补丁与源码核对

实际基线提交：`{series['baseline']}`。各产品改动的提交状态与独立补丁如下；SHA256 是补丁指纹，**不是 Git commit hash**。

{table(['改动','Git commit hash','独立补丁','补丁 SHA256'],[[c['subject'],commits.get(c['subject'],'未创建：.git 只读'),c['patch'],c['sha256']] for c in series['changes']])}

补丁位于 `Experiments/astra/round3-patches/`，每份含指定中文标题和 `Co-Authored-By: GPT-6 Astra <noreply@openai.com>`。回放工具的改动独立于五份产品补丁；报告另存根目录。未将运行产物加入版本管理。

| 重放 | 产品源树 SHA256（含核心测试） | 二进制 SHA256 |
| --- | --- | --- |
'''
for n in names:text+=f"| {labels[n]} | `{manifest[n]['sourceTreeSHA256']}` | `{manifest[n]['binarySHA256']}` |\n"
text+='''
核对方法：每次 `prepare_product.py` 删除旧生成包并从该阶段产品源码重新复制，逐文件断言 source SHA256 == copy SHA256；只链接该生成包产出的 SpatialCore。每次重新生成 Speech/Turns/adapter、重新编译 replay-product、重跑所有帧。`seal_product.py` 在执行后再次验证编译输入，记录 executable、工具、App 调用处与 Swift 版本。`product_manifest.json` 是本轮权威来源记录；基线同时通过 2128/2128 录制预测一致性检查：reason、scenario 和路线点（坐标容差 0.1 mm）。没有用改名的第二轮实验规划器代替产品。

## 集中复现命令

均从仓库根目录运行。不会 push、改 remote 或写原始 DIAG；同一时间只有一个编译。

```sh
# 恢复 .git 写权限后，独立提交工具、逐项提交产品并在每项提交后测量，最后提交报告
# 当前受限会话未执行此脚本；不修改 remote、不 push
python3 Experiments/astra/commit_round3.py

# 当前产品完整重放、全套测试（swift build/test -j 2）
zsh Experiments/astra/run.sh

# 从基线和五项产品补丁重建九个源树，逐个完整重放与全套测试，最后生成本报告
zsh Experiments/astra/run_round3.sh

# 指定只读数据根目录时，作为上面脚本的第一个参数传入
# 单次自选源快照，仍然重新生成和编译
ASTRA_SOURCE_ROOT=/path/to/product-snapshot \\
  zsh Experiments/astra/run_product.sh custom /path/to/pull-17pm-1028

# 当前工作区 SpatialCore 的全部测试；独立缓存避免路径大小写导致 PCM 重定义
CLANG_MODULE_CACHE_PATH="$PWD/Experiments/astra/build-final/ModuleCache" \\
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/Experiments/astra/build-final/ModuleCache" \\
  swift test --disable-sandbox --package-path Vendor/SpatialCore \\
  --scratch-path Experiments/astra/build-final -j 2

python3 scripts/test_spatial_integration.py
python3 Experiments/astra/tests.py
python3 Experiments/astra/report_product.py

# 检查 App 调用链与同步基线
rg -n 'successfulObstacleCheck|ObstacleFeedbackFreshness|activeWaypointUpdate|pathHeading|cancelPerceptionSpeech' \\
  Vendor/SpatialCore/Sources/SpatialCore PRTS/Spatial/Runtime PRTS/Feedback
rg -n 'resolvingBodyWidth|sideMargin|GroundRouteDrawing|PathDrawing.meshes|updatePathBuffer' \\
  Vendor/SpatialCore/Sources/SpatialCore PRTS
```

产物：`results/round3/<版本>/product-replay.jsonl`、`product-ticks.jsonl`、`product_metrics.json`、`product_manifest.json`、`product-tests.log`、`inventory.json` 及缺失/恢复清单。统计脚本用到 NumPy；不安装新依赖。若只重算统计，需对应阶段的 replay/index/capture 文件，优先运行上述单次完整命令以避免混用不同版本产物。
'''
(ROOT/'ASTRA_ROUND3.md').write_text(text)
(HERE/'results/round3/report_manifest.json').write_text(json.dumps({
 'reportSHA256':hashlib.sha256(text.encode()).hexdigest(),
 'generatorSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),
 'metricSHA256':{n:hashlib.sha256((OUT/n/'product_metrics.json').read_bytes()).hexdigest() for n in names},
 'sourceManifestSHA256':{n:hashlib.sha256((OUT/n/'product_manifest.json').read_bytes()).hexdigest() for n in names}},indent=2))
print(ROOT/'ASTRA_ROUND3.md')
