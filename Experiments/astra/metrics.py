#!/usr/bin/env python3
"""Deterministic audit metrics. All counts are proxies, not labels/accuracy."""
import argparse, collections, csv, json, math, pathlib
import numpy as np
HERE=pathlib.Path(__file__).resolve().parent

def stats(x):
    a=np.asarray(list(x),dtype=float);a=a[np.isfinite(a)]
    if not len(a):return dict(n=0,median=None,p95=None,max=None,mean=None)
    return dict(n=len(a),median=float(np.median(a)),p95=float(np.quantile(a,.95)),max=float(a.max()),mean=float(a.mean()))

def resample(points,step=.05):
    p=np.asarray(points,dtype=float)
    if len(p)<2:return p
    d=np.linalg.norm(np.diff(p,axis=0),axis=1);s=np.r_[0,np.cumsum(d)]
    use=np.r_[True,d>1e-7];p=p[use];s=s[use]
    if len(p)<2:return p
    t=np.r_[np.arange(0,s[-1],step),s[-1]]
    return np.stack([np.interp(t,s,p[:,i]) for i in range(3)],axis=1)

def nearest(points,line):
    p=np.asarray(points);l=np.asarray(line)
    if len(p)==0 or len(l)<2:return np.empty((0,3)),np.empty(0)
    a=l[:-1];v=np.diff(l,axis=0);d=np.maximum((v*v).sum(axis=1),1e-12)
    t=np.clip(((p[:,None,:]-a)*v).sum(axis=2)/d,0,1)
    q=a+t[:,:,None]*v;ds=((p[:,None,:]-q)**2).sum(axis=2);ii=ds.argmin(axis=1)
    return q[np.arange(len(p)),ii],np.sqrt(ds[np.arange(len(p)),ii])

def angles(points):
    p=np.asarray(points);v=np.diff(p,axis=0);d=np.linalg.norm(v,axis=1)
    v=v[d>1e-6];d=d[d>1e-6]
    if len(v)<2:return [],[]
    v=v/d[:,None];a=np.arccos(np.clip((v[:-1]*v[1:]).sum(axis=1),-1,1))
    return np.degrees(a).tolist(),(a/((d[:-1]+d[1:])/2)).tolist()

def contiguous(a,b):return a['epoch']==b['epoch'] and 0<b['timestamp']-a['timestamp']<.15 and not a['missingDepth'] and not b['missingDepth'] and a['tracking'] and b['tracking']

def episodes(mask,rows):
    out=[];current=[]
    for i,on in enumerate(mask):
        if on:
            if current and not contiguous(rows[i-1],rows[i]):out.append(current);current=[]
            current.append(i)
        elif current:out.append(current);current=[]
    if current:out.append(current)
    return out

def qualified(rows,distance,n=3,key='clusters'):
    counts=[];previous=[];mask=[];starts=[]
    for i,r in enumerate(rows):
        if i==0 or not contiguous(rows[i-1],r):previous=[]
        nexts=[]
        for c in r['raw'][key]:
            if c['support']<6 or c['distance']>distance+1e-6:continue
            matches=[v for v in previous if np.linalg.norm(np.array(v[0])-c['center'])<=.25]
            count,start=max([(v[1]+1,v[2]) for v in matches],default=(1,i))
            nexts.append((c['center'],count,start))
        qual=[v for v in nexts if v[1]>=n]
        mask.append(bool(qual));starts.append(min((v[2] for v in qual),default=i))
        previous=nexts
    return mask,starts

def future_false(rows,i,window=1.5):
    t=rows[i]['timestamp'];j=i
    while j+1<len(rows) and rows[j]['timestamp']<t+window:
        if not contiguous(rows[j],rows[j+1]):return None
        j+=1
    if rows[j]['timestamp']<t+window:return None
    sub=rows[i:j+1]
    q,_=qualified(sub,4,n=3,key='allLaneClusters')
    tail=[r for r in sub if r['timestamp']>=t+window-.3]
    absent=all(not any(c['support']>=6 for c in r['raw']['allLaneClusters']) for r in tail)
    return not any(q) and absent

