#!/usr/bin/env python3
"""Copy the exact product source tree, with a hash manifest. No algorithm patching."""
import hashlib, json, pathlib, shutil, subprocess, sys, os
import prepare
REPO=prepare.ROOT; ROOT=pathlib.Path(os.environ.get("ASTRA_SOURCE_ROOT",str(REPO))); HERE=prepare.HERE
prepare.sources=lambda:None
prepare.ROOT=ROOT
prepare.main()
dest=HERE/'generated/ProductCore'
if dest.exists():shutil.rmtree(dest)
shutil.copytree(ROOT/'Vendor/SpatialCore',dest,ignore=shutil.ignore_patterns('.build','.swiftpm'))
shutil.copyfile(ROOT/'PRTS/Feedback/ObstacleRouteAnnouncementPolicy.swift',HERE/'generated/ProductSpeech.swift')
turns=(ROOT/'PRTS/Feedback/FeedbackCoordinator.swift').read_text().split('struct TurnAnnouncementPolicy {',1)[1]
(HERE/'generated/ProductTurns.swift').write_text('import Foundation\nimport SpatialCore\nstruct TurnAnnouncementPolicy {'+turns)
core=dest/'Sources/SpatialCore' 
fresh=(core/'ObstacleFeedbackFreshness.swift').exists()
drawing=(core/'GroundRouteDrawing.swift').exists()
(HERE/'generated/ProductAdapter.swift').write_text('''import Foundation
import simd
@testable import SpatialCore
func legacyFeedbackAllowed(_ update:PathUpdate,gate:ResultPresentationGate,now:Double)->Bool {
    guard update.waypointGuidance != nil,let context=update.continuity else{return false}
    return gate.enabled && gate.trackingNormal && context.epoch==gate.epoch &&
        context.parameterVersion==gate.parameterVersion && context.frameID>=gate.minimumGeometryFrameID &&
        context.frameID<=gate.frameID && now>=gate.frameTimestamp && now-gate.frameTimestamp<=gate.maxAge
}
func feedbackAllowed(_ update:PathUpdate,gate:ResultPresentationGate,now:Double)->Bool {
'''+('    ObstacleFeedbackFreshness.allows(update,gate:gate,hazardWatermark:0,now:now)' if fresh else '    legacyFeedbackAllowed(update,gate:gate,now:now)')+'''
}
func successfulCheck(_ update:PathUpdate)->Double? {
'''+('    update.successfulObstacleCheck?.timestamp' if fresh else '    nil')+'''
}
struct ProductDrawing:Encodable {
    var before:[V3],after:[V3],plane:GroundPlane,routeID:UInt64
    var fallback:Bool,visible:Bool,collision:Bool,ms:Double
}
func productDrawing(update:PathUpdate,recorded:PathUpdate?,result:AnalysisResult)->ProductDrawing? {
    // Fixed 518-frame population: same recorded intent for both display algorithms.
    guard var path=recorded?.path,let pose=result.sourcePose else{return nil}
    let foot=path.plane.project(pose.position)
    let approach=simd_distance(foot,path.points[0])>0.03 ? [foot,path.points[0]]:[]
    let before=(approach.isEmpty ? []:[foot])+path.points
    let plane=update.strategy?.reference?.plane ?? path.plane
    func lift(_ p:V3)->V3 {V3(p.x,-(plane.offset+plane.normal.x*p.x+plane.normal.z*p.z)/plane.normal.y,p.z)}
    path.points=path.points.map(lift);path.plane=plane
    let p=PathPresentation(path:path,age:0,historical:false,approach:approach.map(lift))
    let start=ProcessInfo.processInfo.systemUptime
'''+('''    let shape=GroundRouteDrawing.make(p,obstacles:update.confirmedObstacles,bodyWidth:result.parameters.bodyWidth)
    let points=shape.points
    let fallback=shape.usedFallback
    let meshes=PathDrawing.meshes(p,obstacles:update.confirmedObstacles,bodyWidth:result.parameters.bodyWidth)
''' if drawing else '''    let points=(p.approach.isEmpty ? []:[p.approach[0]])+p.path.points
    let fallback=false
    let meshes=PathDrawing.meshes(p)
''')+'''    return .init(before:before,after:points,plane:plane,routeID:path.id,fallback:fallback,
        visible:meshes.contains{$0.role != .target && !$0.vertices.isEmpty},collision:collision(points,update.confirmedObstacles ?? [],0.6),
        ms:(ProcessInfo.processInfo.systemUptime-start)*1000)
}
''')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
files=sorted((ROOT/'Vendor/SpatialCore').rglob('*.swift'))
files=[p for p in files if '.build' not in p.parts and '.swiftpm' not in p.parts]
pairs={str(p.relative_to(ROOT)):{'source':sha(p),'copy':sha(dest/p.relative_to(ROOT/'Vendor/SpatialCore'))} for p in files}
assert all(v['source']==v['copy'] for v in pairs.values())
manifest={'commit':subprocess.check_output(['git','rev-parse','HEAD'],cwd=REPO,text=True).strip(),'dirty':subprocess.check_output(['git','status','--porcelain'],cwd=REPO,text=True),'appHashes':{str(p.relative_to(ROOT)):sha(p) for p in (ROOT/'PRTS').rglob('*.swift')},'sourceRoot':str(ROOT),'sourceTreeSHA256':hashlib.sha256(json.dumps(pairs,sort_keys=True).encode()).hexdigest(),'sources':pairs,'speech':sha(HERE/'generated/ProductSpeech.swift'),'turns':sha(HERE/'generated/ProductTurns.swift'),'adapter':sha(HERE/'generated/ProductAdapter.swift'),'features':{'freshness':fresh,'drawing':drawing}}
(HERE/'results/product_manifest.json').write_text(json.dumps(manifest,indent=2))
