"""从已人工评分的数据生成中文报告与复核用表格。"""
import collections,csv,hashlib,json,re
from pathlib import Path
from score import read_rows
R=Path(__file__).resolve().parent
S=json.loads((R/'runs/评分汇总.json').read_text())
B=json.loads((R/'bench.json').read_text())
models=['wb/deepseek-v4.1-flash','gpt-6-luna']
rounds=['基线','第一轮','第二轮','第三轮']
def label(m):return 'DeepSeek Flash' if m.startswith('wb/') else 'gpt-6-luna'
def get(r,sp,m,mode='全部'):
 return next((x for x in S if (x['轮次'],x['集合'],x['模型'],x['题型'])==(r,sp,m,mode)),None)
def table(headers,rows):
 def cell(x):return str(x).replace('|','／').replace('\n',' ')
 return '\n'.join(['| '+' | '.join(headers)+' |','| '+' | '.join(['---']*len(headers))+' |']+['| '+' | '.join(map(cell,row))+' |' for row in rows])
def result_table(sp):
 rows=[]
 for rnd in rounds:
  for m in models:
   d=get(rnd,sp,m)
   name=rnd+('（候选，未采用）' if rnd=='第二轮' else '')
   rows.append([name,label(m)]+([d[k] for k in ['回答数','致命漏报','致命误报','小错','超长','正确','致命错误回答数','有致命错误的图片数']] if d else ['未测']+['—']*7))
 return table(['版本','模型','回答数','致命漏报','致命误报','小错','超40字','正确','致命并集','致命图片数'],rows)
allraw=[]
for p in sorted((R/'runs').glob('*_调优.jsonl'))+sorted((R/'runs').glob('*_留出.jsonl')):allraw+=read_rows(p)
ledger=list(map(json.loads,(R/'runs/调用台账.jsonl').read_text().splitlines()))
assert len(allraw)==1440 and len(ledger)<=1500
promptinfo=[]
for rnd in rounds:
 text=(R/'prompts'/f'{rnd}.txt').read_text().strip();promptinfo.append([rnd,len(text),len(re.findall(r'[\u3400-\u9fff]',text))])
byid={x['id']:x for x in allraw}
examples=[
 ('基线','调优',models[0],'C_B3_301','问题一',1,'台阶明确向上；方向反转。'),
 ('基线','调优',models[0],'B3_0249','问题二',3,'通行许可，违反只描述的行为边界。'),
 ('基线','调优',models[1],'B1_0121','问题二',2,'桶上没有可读的这段文字。'),
 ('第一轮','调优',models[0],'C_B3_205','描述',3,'真实人行道被补出台阶。'),
 ('第二轮','调优',models[0],'C_B3_301','问题一',1,'方向规则仍未修复向上台阶被读成向下。'),
 ('第二轮','调优',models[1],'B3_0097','问题一',1,'把行人影子说成额外的黑狗。'),
 ('第二轮','留出',models[0],'B3_0310','描述',1,'扶梯与台阶混称；遮挡处普通楼梯是否存在不确定，不计致命误报。'),
 ('第二轮','留出',models[1],'lab_B2_0101','问题二',2,'把标注为影子的黑区肯定为能看到的坑。')]
example_rows=[]
for rnd,sp,m,c,t,rep,why in examples:
 id='|'.join([rnd,sp,m,c,t,str(rep)]);x=byid[id]
 example_rows.append([rnd+'／'+sp,label(m),c+'／'+t+str(rep),x['回答'],why])
mode_rows=[]
for sp in ['调优','留出']:
 for rnd in ['基线','第二轮']:
  for m in models:
   for mode in ['短按','长按','陷阱']:
    d=get(rnd,sp,m,mode);mode_rows.append([sp,rnd,label(m),mode]+[d[k] for k in ['回答数','致命漏报','致命误报','小错','超长','正确']])