def summarize(rows,names):
    dt=[rows[i+1]['timestamp']-r['timestamp'] if i+1<len(rows) and contiguous(r,rows[i+1]) else 0 for i,r in enumerate(rows)]
    duration=sum(dt);result={};events=[]
    qualified_sets={d:qualified(rows,d) for d in [1,.5]}
    for name in names:
        alarm=[r['variants'][name]['scenario'] not in ('clear','unknown') for r in rows]
        clear=[r['variants'][name]['scenario']=='clear' for r in rows]
        unknown=[r['variants'][name]['scenario']=='unknown' for r in rows]
        ep=episodes(alarm,rows)
        # A pre-existing nonclear interval at a log gap is censored rather than a new alarm.
        onsets=[g[0] for g in ep if g[0]>0 and contiguous(rows[g[0]-1],rows[g[0]]) and not alarm[g[0]-1]]
        false={};censored={}
        for w in [1,1.5,2]:
            f=[future_false(rows,i,w) for i in onsets];false[str(w)]=sum(x is True for x in f);censored[str(w)]=sum(x is None for x in f)
        flips=sum(alarm[i]!=alarm[i-1] for i in range(1,len(rows)) if contiguous(rows[i-1],rows[i]) and not unknown[i] and not unknown[i-1])
        metrics={'observedSeconds':duration,'alarmOnsets':len(onsets),'falseProxy':false,'falseCensored':censored,'falsePerMinute':false['1.5']/(duration/60),'flips':flips,'alarmSeconds':sum(d for d,a in zip(dt,alarm) if a),'unknownSeconds':sum(d for d,a in zip(dt,unknown) if a),'blockedFrames':sum(r['variants'][name]['scenario']=='blocked' for r in rows),'pathFrames':sum(bool(r['variants'][name].get('path')) for r in rows),'noVisibleFrames':sum(r['variants'][name]['reason']=='no_visible_target' for r in rows),'speechRequests':sum(r['variants'][name].get('speechSeverity',0)>0 for r in rows),'planningMS':stats([r['variants'][name]['planningMS'] for r in rows if not r['missingDepth']])}
        prior_speech=[];spoken=0;last_epoch=None
        for r in rows:
            if r['epoch']!=last_epoch:spoken=0;last_epoch=r['epoch']
            if r['variants'][name]['scenario'] in ('clear','unknown'):spoken=0
            prior_speech.append(spoken)
            if 'speechSeverity' in r['variants'][name]:spoken=r['variants'][name]['speechSeverity']
        for d,(qual,starts) in qualified_sets.items():
            groups=episodes(qual,rows);miss=[q and c for q,c in zip(qual,clear)]
            latency=[];speechLatency=[];unwarned=0;affected=0;entire=0;unknownEvents=0;unwarned_close=0;previously_warned=0
            for g in groups:
                start=starts[g[0]];end=g[-1]
                hits=[i for i in range(start,end+1) if alarm[i]]
                voiced=[i for i in range(start,end+1) if rows[i]['variants'][name].get('speechSeverity',0)>0]
                if start>0 and contiguous(rows[start-1],rows[start]) and alarm[start-1]:latency.append(0)
                elif hits:latency.append(max(0,rows[hits[0]]['publishTime']-rows[start]['timestamp']))
                if prior_speech[start]>0:speechLatency.append(0);previously_warned+=1
                elif voiced:speechLatency.append(max(0,rows[voiced[0]]['publishTime']-rows[start]['timestamp']))
                else:unwarned+=1
                if prior_speech[start]<2 and not any(rows[i]['variants'][name].get('speechSeverity',0)>=2 for i in range(start,end+1)):unwarned_close+=1
                affected+=any(miss[i] for i in g);entire+=all(clear[i] for i in range(start,end+1));unknownEvents+=any(unknown[i] for i in g)
                events.append(dict(variant=name,distance=d,epoch=rows[start]['epoch'],firstFrame=rows[start]['frameID'],qualifiedFrame=rows[g[0]]['frameID'],lastFrame=rows[end]['frameID'],timestamp=rows[start]['timestamp'],qualifiedFrames=len(g),missFrames=sum(miss[i] for i in g),speechMissing=not bool(voiced) and prior_speech[start]==0))
            metrics['near'+str(d)]={'qualifiedFrames':sum(qual),'episodes':len(groups),'missFrames':sum(miss),'missSeconds':sum(v for v,m in zip(dt,miss) if m),'affectedEvents':affected,'entirelyMissedEvents':entire,'unknownEvents':unknownEvents,'stateLatency':stats(latency),'speechLatency':stats(speechLatency),'noSpeechEvents':unwarned,'noCloseSpeechEvents':unwarned_close,'previouslyWarnedEvents':previously_warned}
        speech=[i for i,r in enumerate(rows) if r['variants'][name].get('speechSeverity',0)>0]
        sf=[future_false(rows,i,1.5) for i in speech]
        metrics['speechFalseProxy']=sum(f is True for f in sf);metrics['speechFalseCensored']=sum(f is None for f in sf)
        result[name]=metrics
    return result,events

