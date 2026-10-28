"""汇总人工逐回答标注；不调用模型，也不自动猜测语义正确性。"""
import collections,json,re,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent

def read_rows(path):
 return sorted((json.loads(s) for s in path.read_text().splitlines() if s),key=lambda r:(r['图片'],r['model'],r['题目'],r['重复']))
def annotate(filename,issues,model=None):
 """issues: 索引 -> [(漏报/误报/小错, 依据)]。调用即确认已人工审阅整份文件。"""
 bench={c['id']:c for c in json.loads((ROOT/'bench.json').read_text())['cases']}
 p=ROOT/'runs'/filename;rows=read_rows(p);rows=[r for r in rows if model is None or r['model']==model];out=[]
 for i,r in enumerate(rows):
  flags=issues.get(i,[]);answer=r['回答'];chars=len(re.sub(r'\s','',answer));labels={k:False for k in ['致命漏报','致命误报','小错']}
  reasons=[]
  for code,reason in flags:
   labels[{'漏报':'致命漏报','误报':'致命误报','小错':'小错'}[code]]=True;reasons.append(reason)
  labels['超长']=chars>40;labels['正确']=not any(labels.values())
  out.append({'id':r['id'],'审阅索引':i,'审阅范围模型':model or '文件全部模型','回答':answer,'字数':chars,'汉字数':len(re.findall(r'[\u3400-\u9fff]',answer)),**labels,'评分依据':'；'.join(reasons) if reasons else '符合本题可核实事实；标准答案不确定项未计错。','未评分的不确定项':bench[r['图片']]['truth']['不确定'],'评分者':'主代理逐条审阅，无外部裁判调用'})
 dest=p.with_name(p.stem+'_评分.json')
 if model is not None and dest.exists():
  existing=json.loads(dest.read_text());new_ids={r['id'] for r in out};out=[r for r in existing if r['id'] not in new_ids]+out
 dest.write_text(json.dumps(out,ensure_ascii=False,indent=2));print(dest.name,len(out))

def summarize():
 output=[]
 for p in sorted((ROOT/'runs').glob('*_评分.json')):
  grade=json.loads(p.read_text());byid={r['id']:r for r in grade}
  raw=p.with_name(p.name.replace('_评分.json','.jsonl'));rows=read_rows(raw)
  if set(byid)!=set(r['id'] for r in rows):raise ValueError('评分不完整：'+str(p))
  groups=collections.defaultdict(list)
  for r in rows:groups[(r['轮次'],r['集合'],r['model'])].append((r,byid[r['id']]))
  for (rnd,split,model),rs in groups.items():
   for mode in ['全部','短按','长按','陷阱']:
    filtered=[(r,g) for r,g in rs if mode=='全部' or r['模式']==mode or (mode=='陷阱' and r['陷阱'])]
    severe={r['图片'] for r,g in filtered if g['致命漏报'] or g['致命误报']}
    output.append({'轮次':rnd,'集合':split,'模型':model,'题型':mode,'回答数':len(filtered),'致命漏报':sum(g['致命漏报'] for r,g in filtered),'致命误报':sum(g['致命误报'] for r,g in filtered),'致命错误回答数':sum(g['致命漏报'] or g['致命误报'] for r,g in filtered),'小错':sum(g['小错'] for r,g in filtered),'超长':sum(g['超长'] for r,g in filtered),'正确':sum(g['正确'] for r,g in filtered),'有致命错误的图片数':len(severe)})
 (ROOT/'runs/评分汇总.json').write_text(json.dumps(output,ensure_ascii=False,indent=2))
 for r in output:
  if r['题型']=='全部':print(r)
if __name__=='__main__':summarize()