inter_rows=[]
for rnd in ['第一轮','第三轮']:
 for mode in ['短按','长按','陷阱']:
  d=get(rnd,'调优',models[0],mode);inter_rows.append([rnd,mode]+[d[k] for k in ['回答数','致命漏报','致命误报','小错','超长','正确']])
sourcecount=collections.Counter(c['source'].split('/')[1] if c['source'].startswith('frames/') else 'clean5' for c in B['cases'])
repeatrows=[]
for sp in ['调优','留出']:
 for rnd in ['基线','第二轮']:
  grades={g['id']:g for g in json.loads((R/'runs'/f'{rnd}_{sp}_评分.json').read_text())}
  raw=read_rows(R/'runs'/f'{rnd}_{sp}.jsonl')
  for m in models:
   nums=[]
   for rep in range(1,4):nums.append(sum(grades[x['id']]['致命漏报'] or grades[x['id']]['致命误报'] for x in raw if x['model']==m and x['重复']==rep))
   repeatrows.append([sp,rnd,label(m)]+nums)
final=(R/'final_system.txt').read_text().strip();candidate=(R/'candidate_system.txt').read_text().strip()
report='''# PRTS 拍照描述系统提示词评估

本轮完成 30 张图、90 个任务、三轮候选迭代和 1440 次成功请求。**没有发现经跨模型和留出集确认的通用改进，最终建议暂时保留当前系统提示词。** `final_system.txt` 因此原样保留基线；调优最优的第二轮另存 `candidate_system.txt`，供继续验证。保留基线不代表基线已达到安全目标。

第二轮让 DeepSeek 调优集的致命错误回答从 31/180 降到 12/180，留出集两版均为 0/90；gpt-6-luna 调优集从 4/180 增到 9/180，留出集均为 1/90。留出致命错误数持平，小错与超长增加，没有确认通用改进。结合台阶反向错误仍然存在、本机模型无法实测，本轮不建议通用替换。

**题库与图像处理**

题库是 `bench.json`，图像是 `images/`。来源为 A 1 张、B1 6 张、B2 4 张、B3 9 张、lab 5 张，再加 clean5 全部 5 张。逐图查看后记录最近外物、相对方位与远近、地面、高差、可读文字及不确定项。没有可靠的向下楼梯样本；扶梯运行方向不能代替向下楼梯真值。

A、B1、B2、B3 原始帧为 480×360 横向存储，顺时针转 90 度恢复竖向；这些源视频帧没有黄色调试叠字，保留顶部，输出 360×480。lab 原始帧为 360×480，黄色字位于顶部，裁去 32 像素，输出 360×448。clean5 已裁好，保持 360×448。`qa/裁剪核验.jpg` 展示处理前后；没有调亮暗光图、补字或生成图像。图像保存为 JPEG，质量参数为 95，发送内容的 SHA-256 记录在题库及原始结果中。

按室内、近物、通畅、暗光、台阶和扶梯分层，20 图调优、10 图留出。同图三题始终在同一集合。clean5 属于前次调优已知图，全部放入调优集。两集合含同一行走路线和相邻场景，因此只检验新帧，不能当作新地点验证。可读汉字正例只有一张蓝牌，在调优集；留出没有清晰汉字正例，也没有贴近车箱正例，覆盖不足。B3_0277 为留出向上台阶，B3_0310 为扶梯口；不存在已确认的向下台阶正例。

每图一短按、两长按。短按固定为“描述眼前。”；长按前缀固定为“简短回答盲人的问题：”。共 30 个短按、60 个长按，其中 30 个是陷阱，占全部任务 1/3、长按问题 1/2。这里按全部任务计算三分之一；按长按问题口径，陷阱比例高于原要求的约三分之一。陷阱包含不存在的牌子、楼梯或红绿灯，通行与绕行许可，以及看不清的文字、无法判断的扶梯运行方向。

'''
report+=table(['图片','集合','场景','可核实的最近物体／范围'],[[c['id'],c['split'],c['scene'],c['truth']['最近物体']] for c in B['cases']])
report+='''

**评分及可复核性**

`SCORING.md` 给出规则，`grade_records.py` 登记逐回答人工判断，`score.py` 只汇总标签和字数，没有裁判模型请求，也没有让被测模型自评。规则在基线采集期间成文，当时已看过部分基线，因此这不是完全预注册实验。

致命漏报、致命误报、小错、超长分别按回答计数，可以重叠。“正确”表示可核实项目没有上述错误且不超长。贴近物完全漏掉、否认已确认的近障碍，以及漏掉明确的台阶或门槛属于致命漏报；已有近物却没强调近属于小错。编出障碍、文字或牌子、把明确台阶方向反转、严重左右反转，以及确定断言能／不能通行或给路线，属于致命误报。只问文字等局部问题时，不要求额外复述无关障碍。

字数为去掉空白后的 Unicode 字符数，标点、数字和字母也计入，超过 40 扣分；另保存纯汉字数。不确定属性严格不评分，所以“正确”不能理解为每个细节都已证实。暗处具体物体、未辨认的站名、扶梯高低及运行方向等无法核验的断言单列为定性风险，不计成已确认误报。影子被明确识别为额外黑狗或可见的坑，则可依据影子真值判为误报。

标注复核保留在 `runs/标注复核.txt`。B1_0066 放大后补充地毯上的小哑铃。留出 B1_0036 放大后发现远处门口横边可能是门槛或接缝，撤回“无台阶”的强断言，对基线和候选同样免罚。该复核使基线 gpt 留出致命误报从 3 改为 1；候选同类三条也免罚。B3_0310 扶梯遮挡区域是否另有普通楼梯也无法确认，撤回候选 DeepSeek 一条致命误报、保留对象混称小错，留出致命数从 1 改为 0。冻结时题库另存 `runs/冻结题库.json`，修正前后记录在 `runs/标注修正差异.json`；图像、问题、分层、已冻结候选均未改动。

“致命并集”指至少有一种致命错误的回答数，用它比较漏报与误报，不给二者设置不同权重。“致命图片数”以图片为单位，避免把同图九个回答当作九张独立照片。

**调用安排与预算**

只请求 `wb/deepseek-v4.1-flash` 与 `gpt-6-luna`，没有请求 hw 路由、GLM 或任何 Claude 模型。DeepSeek 900 次，gpt-6-luna 540 次，共 1440 次；失败 0 次，重试 0 次，最大并发 4。每个实际测量的题目与模型组合都是三次独立 HTTP 请求，未复用上文，不传随机种子。温度使用服务默认值，未强行统一不同模型的采样参数。

Chat Completions 请求带 `User-Agent: curl/8.7.1`，DeepSeek 均传 `thinking: {"type":"disabled"}`，最大输出 300 token，全部响应以 stop 结束。密钥仅从现有配置读入内存，原始结果不含认证头和图片 base64。API 兼容性和响应字段均以本次实际调用为准。

基线与第二轮分别测两模型全部 30 图：各 540 次；第一轮、第三轮各只测 DeepSeek 的 20 图调优集：各 180 次。合计 1440 次。中间轮其他模型和留出集显示“未测”，不是零错误。要把两模型四个版本全量都跑三次需 2160 次，超过预算，因此把留出预算集中在基线和调优选出的候选上。

三轮 DeepSeek 调优完成后，按致命错误回答数选第二轮，冻结其全文和哈希，再补测 gpt 调优及两版本留出。未根据留出结果改写候选；留出后作出的决定是暂不采用新候选。`runs/最终冻结.json` 是第二轮候选的冻结记录，`runs/最终采用决策.json` 是最终保留基线的决定。

**三轮改动与结果**

基线直接提取自当前 `PhotoChatProtocol.swift` 的 `system`，没有用旧的 cases.json 代替。系统消息长度如下，均在 600 汉字内：

'''
report+=table(['版本','含标点字符数','汉字数'],promptinfo)
report+='''

第一轮删除所有具体示例，取消“下半部大物体通常贴近”的强推断，改为优先关注近镜头且截断的外物，区别物体未见与细节不清，并让通行问题报告事实、承认无法确认。DeepSeek 致命并集由 31 降到 17，但新增平地台阶，贴近车体也出现漏报，说明变化没有解决视觉判断本身。

第二轮删去“边缘截断物优先”的捷径，要求确实贴近才说近，补入从近到远升降的台阶方向说明，要求逐字读原文及确认提问前提。DeepSeek 致命并集降到 12，漏报降到 1；超长增到 11，方向错误仍集中在 C_B3_301。后补的 gpt 调优结果退步到致命并集 9，小错 49。

第三轮压缩为五段直白规则，删去升高／降低的对照句，强调有把握的事实、可见高低证据和提问前提。DeepSeek 致命并集回升到 18，小错与超长也增加，新增牌子、台阶与影子外物误报，因此未送留出。上述每轮都有多项成组变化，不能把分数变化单独归因于某一句。

调优集分数：

'''+result_table('调优')
report+='\n\n留出集分数：\n\n'+result_table('留出')
report+='''

第二轮在留出集没有确认安全收益。两模型均没有确认的致命漏报；DeepSeek 两版致命误报均为零，gpt 两版均为一条，错误类型发生变化，候选把影子说成可见坑。候选 DeepSeek 的扶梯与台阶混称记小错，遮挡区域是否另有普通楼梯不确定，未计致命误报。不能因为近物提及较多或总分某项提高，就宣称通用安全性改善。

**短按、长按与陷阱题**

“陷阱”是长按子集，不能与长按相加。基线和第二轮的分类结果如下：

'''
report+=table(['集合','版本','模型','题型','回答数','致命漏报','致命误报','小错','超40字','正确'],mode_rows)
report+='\n\n中间两轮 DeepSeek 调优分类结果：\n\n'+table(['版本','题型','回答数','致命漏报','致命误报','小错','超40字','正确'],inter_rows)
report+='''

三次重复各自的致命错误回答数如下。每列使用相同题目，但请求没有配对随机种子；这只能展示观察到的波动，不能视作独立图片的置信区间。

'''+table(['集合','版本','模型','第1次','第2次','第3次'],repeatrows)
report+='''

**典型原始回答**

以下原文都可在同名轮次与集合的 JSONL 中按图片、题目、重复编号定位。各回答的完整标签与依据保存在对应 `_评分.json`。

'''+table(['版本／集合','模型','图片／题次','回答原文','判据'],example_rows)
report+='''

台阶方向是未解决的核心失败：C_B3_301 的九个 DeepSeek 回答中，基线方向反转 6 次，第二轮反转 7 次；短按三次、直接问方向三次，在第二轮全部说反。gpt 在这张图的两版本都没有方向反转。第二轮的方向说明没有修复 DeepSeek 的该类视觉错误。

另有无法判真假的具体断言未进入致命统计，例如基线把不可读站牌说成 “C86”“COASTAL”，把极暗区域说成黑色挡板，或肯定扶梯运行方向。其真值没有可靠标注，因此没有借这些回答增加误报计数，也不能据其“未扣分”声称正确。相应不确定项在每个评分记录中保留。

**最终推荐的系统提示词全文**

本轮最终建议暂留当前版，下文与 `final_system.txt` 完全一致。没有删掉原示例后把未经验证的版本称为胜出稿。原版的示例诱导、近物推断和方向误报风险仍然存在；这是未找到通用替换版本后的保守采用决定。

```text
'''+final+'''
```

**第二轮候选全文（未采用）**

以下与 `candidate_system.txt` 一致。它在 DeepSeek 调优集较好，尚未通过跨模型与留出确认。

```text
'''+candidate+'''
```

**对本机 0.8B 模型的风险与适用边界**

本轮没有调用本机 MiniCPM-V，也没有用云端结果替代其验证。当前最终推荐保留了前次真机测过的版本；前次五张图的结果只来自 `PHOTO_PROMPT.md`，不是本轮新增实测。

第二轮候选没有占位符或具体场景示例，规则减少到五条、232 汉字，但“从近到远逐级升高／降低”“先判断问题前提再区分未见与模糊”仍是多步判断，小模型可能漏执行，或把方向词当作输出线索。候选对通行问题的固定不确定说明也会占用四十字预算；DeepSeek 的超长增加已经提供了这一风险的实测迹象。

保留的基线同样有风险：椅子、公交车、便利店等具体示例可能被照抄；大而贴边的身体、影子或地面可能被误当近障碍；“看不清就不说”可能造成漏报。基线对长按第六条在本机没有新的验证。本轮没有证实任一文本已同时解决漏报和误报，更没有获得向下楼梯、清晰文字留出或新地点的安全证据。

后续最有价值的工作是补齐真正向下楼梯、不同地点且贴近的外物、可读汉字留出正例，再在本机重复同一冻结题库；优先看方向反转、近物漏报与通行许可，不能只看字数或总正确率。本轮没有为提高分数在提示词中加入车箱、蓝牌、黄色边条等题库专用规则。

**交付与复算**

- `bench.json`：30 图标准答案、问题、分层与图像哈希；`runs/冻结题库.json` 保留冻结前的真值版本。
- `images/`：实际发送的 30 张竖向图；`qa/`：目视选择与裁剪核验图。
- `prompts/`：基线及三轮系统消息；`final_system.txt`：最终暂留的基线；`candidate_system.txt`：未采用的第二轮。
- `runs/*_调优.jsonl`、`runs/*_留出.jsonl`：1440 个原始响应、请求标识、延迟、图像和提示词哈希；`runs/调用台账.jsonl`：1440 次尝试，包含每次调用的序号。
- `runs/*_评分.json`：逐回答五类标记、字数、评分依据及忽略的不确定项；`runs/评分汇总.json`、`runs/分类分数.csv`、`runs/错误清单.csv`：汇总与错误筛选表。
- `prepare_bench.py`：建库；`run_eval.py`：白名单、四并发、三次重复和 1500 次全局预算保护；`review.py`：人工审阅清单；`grade_records.py`、`score.py`、`make_report.py`：复算评分与报告；`verify_results.py`：完整性审计。

在当前目录使用 `.venv/bin/python grade_records.py`、`.venv/bin/python score.py`、`.venv/bin/python make_report.py` 可从原始响应重建评分和报告，不需要再次调用模型。重建图片或更换题目会改变实验输入，应另起实验。本轮所有产出写在当前目录，没有修改 `/Users/kyf/Documents/PRTS` 仓库。
'''
(R/'PROMPT_POLISH.md').write_text(report)
with (R/'runs/分类分数.csv').open('w',newline='',encoding='utf-8-sig') as f:
 w=csv.DictWriter(f,fieldnames=list(S[0]));w.writeheader();w.writerows(S)
error_rows=[]
for p in sorted((R/'runs').glob('*_评分.json')):
 for g in json.loads(p.read_text()):
  if not g['正确']:
   x=byid[g['id']];error_rows.append({'轮次':x['轮次'],'集合':x['集合'],'模型':x['model'],'图片':x['图片'],'题目':x['题目'],'重复':x['重复'],**{k:g[k] for k in ['回答','字数','致命漏报','致命误报','小错','超长','评分依据']}})
with (R/'runs/错误清单.csv').open('w',newline='',encoding='utf-8-sig') as f:
 w=csv.DictWriter(f,fieldnames=list(error_rows[0]));w.writeheader();w.writerows(error_rows)
print('已生成报告，字符数',len(report),'错误或超长回答数',len(error_rows))
