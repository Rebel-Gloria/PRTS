"""验证本次测评的预算、重复、原始响应、评分和冻结完整性。"""
from pathlib import Path
from collections import Counter,defaultdict
from datetime import datetime
import hashlib,io,json,re
from PIL import Image
from score import read_rows
R=Path(__file__).resolve().parent
bench=json.loads((R/'bench.json').read_text());cases={x['id']:x for x in bench['cases']}
assert len(cases)==30
assert Counter(x['split'] for x in cases.values())=={'调优':20,'留出':10}
assert len(list((R/'images').glob('*.jpg')))==30
assert sum(t['trap'] for c in cases.values() for t in c['tasks'])==30
assert all(len(c['tasks'])==3 for c in cases.values())
for c in cases.values():
 p=R/c['image'];assert hashlib.sha256(p.read_bytes()).hexdigest()==c['preprocess']['sha256']
 im=Image.open(R/c['source'])
 if c['preprocess']['顺时针旋转90度']:im=im.transpose(Image.Transpose.ROTATE_270)
 top=c['preprocess']['顶部裁剪像素'];im=im.crop((0,top,im.width,im.height))
 assert list(im.size)==c['preprocess']['尺寸']
 f=io.BytesIO();im.save(f,format='JPEG',quality=95);assert hashlib.sha256(f.getvalue()).hexdigest()==c['preprocess']['sha256']
ledger=list(map(json.loads,(R/'runs/调用台账.jsonl').read_text().splitlines()))
assert len(ledger)==1440 and len(ledger)<=1500
assert [x['序号'] for x in ledger]==list(range(1,1441))
assert set(x['model'] for x in ledger)=={'wb/deepseek-v4.1-flash','gpt-6-luna'}
assert all(x['尝试']==1 for x in ledger)
raw=[];seen=set();grades=[]
for p in sorted((R/'runs').glob('*_调优.jsonl'))+sorted((R/'runs').glob('*_留出.jsonl')):
 rows=read_rows(p);raw+=rows
 score=json.loads(p.with_name(p.stem+'_评分.json').read_text());graded={x['id']:x for x in score};grades+=score
 assert set(graded)=={x['id'] for x in rows}
 grouping=defaultdict(list)
 for x in rows:
  assert x['id'] not in seen;seen.add(x['id'])
  assert x['成功'] and x['原始响应']['choices'][0]['finish_reason']=='stop'
  assert x['回答']==x['原始响应']['choices'][0]['message']['content'].strip()
  c=cases[x['图片']];assert c['split']==x['集合']
  task=next(t for t in c['tasks'] if t['id']==x['题目']);assert task['text']==x['用户消息']
  assert x['图像sha256']==c['preprocess']['sha256']
  system=(R/'prompts'/f"{x['轮次']}.txt").read_text().strip()
  assert x['系统提示词sha256']==hashlib.sha256(system.encode()).hexdigest()
  g=graded[x['id']];assert x['回答']==g['回答']
  assert g['字数']==len(re.sub(r'\s','',x['回答']))
  assert g['超长']==(g['字数']>40)
  assert g['正确']==(not any(g[k] for k in ['致命漏报','致命误报','小错','超长']))
  assert g['未评分的不确定项']==c['truth']['不确定']
  grouping[(x['model'],x['图片'],x['题目'])].append(x['重复'])
 assert all(sorted(v)==[1,2,3] for v in grouping.values())
assert len(raw)==1440 and len(grades)==1440
assert {x['调用序号'] for x in raw}==set(range(1,1441))
assert Counter(x['model'] for x in raw)=={'wb/deepseek-v4.1-flash':900,'gpt-6-luna':540}
frozen=json.loads((R/'runs/最终冻结.json').read_text())
assert hashlib.sha256((R/'runs/冻结题库.json').read_bytes()).hexdigest()==frozen['bench_sha256']
assert hashlib.sha256((R/'candidate_system.txt').read_text().strip().encode()).hexdigest()==frozen['提示词sha256']
original=json.loads((R/'runs/冻结题库.json').read_text())
for old in original['cases']:
 new=cases[old['id']]
 for key in ['id','source','image','split','scene','tags','preprocess','tasks']:assert new[key]==old[key]
freeze_time=datetime.fromisoformat(frozen['冻结时间UTC'])
assert all(datetime.fromisoformat(x['时间'])>freeze_time for x in ledger if x['集合']=='留出')
assert (R/'final_system.txt').read_text().strip()==(R/'prompts/基线.txt').read_text().strip()
for p in list((R/'prompts').glob('*.txt'))+[R/'final_system.txt',R/'candidate_system.txt']:
 assert len(re.findall(r'[\u3400-\u9fff]',p.read_text()))<=600
assert not (R/'runs/调用失败.jsonl').exists()
results={'结论':'通过','图片数':30,'调优图片':20,'留出图片':10,'任务数':90,'原始成功回答数':1440,'已逐条评分数':1440,'调用次数':1440,'失败及重试':0,'模型调用数':dict(Counter(x['model'] for x in raw)),'三次重复完整':True,'候选冻结前无留出调用':True,'最终推荐':'原样保留基线','候选':'第二轮，未采用','最大并发':'执行器固定4，所有轮次顺序启动','图像来源与预处理哈希':'30张全部匹配','最终提示词汉字数':len(re.findall(r'[\u3400-\u9fff]',(R/'final_system.txt').read_text())),'不确定属性复核':'仅修改真值，不修改题目、图片、分层或候选'}
(R/'runs/完整性审计.json').write_text(json.dumps(results,ensure_ascii=False,indent=2));print(json.dumps(results,ensure_ascii=False))
