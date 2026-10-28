#!/usr/bin/env python3
"""Secondary integrity, sensitivity, haptic and recorded-tick stall audits."""
import collections,copy,json,pathlib
import numpy as np
from metrics import stats,summarize,qualified,episodes,contiguous
HERE=pathlib.Path(__file__).resolve().parent
rs=[json.loads(l) for l in (HERE/'results/replay.jsonl').open()]
inputs=[json.loads(l) for l in (HERE/'results/index.jsonl').open()]
names=list(rs[0]['variants'])
gaps=json.loads((HERE/'results/missing_frames.json').read_text())
differences=[]
for r,i in zip(rs,inputs):
    if not r['baselineMatch']:
        differences.append(dict(epoch=r['epoch'],frameID=r['frameID'],recordedScenario=i['recorded'].get('waypointGuidance',{}).get('scenario'),replayedScenario=r['variants']['baseline']['scenario'],recordedReason=i['recorded']['reason'],replayedReason=r['variants']['baseline']['reason']))
clean=copy.deepcopy(rs);excluded=[]
for r in clean:
    if not r['baselineMatch'] or any(g['epoch']==r['epoch'] and g['timestamp'] is not None and 0<=r['timestamp']-g['timestamp']<=.75 for g in gaps):
        excluded.append([r['epoch'],r['frameID']]);r['missingDepth']=True;r['raw']={'clusters':[],'allLaneClusters':[]}
        for v in r['variants'].values():v['scenario']='unknown';v.pop('path',None);v.pop('speech',None);v.pop('speechSeverity',None)
cleansummary,_=summarize(clean,names)
haptics={}
visibility=collections.Counter()
for r in rs:
    drawing=r.get('drawing')
    if not drawing:continue
    points=np.asarray(drawing['before']);pose=r['pose'];intr=r['intrinsics']
    plane=r['variants']['baseline']['path']['plane'];normal=np.array(plane['normal'])
    for i in range(1,len(points)-1):
        u=points[i]-points[i-1];w=points[i+1]-points[i]
        if min(np.linalg.norm(u),np.linalg.norm(w))<1e-6:continue
        angle=np.degrees(np.arccos(np.clip(u@w/np.linalg.norm(u)/np.linalg.norm(w),-1,1)))
        if angle<=150:continue
        visibility['sharpVerticesAbove150']+=1
        p=points[i]+normal*.025-np.array(pose['position']);z=-(p@pose['back'])
        if z<=.001:continue
        x=intr['fx']*(p@pose['right'])/z+intr['cx'];y=-intr['fy']*(p@pose['up'])/z+intr['cy']
        if -.5<=x<intr['width']-.5 and -.5<=y<intr['height']-.5:visibility['sharpVerticesInImage']+=1
for name in ['baseline','entry8','entry12']:
    pulses=[r for r in rs if r['haptics'].get(name) in ['left_double','right_long']]
    low=[r for r in pulses if abs(r['variants']['baseline'].get('heading',99))<12]
    haptics[name]={'turnPulses':len(pulses),'smallAnglePulses':len(low),'smallAngles':[r['variants']['baseline'].get('heading') for r in low]}
width={}
for name in ['baseline','width060','width090','plane004','plane012','visibility060','visibility100']:
    vv=[r['variants'][name] for r in rs]
    width[name]={f'collision{w}':sum(v.get(f'pathCollision{w}',False) for v in vv) for w in ['050','060','090']}
    width[name]['rebases']=sum(max((r['variants'][name].get('rebases',0) for r in rs if r['epoch']==e),default=0) for e in range(1,5))
    width[name]['coverage']=stats([v['coverage'] for v in vv if 'coverage' in v])
caps=[json.loads(l) for l in (HERE/'results/captures.jsonl').open()]
stalls=[]
for e in range(1,5):
    epoch=[r for r in rs if r['epoch']==e];ticks=[c for c in caps if c['epoch']==e]
    # One actually available steady path and one clear stretch per epoch, when present.
    for kind in ['path','clear']:
        candidates=[(j,r) for j,r in enumerate(epoch) if j>10 and j+15<len(epoch) and
                    (bool(r['variants']['baseline'].get('path')) if kind=='path' else r['variants']['baseline']['scenario']=='clear') and
                    all(contiguous(epoch[k],epoch[k+1]) for k in range(j,j+12))]
        if not candidates:continue
        j,start=candidates[0];begin=start['publishTime']
        for duration in [.3,1.0]:
            window=[c for c in ticks if begin<c['receivedAt']<begin+duration and c['trackingNormal'] and c['receivedAt']-c['timestamp']<=.25]
            ages=[c['receivedAt']-start['timestamp'] for c in window]
            stalls.append(dict(epoch=e,frameID=start['frameID'],kind=kind,stallSeconds=duration,ticks=len(ages),sourceAge=stats(ages),suppressed={str(tt):sum(a>tt for a in ages) for tt in [.15,.25,.5]}))
summary={'recordedPathsInAnalysisIndex':sum(bool(i['recorded'].get('path')) for i in inputs),'recordedProjections':sum(bool(i['recorded'].get('projection')) for i in inputs),'drawingVisibility':dict(visibility),'differences':differences,'quarantineFrames':len(excluded),'quarantineIdentities':excluded,'quarantine':{n:{k:cleansummary[n][k] for k in ['observedSeconds','near1','falseProxy','flips']} for n in names},'haptics':haptics,'widthAndPlane':width,'stallExperiments':stalls,'rawNSensitivity':{f'N{n}_D{d}':{name:{'qualified':sum(q),'missFrames':sum(a and r['variants'][name]['scenario']=='clear' for a,r in zip(q,rs))} for name in ['baseline','fast6_1','fast6_2','fast12_3']} for n in [1,2,3,4] for d in [.5,1] for q,_ in [qualified(rs,d,n)]}}
(HERE/'results/audit.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in summary.items() if k not in ['quarantine','quarantineIdentities','stallExperiments']},ensure_ascii=False,indent=2))