def drawings(rows):
    arrays=collections.defaultdict(list);counts=collections.Counter();per_epoch=collections.defaultdict(lambda:collections.defaultdict(list));last=None
    for r in rows:
        d=r.get('drawing')
        # Planning foot discrepancy, valid on confirmed-frame population only.
        if r['groundConfirmed'] and r.get('plane'):
            n=np.array(r['plane']['normal']);offset=r['plane']['offset'];cam=np.array(r['pose']['position'])
            for name in ['baseline','plane004','plane012']:
                ref=r['variants'][name].get('reference')
                if ref:
                    pn=np.array(ref['plane']['normal']);po=ref['plane']['offset'];foot=cam-pn*(pn@cam+po)
                    per_epoch[r['epoch']][name].append(abs(n@foot+offset))
        if not d:last=None;continue
        counts['pathFrames']+=1;counts['accepted']+=d['accepted'];counts['localGroundUsed']+=d['localGroundUsed'];counts['beforeCollision']+=d['beforeCollision'];counts['afterCollision']+=d['afterCollision'];counts['rawCollision']+=d['rawCollision'];counts['body060Collision']+=d['body060Collision']
        if d.get('rejectedReason'):counts[d['rejectedReason']]+=1
        counts['radius'+str(d['smoothingRadius'])]+=d['accepted']
        for k in ['ms','meshMS','beforeVertices','afterVertices','maxWidthError']:arrays[k].append(d[k])
        if not d['accepted']:last=None;continue
        a=resample(d['before']);b=np.array(d['after']);unfiltered=np.array(d['afterUnfiltered'])
        # Paired elevation on exactly the same horizontal stations, with the original
        # planning plane as baseline. This prevents short-path censoring from improving error.
        pp=r['variants']['baseline']['path']['plane'];pn=np.asarray(pp['normal'])
        original_y=-(pp['offset']+pn[0]*b[:,0]+pn[2]*b[:,2])/pn[1]
        original_at_b=b.copy();original_at_b[:,1]=original_y
        if r['groundConfirmed']:
            nn=np.array(r['plane']['normal']);oo=r['plane']['offset']
            arrays['pairedBeforeGroundError'].extend(np.abs(original_at_b@nn+oo).tolist())
            arrays['pairedAfterGroundError'].extend(np.abs(b@nn+oo).tolist())
        ground=np.asarray(r['groundSamples'])
        if len(ground):
            ds=np.linalg.norm(b[:,None,[0,2]]-ground[None,:,[0,2]],axis=2);idx=ds.argmin(axis=1)
            valid=ds[np.arange(len(b)),idx]<.15
            arrays['pairedBeforeObservedGroundYError'].extend(np.abs(original_y[valid]-ground[idx[valid],1]).tolist())
            arrays['pairedAfterObservedGroundYError'].extend(np.abs(b[valid,1]-ground[idx[valid],1]).tolist())
        for label,p in [('before',a),('after',b),('unfiltered',unfiltered)]:
            # Both evaluated at equal arclength spacing for angle/curvature comparability.
            p=resample(p);aa,kk=angles(p);arrays[label+'Angle'].extend(aa);arrays[label+'Curvature'].extend(kk)
            arrays[label+'MaxAnglePerFrame'].append(max(aa,default=0))
            if r['groundConfirmed']:
                n=np.array(r['plane']['normal']);offset=r['plane']['offset']
                arrays[label+'GroundError'].extend(np.abs(p@n+offset).tolist())
                counts['groundComparisonFrames']+=int(label=='before')
            ground=np.asarray(r['groundSamples'])
            if len(ground):
                ds=np.linalg.norm(p[:,None,[0,2]]-ground[None,:,[0,2]],axis=2)
                idx=ds.argmin(axis=1);valid=ds[np.arange(len(p)),idx]<.15
                arrays[label+'ObservedGroundYError'].extend(np.abs(p[valid,1]-ground[idx[valid],1]).tolist())
        arrays['xzDeviation'].extend(nearest(b[:,[0,2]],a[:,[0,2]])[1].tolist())
        arrays['xyzDeviation'].extend(nearest(b,a)[1].tolist())
        arrays['originalSegmentLengths'].extend(np.linalg.norm(np.diff(np.array(d['before']),axis=0),axis=1).tolist())
        arrays['newSegmentLengths'].extend(np.linalg.norm(np.diff(b,axis=0),axis=1).tolist())
        if last and contiguous(last,r) and last['drawing']['accepted']:
            old=last['drawing'];same=old['routeID']==d['routeID'];counts['sameIdPairs' if same else 'newIdPairs']+=1
            triples=[('before',a,old['before']),('after',b,old['after']),('unfiltered',unfiltered,old['afterUnfiltered'])]
            shared=all(len(resample(p))>14 and len(resample(q))>14 for _,p,q in triples)
            for label,p,oldp in triples:
                # Symmetric interior curve distance in world coordinates; remove 0.3m end caps.
                pp=resample(p);oo=resample(oldp)
                if len(pp)>14 and len(oo)>14:
                    ds=np.r_[nearest(pp[6:-6],oo)[1],nearest(oo[6:-6],pp)[1]]
                    rms=float(np.sqrt(np.mean(ds*ds)))
                    arrays[label+'WorldJitter'].append(rms)
                    arrays[label+('StableJitter' if same else 'HandoffJitter')].append(rms)
                    if shared:arrays[label+'PairedJitter'].append(rms)
                    if shared and same:arrays[label+'PairedStableJitter'].append(rms)
                    if shared:
                        qp,_=nearest(pp[6:-6],oo)
                        pose=r['pose'];pos=np.array(pose['position']);axes=np.array([pose['right'],pose['up'],pose['back']]);intr=r['intrinsics']
                        def uv(p):
                            cam=(p-pos)@axes.T;z=-cam[:,2]
                            return np.stack([intr['fx']*cam[:,0]/z+intr['cx'],-intr['fy']*cam[:,1]/z+intr['cy']],axis=1),z
                        u,z=uv(pp[6:-6]);v,zz=uv(qp)
                        valid=(z>.05)&(zz>.05)&np.all(u>=0,axis=1)&(u[:,0]<intr['width'])&(u[:,1]<intr['height'])&np.all(v>=0,axis=1)&(v[:,0]<intr['width'])&(v[:,1]<intr['height'])
                        if np.any(valid):arrays[label+'ReprojectedPixelJitter'].append(float(np.sqrt(np.mean(np.sum((u[valid]-v[valid])**2,axis=1)))*.5))
        last=r
    return {'counts':dict(counts),'metrics':{k:stats(v) for k,v in arrays.items()},'footPlaneError':{str(e):{k:stats(v) for k,v in ds.items()} for e,ds in per_epoch.items()}}

