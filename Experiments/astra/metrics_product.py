#!/usr/bin/env python3
import collections,json,numpy as np
from metrics import HERE,summarize,stats,resample,angles,nearest,contiguous
rows=[json.loads(l) for l in (HERE/'results/product-replay.jsonl').open()]
recorded={(r['epoch'],r['frameID']):r['recorded']['path'] for r in map(json.loads,(HERE/'results/index.jsonl').open()) if r.get('recorded',{}).get('path')}
summary,events=summarize(rows,['baseline','feedback'])
for name,v in summary.items():v['body060ConflictFrames']=sum(r['variants'][name].get('pathCollision060',False) is True for r in rows)
a=collections.defaultdict(list); counts=collections.Counter();last=None
actual=[r['actualDrawing'] for r in rows if r.get('actualDrawing')]
for r in rows:
 d=r.get('drawing')
 if not d:last=None;continue
 counts['frames']+=1;counts['visible']+=d['visible'];counts['fallback']+=d['fallback'];counts['collision']+=d['collision'];counts['smoothedCollision']+=d['collision'] and not d['fallback']
 a['drawingMS'].append(d['ms'])
 if r['groundConfirmed'] and r.get('plane'):
  q=resample(d['after']);pp=r['variants']['baseline'].get('path')
  # The archived recorded baseline plane is recoverable from the original centerline.
  # Use input recorded path explicitly for identical horizontal comparison stations below.
  source=recorded[(r['epoch'],r['frameID'])]['plane'];pn=np.array(source['normal'])
  old=q.copy();old[:,1]=-(source['offset']+pn[0]*q[:,0]+pn[2]*q[:,2])/pn[1]
  nn=np.array(r['plane']['normal']);off=r['plane']['offset']
  a['pairedBeforeGroundError'].extend(abs(old@nn+off));a['pairedAfterGroundError'].extend(abs(q@nn+off))
 for label in ['before','after']:
  p=resample(d[label]);aa,_=angles(p);a[label+'MaxAngle'].append(max(aa,default=0))
  if r['groundConfirmed'] and r.get('plane'):
   a[label+'GroundError'].extend(abs(p@np.array(r['plane']['normal'])+r['plane']['offset']))
 if last and contiguous(last,r) and last['drawing']['routeID']==d['routeID']:
  pairs={k:(resample(d[k]),resample(last['drawing'][k])) for k in ['before','after']}
  if all(len(p)>14 and len(q)>14 for p,q in pairs.values()):
   for k,(p,q) in pairs.items():
    ds=np.r_[nearest(p[6:-6],q)[1],nearest(q[6:-6],p)[1]]
    a[k+'SameIDRMS'].append(float(np.sqrt(np.mean(ds*ds))))
 last=r
foot=collections.defaultdict(list)
for r in rows:
 if r['groundConfirmed'] and r.get('plane') and r['variants']['baseline'].get('reference'):
  pp=r['variants']['baseline']['reference']['plane'];pn=np.array(pp['normal']);cam=np.array(r['pose']['position'])
  projected=cam-pn*(pn@cam+pp['offset']);plane=r['plane']
  foot[str(r['epoch'])].append(abs(np.array(plane['normal'])@projected+plane['offset']))
result={'footPlaneError':{e:stats(v) for e,v in foot.items()},'analysisMS':stats(r['analysisMS'] for r in rows if not r['missingDepth']),'frames':len(rows),'depthFrames':sum(not r['missingDepth'] for r in rows),'recordedMatch':sum(r['baselineMatch'] for r in rows),'metrics':summary,'drawing':{'counts':dict(counts),'metrics':{k:stats(v) for k,v in a.items()}},'actualDisplay':{'input':len(actual),'visible':sum(d['visible'] for d in actual),'fallback':sum(d['fallback'] for d in actual),'collision':sum(d['collision'] for d in actual)},'haptics':dict(collections.Counter(r['haptics'].get('baseline') for r in rows if r['haptics'].get('baseline')))}
tickpath=HERE/'results/product-ticks.jsonl'
if tickpath.exists():
 ticks=[json.loads(l) for l in tickpath.open()];eligible=[t for t in ticks if t['eligible']];blocked=[t for t in eligible if not t['allowed']]
 result['captureFreshness']={'eligible':len(eligible),'suppressed':len(blocked),'clear':sum(t['scenario']=='clear' for t in blocked),'directions':sum(t['hasPath'] for t in blocked),'neverSuccessful':sum('successfulCheck' not in t for t in blocked)}
(HERE/'results/product_metrics.json').write_text(json.dumps(result,indent=2,allow_nan=False))
print(json.dumps(result,indent=2))
