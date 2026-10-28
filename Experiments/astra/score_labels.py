#!/usr/bin/env python3
"""Score adjudicated frame labels, exact frame IDs only. Does not invent missing labels."""
import argparse,collections,csv,json,pathlib
HERE=pathlib.Path(__file__).resolve().parent
ap=argparse.ArgumentParser();ap.add_argument('labels',type=pathlib.Path);ap.add_argument('--replay',type=pathlib.Path,default=HERE/'results/replay.jsonl');ap.add_argument('--gold-only',action='store_true',help='Only accept independent metric distance evidence; visual estimates stay exploratory.');a=ap.parse_args()
rows={(r['epoch'],r['frameID']):r for r in map(json.loads,a.replay.open())}
counts=collections.defaultdict(collections.Counter);excluded=collections.Counter();seen=set()
for label in csv.DictReader(a.labels.open()):
    key=(int(label['epoch']),int(label['frameID']))
    if key in seen:raise ValueError(f'duplicate adjudication {key}')
    seen.add(key)
    truth=label['label_obstacle_1m']
    if truth not in ('yes','no'):excluded['unlabeled_or_uncertain']+=1;continue
    if a.gold_only and label.get('distance_certainty')!='independent_measurement':excluded['no_independent_distance_evidence']+=1;continue
    if key not in rows or rows[key]['missingDepth']:excluded['missing_replay_frame']+=1;continue
    r=rows[key]
    for name,v in r['variants'].items():
        c=counts[name];positive=truth=='yes'
        if v['scenario']=='unknown':c['abstainPositive' if positive else 'abstainNegative']+=1;continue
        # Explicitly score near warnings, not a correct distant-obstacle message against 1m truth.
        predicted=v['scenario']!='clear' and v.get('distance',float('inf'))<=1
        c['TP' if predicted and positive else 'FP' if predicted else 'FN' if positive else 'TN']+=1
result={}
for name,c in counts.items():
    tp=c['TP'];result[name]=dict(c,precision=tp/(tp+c['FP']) if tp+c['FP'] else None,recallIncludingAbstention=tp/(tp+c['FN']+c['abstainPositive']) if tp+c['FN']+c['abstainPositive'] else None)
print(json.dumps(dict(goldOnly=a.gold_only,excluded=excluded,variants=result,note='Exact labeled 5Hz frame population only. Distance uncertainty and temporal correlation require separate audit; no truth is interpolated to 10Hz.'),ensure_ascii=False,indent=2))