def stale(rows):
    # Evaluate authority at recorded camera timestamps, using recorded publication completion.
    captures=[json.loads(l) for l in (HERE/'results/captures.jsonl').open()]
    byepoch=collections.defaultdict(list)
    for r in rows:byepoch[r['epoch']].append(r)
    values=[];details=[];valid_values=[];valid_details=[];never_valid=0
    for e,rr in byepoch.items():
        ticks=[c for c in captures if c['epoch']==e];i=-1;last_valid=None
        for c in ticks:
            t=c['receivedAt']
            while i+1<len(rr) and rr[i+1]['publishTime']<=t:
                i+=1
                if not rr[i]['missingDepth'] and rr[i]['tracking'] and rr[i].get('plane') and rr[i]['raw']['highConfidencePoints']>0:last_valid=rr[i]['timestamp']
            if i<0 or not c['trackingNormal'] or t-c['timestamp']>.25:continue
            r=rr[i]
            if r['missingDepth'] or not r['tracking']:continue
            age=t-r['timestamp'];values.append(age)
            details.append((age,r['variants']['baseline']['scenario'],bool(r['variants']['baseline'].get('path')),e,c['frameID']))
            if last_valid is None:never_valid+=1
            else:
                va=t-last_valid;valid_values.append(va);valid_details.append((va,r['variants']['baseline']['scenario'],bool(r['variants']['baseline'].get('path'))))
    return {'ages':stats(values),'profiles':{str(tt):{'suppressedTicks':sum(a>tt for a,*_ in details),'suppressedClearTicks':sum(a>tt and s=='clear' for a,s,*_ in details),'suppressedDirectionTicks':sum(a>tt and p for a,s,p,*_ in details)} for tt in [.15,.25,.5]},'successfulEvaluationAges':stats(valid_values),'neverSuccessfulTicks':never_valid,'successfulEvaluationProfiles':{str(tt):{'suppressedTicks':sum(a>tt for a,*_ in valid_details),'suppressedClearTicks':sum(a>tt and s=='clear' for a,s,*_ in valid_details),'suppressedDirectionTicks':sum(a>tt and p for a,s,p in valid_details)} for tt in [.15,.25,.5]},'injectedStallSeconds':{str(tt):{str(stall):max(0,stall-tt) for stall in [.3,1]} for tt in [.15,.25,.5]}}

