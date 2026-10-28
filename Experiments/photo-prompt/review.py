"""输出人工审阅清单，完全不调用模型。"""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('file');p.add_argument('--start',type=int,default=0);p.add_argument('--end',type=int,default=10000);p.add_argument('--model');a=p.parse_args()
rows=list(map(json.loads,Path(a.file).read_text().splitlines()));rows=sorted(rows,key=lambda r:(r['图片'],r['model'],r['题目'],r['重复']))
rows=[r for r in rows if not a.model or r['model']==a.model]
last=None
for n,r in enumerate(rows):
 if not a.start<=n<a.end:continue
 group=(r['图片'],r['model'])
 if group!=last:print('\n'+r['图片']+' '+r['model']);last=group
 print(f"{n:04} {r['题目']}{r['重复']} {r['回答']}")
Path(a.file.replace('.jsonl',('_'+a.model.replace('/','_') if a.model else '')+'_审阅索引.json')).write_text(json.dumps([r['id'] for r in rows],ensure_ascii=False,indent=2))
