"""受预算限制的三次独立重复测评。密钥只在内存中读取。"""
import argparse,base64,concurrent.futures as cf,datetime,hashlib,json,os,random,threading,time,tomllib,urllib.request
from pathlib import Path
ROOT=Path(__file__).resolve().parent
MODELS=['wb/deepseek-v4.1-flash','gpt-6-luna']
ALLOWED=set(MODELS+['hw/deepseek-v4.1-flash-1017'])
LOCK=threading.Lock()
LEDGER=ROOT/'runs/调用台账.jsonl'
def append(path,obj):
 with path.open('a') as f:
  f.write(json.dumps(obj,ensure_ascii=False)+'\n');f.flush();os.fsync(f.fileno())
def reserve(meta):
 with LOCK:
  n=sum(1 for _ in LEDGER.open()) if LEDGER.exists() else 0
  if n>=1500: raise RuntimeError('调用预算已经用完')
  append(LEDGER,{'序号':n+1,'时间':datetime.datetime.now(datetime.timezone.utc).isoformat(),**meta})
  return n+1

def main():
 p=argparse.ArgumentParser();p.add_argument('round');p.add_argument('--split',choices=['调优','留出'],default='调优');p.add_argument('--models',nargs='+',default=MODELS);a=p.parse_args()
 if not set(a.models)<=ALLOWED:raise ValueError('模型不在授权清单')
 if a.split=='留出' and not (ROOT/'runs/最终冻结.json').exists():raise ValueError('必须先冻结最终提示词')
 (ROOT/'runs').mkdir(exist_ok=True)
 system=(ROOT/'prompts'/f'{a.round}.txt').read_text().strip()
 bench=json.loads((ROOT/'bench.json').read_text())
 config=tomllib.load(open(os.path.expanduser('~/.codex/config.toml'),'rb'))
 token=config['model_providers']['custom']['experimental_bearer_token']
 path=ROOT/'runs'/f'{a.round}_{a.split}.jsonl'
 done={r['id'] for r in map(json.loads,path.read_text().splitlines()) if r.get('成功')} if path.exists() else set()
 jobs=[]
 for case in bench['cases']:
  if case['split']!=a.split:continue
  for model in a.models:
   for task in case['tasks']:
    for rep in range(1,4):
     ident='|'.join([a.round,a.split,model,case['id'],task['id'],str(rep)])
     if ident not in done: jobs.append((ident,case,model,task,rep))
 random.Random(20261029).shuffle(jobs)
 def call(j):
  ident,c,m,t,rep=j
  image=base64.b64encode((ROOT/c['image']).read_bytes()).decode()
  body={'model':m,'stream':False,'max_tokens':300,'messages':[{'role':'system','content':system},{'role':'user','content':[{'type':'text','text':t['text']},{'type':'image_url','image_url':{'url':'data:image/jpeg;base64,'+image}}]}]}
  if 'deepseek' in m:body['thinking']={'type':'disabled'}
  meta={'id':ident,'轮次':a.round,'集合':a.split,'model':m,'图片':c['id'],'题目':t['id'],'重复':rep,'模式':t['mode'],'陷阱':t['trap'],'用户消息':t['text'],'系统提示词sha256':hashlib.sha256(system.encode()).hexdigest(),'图像sha256':c['preprocess']['sha256']}
  for attempt in range(1,4):
   number=reserve({**meta,'尝试':attempt});start=time.monotonic()
   try:
    req=urllib.request.Request('https://cpa.l0ve.icu/v1/chat/completions',json.dumps(body).encode(),{'Authorization':'Bearer '+token,'Content-Type':'application/json','User-Agent':'curl/8.7.1'})
    with urllib.request.urlopen(req,timeout=90) as r:raw=json.load(r)
    choice=raw['choices'][0];answer=(choice['message'].get('content') or '').strip()
    if not answer:raise ValueError('空回答')
    result={**meta,'成功':True,'调用序号':number,'毫秒':round((time.monotonic()-start)*1000),'回答':answer,'原始响应':raw}
    with LOCK:append(path,result)
    return True
   except Exception as e:
    error={'id':ident,'调用序号':number,'尝试':attempt,'错误类型':type(e).__name__,'状态码':getattr(e,'code',None),'毫秒':round((time.monotonic()-start)*1000)}
    with LOCK:append(ROOT/'runs/调用失败.jsonl',error)
  result={**meta,'成功':False,'回答':'','错误':'三次尝试均失败'}
  with LOCK:append(path,result)
  return False
 print(f'{a.round} {a.split}：待测{len(jobs)}条，最多4并发',flush=True)
 with cf.ThreadPoolExecutor(max_workers=4) as ex:
  futures=[ex.submit(call,j) for j in jobs]
  ok=0
  for i,f in enumerate(cf.as_completed(futures),1):
   ok+=f.result()
   if i%20==0 or i==len(futures):print(f'完成 {i}/{len(jobs)}，成功 {ok}',flush=True)
 (ROOT/'runs'/f'{a.round}_{a.split}_配置.json').write_text(json.dumps({'轮次':a.round,'集合':a.split,'模型':sorted({json.loads(line)['model'] for line in path.read_text().splitlines()}),'重复次数':3,'最大并发':4,'最大输出token':300,'温度':'服务默认值，未传入','随机种子':'不传入；调度顺序固定20261029','DeepSeek思考':'disabled','User-Agent':'curl/8.7.1','系统提示词':system,'备注':'基线留出结果在最终冻结之后采集；密钥和base64请求不落盘。'},ensure_ascii=False,indent=2))
if __name__=='__main__':main()
