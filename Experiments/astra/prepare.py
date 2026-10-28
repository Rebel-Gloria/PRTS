#!/usr/bin/env python3
"""Create a small replay index and instrumented experimental classes; never edit product code."""
import argparse, collections, hashlib, json, pathlib, sys
ROOT = pathlib.Path(__file__).resolve().parents[2]
HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / 'scripts'))
from read_dev_capture import decode

def records(p):
    return [json.loads(l) for l in p.open()] if p.exists() else []

def replace_once(s, old, new):
    assert s.count(old) == 1, (old[:100], s.count(old))
    return s.replace(old, new)

def sources():
    core = ROOT/'Vendor/SpatialCore/Sources/SpatialCore'
    generated = HERE/'generated'; generated.mkdir(exist_ok=True)
    s = (core/'TemporalOccupancyGrid.swift').read_text().replace('struct TemporalOccupancyGrid:', 'struct AstraOccupancyGrid:')
    s = s[s.index('/// Obstacle-veto'):]
    s = 'import Foundation\nimport simd\n@testable import SpatialCore\n' + s
    s = s.replace('  private struct Track:', '''  var planeMode = 0
  var planeThreshold: Float = 0.04
  private struct Track:''')
    s = s.replace('mutating func reset() { self = .init() }', 'mutating func reset() { let mode = planeMode; let threshold = planeThreshold; self = .init(); planeMode = mode; planeThreshold = threshold }')
    s = replace_once(s, '    if referencePlane == nil {', '''    // Prototype: accept only current-confirmed ground for adaptive rebasing. World
    // obstacle identities/timers are deliberately retained, never reset by a rebase.
    if planeMode > 0, result.diagnostics?.groundConfirmed == true, let next = result.plane {
      let old = referencePlane
      if old == nil || abs(next.height(old!.project(pose.position))) > planeThreshold ||
          simd_dot(old!.normal, next.normal) < cos(3 * .pi / 180) {
        referencePlane = next
        referenceSource = "astra_confirmed_local_plane"
      }
    }
    if referencePlane == nil {''')
    (generated/'AstraOccupancyGrid.swift').write_text(s)

    s = (core/'ObstacleWaypointPlanner.swift').read_text().replace('struct ObstacleWaypointPlanner:', 'struct AstraWaypointPlanner:')
    s = s.replace('import simd', 'import simd\n@testable import SpatialCore')
    s = s.replace('    private var reference:', '''    var adaptivePlane = false
    var visibilityMode = 0 // 0 original; 1 next 0.6m/80%; 2 next 1m/95%
    var measuredResult: AnalysisResult?
    var selectedCoverage: Float? = nil
    var rebaseCount = 0
    private var reference:''')
    s = replace_once(s, '        let foot = plane.project(pose.position)', '''        if adaptivePlane, let old = reference,
           abs(plane.height(old.plane.project(pose.position))) > 0.00001 || simd_dot(old.plane.normal,plane.normal) < 0.999999 {
            // Preserve horizontal intent; replace y. Do not move x/z by normal projection.
            func lift(_ p: V3) -> V3 { V3(p.x, -(plane.offset+plane.normal.x*p.x+plane.normal.z*p.z)/plane.normal.y, p.z) }
            let origin = lift(old.origin)
            let end = lift(old.origin+old.forward)
            reference = .init(origin:origin,forward:simd_normalize(end-origin),plane:plane)
            if var c = current { c.points = c.points.map(lift); c.plane = plane; current = c }
            if var g = goal { g.point = lift(g.point); g.plane = plane; goal = g }
            continuation = continuation.map(lift)
            if var p = preview { p.points = p.points.map(lift); preview = p }
            previousFoot = previousFoot.map(lift)
            rebaseCount += 1
        }
        let foot = plane.project(pose.position)''')
    s = replace_once(s, 'let outOfView = !arrived && exited && !outOfViewLatched', 'let outOfView = visibilityMode == 0 && !arrived && exited && !outOfViewLatched')
    s = replace_once(s, '''        guard let ref = reference,
              let (visiblePlan,index) = ObstacleWaypointSearch.visiblePlan(plan,pose:pose,view:view,normal:ref.plane.normal,minimumDistance:options.arrivalRadius+0.2) else { return false }
        let plan = visiblePlan''', '''        guard let ref = reference else { return false }
        let selected: (ObstacleWaypointSearch.Plan, Int)?
        if visibilityMode == 0 {
            selected = ObstacleWaypointSearch.visiblePlan(plan,pose:pose,view:view,normal:ref.plane.normal,minimumDistance:options.arrivalRadius+0.2)
        } else {
            // Full-body current visibility proof, not merely a floor-point-in-image test.
            let coverage = AstraCoverage.fraction(plan.points, result:measuredResult, width:options.minimumWidth,
                length:visibilityMode == 1 ? 0.6 : 1.0)
            selectedCoverage = coverage
            selected = coverage >= (visibilityMode == 1 ? 0.8 : 0.95) && plan.points.count >= 2 ? (plan,1) : nil
        }
        guard let (visiblePlan,index) = selected else { return false }
        let plan = visiblePlan''')
    (generated/'AstraWaypointPlanner.swift').write_text(s)

    feedback = (ROOT/'PRTS/Feedback/ObstacleRouteAnnouncementPolicy.swift').read_text()
    (generated/'Speech.swift').write_text(feedback)
    adaptive = feedback.split('nonisolated enum ObstacleRouteSpeech:',1)[0].replace('struct ObstacleRouteAnnouncementPolicy', 'struct AstraSpeechPolicy')
    adaptive = adaptive.replace('    private var observedScenario:', '''    var escalationDwell: Double = 0.2
    var escalationInterval: Double = 0.75
    var allowEscalation = true
    private var spokenSeverity = 0
    private var observedSeverity = 0
    private var severitySince: Double = 0
    private var observedScenario:''')
    adaptive = replace_once(adaptive,'        let first = spokenScenario == nil', '''        let severity = state.scenario == .clear ? 0 : state.scenario == .blocked ? 3 : (state.obstacleDistance ?? 99) <= 1 ? 2 : 1
        if severity != observedSeverity { observedSeverity = severity; severitySince = now }
        let escalating = allowEscalation && severity > spokenSeverity && now-severitySince+0.000001 >= escalationDwell && now-spokenAt+0.000001 >= escalationInterval
        let first = spokenScenario == nil''')
    adaptive = adaptive.replace('guard first || !entered ||', 'guard first || escalating || !entered ||')
    adaptive = adaptive.replace('guard canSpeak, first || now-spokenAt', 'guard canSpeak, first || escalating || now-spokenAt')
    adaptive = adaptive.replace('first || entered || turn != nil || distanceDue', 'first || entered || turn != nil || distanceDue || escalating')
    adaptive = adaptive.replace('spokenAt = now; spokenNear = near; spokenScenario = state.scenario', 'spokenAt = now; spokenNear = near; spokenScenario = state.scenario; spokenSeverity = severity')
    (generated/'AdaptiveSpeech.swift').write_text(adaptive)
    turns = (ROOT/'PRTS/Feedback/FeedbackCoordinator.swift').read_text().split('struct TurnAnnouncementPolicy {',1)[1]
    (generated/'Turns.swift').write_text('import Foundation\nimport SpatialCore\nstruct TurnAnnouncementPolicy {'+turns)
    haptic = (core/'PathHapticPolicy.swift').read_text()
    haptic = '@testable import SpatialCore\n'+haptic[haptic.index('/// One actuator:'):]
    haptic = haptic.replace('PathHapticPolicy', 'AstraHapticPolicy')
    haptic = haptic.replace('    public init() {}', '    public var entry: Float = 12\n    public init() {}')
    haptic = replace_once(haptic, '        alignedSince = nil\n        let nextSide', '''        if side == 0 && angle < entry { mode = "neutral"; return nil }
        alignedSince = nil
        let nextSide''')
    (generated/'Haptics.swift').write_text('import Foundation\n'+haptic)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('diag',type=pathlib.Path);a=ap.parse_args()
    run=next(a.diag.glob('*11-28-26Z*'))
    analysis=records(run/'analysis.jsonl'); captures=records(run/'capture.jsonl'); paths=records(run/'path.jsonl')
    predictions={(r['payload']['epoch'],r['payload']['frameID']):r['payload'] for r in paths if r['payload'].get('phase')=='prediction'}
    pubs={(r['payload']['context']['epoch'],r['payload']['context']['frameID']):r['payload'] for r in paths if r['payload'].get('phase')=='publication' and 'context' in r['payload']}
    limited=collections.defaultdict(list)
    for r in captures:
        c=r['payload']
        if not c['trackingNormal']:limited[c['epoch']].append(c['frameID'])
    counts=collections.defaultdict(collections.Counter);missing=[];last={};output=[]
    for row in analysis:
        f=row['payload']['frame'];c=row['payload']['capture']; key=(f['epoch'],f['frameID']);e=key[0]
        counts[e]['analysis']+=1;counts[e]['depth']+=int('attachment' in row)
        if 'attachment' not in row:missing.append({'epoch':e,'frameID':key[1],'timestamp':f['timestamp'],'trackingNormal':c['trackingNormal'],'expected':row['payload'].get('depthAttachmentExpected')})
        reset=any(last.get(e,0)<n<=key[1] for n in limited[e])
        last[e]=key[1]
        pred=predictions.get(key,{});pub=pubs.get(key,{})
        output.append(dict(epoch=e,frameID=key[1],timestamp=f['timestamp'],capture=c,parameters=f['parameters'],parameterVersion=f['parameterVersion'],attachment=row.get('attachment'),reset=reset,options=pred.get('options',{}),recorded=pred.get('update'),publication=pub,recordedPlane=f.get('plane'),recordedDiagnostics=row['payload'].get('diagnostics')))
    out=HERE/'results';out.mkdir(exist_ok=True)
    with (out/'captures.jsonl').open('w') as f:
        for r in captures:f.write(json.dumps(r['payload'],separators=(',',':'))+'\n')
    samples=[]
    for d in sorted(run.glob('dev-capture-*')):
        for r in records(d/'samples.jsonl'):
            samples.append(dict(directory=str(d),**r))
    (out/'samples.json').write_text(json.dumps(samples,indent=2))
    gaps=sorted([list(k) for k in predictions if k not in {(x['epoch'],x['frameID']) for x in output}])
    sample_map={(s['epoch'],s['frameID']):s for s in samples}
    recovered=[];unrecovered=[]
    for e,fid in gaps:
        sample=sample_map.get((e,fid))
        if sample is None or sample.get('depth') is None:
            unrecovered.append([e,fid]);continue
        directory=pathlib.Path(sample['directory']);ev=json.loads(decode(directory,sample['evidence']))
        # The original Dev Capture depth header contains priors/parameters too. Verify
        # this exact attachment independently, then let Swift recompute all perception.
        from read_diag import depth_frame
        header,_,_=depth_frame(decode(directory,sample['depth']))
        assert (header['epoch'],header['frameID'])==(e,fid)
        assert all(k in header for k in ['priors','parameters','directionStable'])
        analysis_ev=ev['analysis'];ref=dict(sample['depth'],directory=str(directory))
        output.append(dict(epoch=e,frameID=fid,timestamp=header['timestamp'],capture=ev['capture'],parameters=header['parameters'],parameterVersion=header['parameterVersion'],attachment=ref,reset=False,options=ev['pathOptions'],recorded=predictions[(e,fid)]['update'],publication=pubs.get((e,fid),{}),recordedPlane=analysis_ev.get('plane'),recordedDiagnostics=analysis_ev.get('diagnostics')))
        recovered.append(dict(epoch=e,frameID=fid,directory=str(directory),depth=sample['depth']))
    output.sort(key=lambda r:(r['epoch'],r['frameID']));last={}
    for row in output:
        e=row['epoch'];row['reset']=any(last.get(e,0)<n<=row['frameID'] for n in limited[e]);last[e]=row['frameID']
    with (out/'index.jsonl').open('w') as f:
        for row in output:f.write(json.dumps(row,separators=(',',':'))+'\n')
    capture_map={(r['payload']['epoch'],r['payload']['frameID']):r['payload'] for r in captures}
    missing_rows=missing+[dict(epoch=e,frameID=f,timestamp=capture_map.get((e,f),{}).get('timestamp'),reason='analysis_record_absent_depth_not_replayed') for e,f in unrecovered]
    (out/'missing_frames.json').write_text(json.dumps(missing_rows,indent=2))
    (out/'recovered_frames.json').write_text(json.dumps(recovered,indent=2))
    manifest={'run':str(run),'epochs':dict(counts),'missing':missing,'samples':len(samples),'captureRows':len(captures),'pathPredictions':len(predictions),'pathPublications':len(pubs),'analysisIndexGaps':gaps,'unrecoveredGaps':unrecovered,'recoveredFrames':recovered,'replayFrames':len(output),'sourceHashes':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [ROOT/'Vendor/SpatialCore/Sources/SpatialCore'/n for n in ['Analysis.swift','PathPrediction.swift','TemporalOccupancyGrid.swift','ObstacleWaypointPlanner.swift','PathDrawing.swift']]}}
    (out/'inventory.json').write_text(json.dumps(manifest,indent=2));print(json.dumps(manifest,indent=2))
    sources()

if __name__=='__main__': main()