def annotations(rows,events):
    samples=json.loads((HERE/'results/samples.json').read_text());lookup={(r['epoch'],r['frameID']):r for r in rows};counts=collections.Counter()
    dest=HERE/'results/annotation_manifest.csv'
    fields=['sample_id','epoch','frameID','timestamp','video','pts_seconds','stratum','annotator','label_obstacle_1m','label_obstacle_05m','body_band_visible','distance_certainty','obstacle_kind','bbox_xyxy','reason','episode_id','adjudication']
    with dest.open('w') as f:
        writer=csv.DictWriter(f,fieldnames=fields);writer.writeheader()
        for s in samples:
            r=lookup.get((s['epoch'],s['frameID']));base=r['variants']['baseline']['scenario'] if r else 'missing'
            near=r and any(c['support']>=6 for c in r['raw']['clusters'])
            stratum='raw_near_clear' if near and base=='clear' else 'output_alarm' if base not in ['clear','unknown','missing'] else 'background'
            counts[stratum]+=1
            writer.writerow(dict(sample_id=f"B{s['epoch']}_{s['frameID']}",epoch=s['epoch'],frameID=s['frameID'],timestamp=s['timestamp'],video=str(pathlib.Path(s['directory'])/'camera.mp4'),pts_seconds=s['videoPTSValue']/s['videoPTSTimescale'],stratum=stratum))
    return {'total':len(samples),'epochs':dict(collections.Counter(s['epoch'] for s in samples)),'strata':dict(counts),'doubleReviewDecisions':2*len(samples),'binomialN90pctPlusMinus5pct':math.ceil(1.96**2*.9*.1/.05**2),'binomialNWorstPlusMinus5pct':math.ceil(1.96**2*.25/.05**2)}

def main():
    ap=argparse.ArgumentParser();ap.add_argument('replay',type=pathlib.Path);args=ap.parse_args()
    rows=[json.loads(l) for l in args.replay.open()]
    names=list(rows[0]['variants']);summary,events=summarize(rows,names)
    result={'frames':len(rows),'missingDepth':sum(r['missingDepth'] for r in rows),'baselineMatch':sum(r['baselineMatch'] for r in rows),'experimentalMatch':sum(r['experimentalMatch'] for r in rows),'planeDelta':stats(r['planeDelta'] for r in rows if 'planeDelta' in r),'analysisMS':stats([r['analysisMS'] for r in rows if not r['missingDepth']]),'all':summary,'epochs':{str(e):summarize([r for r in rows if r['epoch']==e],names)[0] for e in sorted({r['epoch'] for r in rows})},'drawing':drawings(rows),'freshness':stale(rows),'annotation':annotations(rows,events),'rawSensitivity':{f'N{n}_D{d}':sum(qualified(rows,d,n)[0]) for n in [2,3,4] for d in [.5,1]},'haptics':{name:dict(collections.Counter(r['haptics'][name] for r in rows if name in r['haptics'])) for name in ['baseline','entry8','entry12']}}
    (HERE/'results/metrics.json').write_text(json.dumps(result,ensure_ascii=False,indent=2,allow_nan=False))
    with (HERE/'results/events.csv').open('w') as f:
        w=csv.DictWriter(f,fieldnames=list(events[0]));w.writeheader();w.writerows(events)
    print(json.dumps({k:v for k,v in result.items() if k not in ['epochs','all','drawing']},ensure_ascii=False,indent=2))
    print('variant FN1_frames FN1_sec FN05_frames FP1.5 FP/min flips blocked paths speech speech_FP')
    for name,v in summary.items():print(name,v['near1']['missFrames'],round(v['near1']['missSeconds'],3),v['near0.5']['missFrames'],v['falseProxy']['1.5'],round(v['falsePerMinute'],3),v['flips'],v['blockedFrames'],v['pathFrames'],v['speechRequests'],v['speechFalseProxy'])

if __name__=='__main__':main()
