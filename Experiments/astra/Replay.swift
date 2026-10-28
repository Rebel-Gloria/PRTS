// Full saved-depth replay, CPU only. Experimental state/geometry, never product changes.
import Foundation
import CryptoKit
import simd
@testable import SpatialCore

struct Ref: Decodable { let file: String, codec: String, sha256: String; let offset: UInt64?; let directory:String?; let compressedBytes: Int, uncompressedBytes: Int }
struct Header: Decodable {
    let width: Int, height: Int, depthBytes: Int, confidenceBytes: Int
    let epoch: UInt64, frameID: UInt64, parameterVersion: UInt64
    let timestamp: Double, pose: RigidPose, intrinsics: CameraIntrinsics
    let parameters: ProbeParameters, priors: [FloorPrior], directionStable: Bool, source: String
}
struct Capture: Decodable {
    let epoch: UInt64, frameID: UInt64, parameterVersion: UInt64
    let timestamp: Double, receivedAt: Double
    let pose: RigidPose, intrinsics: CameraIntrinsics, trackingNormal: Bool, directionStable: Bool
}
struct Publication: Decodable { var publishTime: Double?; var publicationReason: String? }
struct Input: Decodable {
    let epoch: UInt64, frameID: UInt64, parameterVersion: UInt64, timestamp: Double
    let capture: Capture, parameters: ProbeParameters, attachment: Ref?, reset: Bool
    let options: PathOptions, recorded: PathUpdate?, publication: Publication
    let recordedPlane: GroundPlane?, recordedDiagnostics: AnalysisDiagnostics?
}
struct Cluster: Codable { var distance: Float; var support: Int; var center: V3 }
struct Raw: Codable {
    var clusters: [Cluster] = []; var allLaneClusters: [Cluster] = []
    var cells: Int = 0; var highConfidencePoints: Int = 0
}
enum AstraCoverage {
    static func fraction(_ points: [V3], result: AnalysisResult?, width: Float, length: Float) -> Float {
        guard let grid = result?.grid, points.count >= 2 else { return 0 }
        let route = RouteArc.prefix(points,length:length)
        let total = RouteArc.length(route)
        guard total >= min(length,0.5) else { return 0 }
        var hit=0, count=0
        for (a,b) in zip(route,route.dropFirst()) {
            let v=b-a, d=simd_length(v); guard d>0.001 else { continue }
            let side=simd_normalize(simd_cross(v,grid.basis.normal))
            let n=max(1,Int(ceil(d/0.05)))
            for i in 0...n { for offset in stride(from:-width/2,through:width/2+0.001,by:0.05) {
                let p=grid.basis.local(a+v*Float(i)/Float(n)+side*offset);count+=1
                if let j=grid.index(x:p.x,z:p.z),grid.cells[j].state == .candidate { hit+=1 }
            }}
        }
        return count>0 ? Float(hit)/Float(count) : 0
    }
}
func rawEvidence(_ r: AnalysisResult) -> Raw {
    guard let g=r.grid else { return Raw() }
    var raw=Raw();raw.highConfidencePoints=r.diagnostics?.sampledPoints ?? 0
    // Connected sampled high-confidence obstacle cells, including 1/2-point cells.
    var seen=Set<Int>()
    for seed in g.cells.indices where g.cells[seed].obstacleSamples>0 && !seen.contains(seed) {
        var q=[seed];seen.insert(seed);var at=0
        while at<q.count {
            let i=q[at];at+=1
            for (dx,dz) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let x=i%g.columns+dx,z=i/g.columns+dz
                if x<0 || x>=g.columns || z<0 || z>=g.rows { continue }
                let j=z*g.columns+x
                if g.cells[j].obstacleSamples>0 && seen.insert(j).inserted {q.append(j)}
            }
        }
        for cutoff:Float in [1,4] {
            // This camera-forward 0.60m body band is a fixed audit definition for ALL variants.
            let lane=q.filter { let p=g.center($0);return abs(p.x)<=0.3+g.cellSize/2+0.000001 && p.y-g.cellSize/2<=cutoff+0.000001 }
            guard !lane.isEmpty else {continue}
            let support=lane.reduce(0){$0+g.cells[$1].obstacleSamples}
            let d=lane.map{g.center($0).y-g.cellSize/2}.min()!
            let center=lane.reduce(V3.zero){$0+g.basis.world(x:g.center($1).x,h:0,z:g.center($1).y)*Float(g.cells[$1].obstacleSamples)}/Float(support)
            let c=Cluster(distance:d,support:support,center:center)
            if cutoff==1 {raw.clusters.append(c);raw.cells+=lane.count} else {raw.allLaneClusters.append(c)}
        }
    }
    return raw
}
struct FastHazard {
    var history: [(Double, [Cluster])]=[]
    var until: Double = -.infinity
    var lastDistance: Float?
    let support: Int, hits: Int, immediate: Bool
    mutating func update(_ raw: Raw, at t: Double) -> Float? {
        history.removeAll { t-$0.0>0.26 }
        let now=raw.clusters.filter{$0.support>=support}
        history.append((t,now));if history.count>3 {history.removeFirst()}
        var accepted:[Float]=[]
        for c in now {
            let n=history.filter{h in h.1.contains{simd_distance($0.center,c.center)<=0.25}}.count
            if (immediate && c.distance<=0.5+0.000001) || n>=hits {accepted.append(c.distance)}
        }
        if let d=accepted.min() {until=t+0.2;lastDistance=d}
        return t<=until ? lastDistance : nil
    }
}
struct ExperimentalPlanner {
    var filter=AstraOccupancyGrid(), planner=AstraWaypointPlanner()
    mutating func update(_ result:AnalysisResult, options:PathOptions, view:RouteCameraView) -> PathUpdate {
        let start=ProcessInfo.processInfo.systemUptime
        guard let p=filter.apply(result,forwardLength:options.forwardBufferLength,routeForward:planner.planningForward) else {return .init(reason:"occupancy_waiting_reference")}
        planner.measuredResult=result
        let camera=result.sourcePose.flatMap{filter.projected(result,forwardLength:options.forwardBufferLength,forward:-$0.back)}
        var u=planner.update(result:p,cameraResult:camera,options:options,view:view)
        u.confirmedObstacles=p.planningObstacles;u.occupancyFilter=filter.diagnostics
        u.continuity = .init(epoch:result.epoch,parameterVersion:result.parameterVersion,frameID:result.frameID,timestamp:result.timestamp,requestID:result.frameID,sourceMapVersion:result.frameID,hazardWatermark:0,routeID:u.path?.id,geometryVersion:0,status:u.path == nil ? (u.waypointGuidance?.scenario == .clear ? .clear : .hazardBlocked) : .planned,remainingVerifiedLength:0,evidenceAge:nil,renewalDistance:options.waypoints.previewDistance,requiredWidth:options.minimumWidth)
        u.continuity?.planningPolicy=RoutePlanningPolicy.obstacleVeto.rawValue
        u.milliseconds=(ProcessInfo.processInfo.systemUptime-start)*1000
        return u
    }
}
struct Variant: Encodable {
    var scenario: String, reason: String
    var distance: Float?, path: PredictedPath?, reference: ForwardRouteReference?
    var confirmedCount: Int, speech: String?, speechSeverity: Int?, planningMS: Double
    var heading: Float?, coverage: Float?, rebases: Int?
    var pathCollision050: Bool?, pathCollision060: Bool?, pathCollision090: Bool?
}
func severity(_ c:ObstacleRouteSpeech) -> Int {
    switch c { case .clear:return 0;case .blocked:return 3;case .obstacle(let d,_),.adjustCamera(let d):return (d ?? 99)<1 ? 2:1 }
}
func collision(_ points:[V3], _ footprints:[OccupancyFootprint], _ width:Float)->Bool {
    zip(points,points.dropFirst()).contains {a,b in footprints.contains{$0.overlaps(from:a,to:b,radius:width/2)}}
}
struct Output: Encodable {
    var epoch:UInt64,frameID:UInt64,timestamp:Double,publishTime:Double,missingDepth:Bool,tracking:Bool,directionStable:Bool
    var pose:RigidPose,intrinsics:CameraIntrinsics,plane:GroundPlane?,groundConfirmed:Bool,groundMode:String?,raw:Raw
    var variants:[String:Variant],confirmed:[OccupancyFootprint],rawFootprints:[OccupancyFootprint]
    var haptics:[String:String], baselineMatch:Bool, experimentalMatch:Bool, planeDelta:Float?, analysisMS:Double
    var groundSamples:[V3]
    var drawing:DrawingOutput?
}
@main enum Replay {
    static func main() throws {
        if CommandLine.arguments.count==2,CommandLine.arguments[1]=="--self-test" {selfTests();return}
        guard CommandLine.arguments.count>=3 else {fatalError("Replay <run> <index.jsonl> [limit]")}
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]), index=URL(fileURLWithPath:CommandLine.arguments[2])
        let decoder=JSONDecoder();decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let lines=try String(contentsOf:index,encoding:.utf8).split(separator:"\n")
        let analyzer=SpatialAnalyzer()
        var predictors=[PathPredictor(),PathPredictor(),PathPredictor()]
        func experimental()->[ExperimentalPlanner] {
            var x=Array(repeating:ExperimentalPlanner(),count:5)
            for i in 1..<5 {x[i].filter.planeMode=1;x[i].filter.planeThreshold=i==2 ? 0.12:0.04;x[i].planner.adaptivePlane=true}
            x[3].planner.visibilityMode=1;x[4].planner.visibilityMode=2
            return x
        }
        var exp=experimental()
        let names=["baseline","width060","width090","seam","plane004","plane012","visibility060","visibility100"]
        let fastNames=["fast6_1","fast6_2","fast12_3"]
        func fasts()->[FastHazard] {[.init(support:6,hits:2,immediate:true),.init(support:6,hits:2,immediate:false),.init(support:12,hits:3,immediate:false)]}
        var fast=fasts(),speeches=[String:ObstacleRouteAnnouncementPolicy]()
        var urgent=[AstraSpeechPolicy(),AstraSpeechPolicy(),AstraSpeechPolicy()];urgent[0].escalationDwell=0;urgent[2].escalationDwell=0
        var haptics=PathHapticPolicy(), ah=[AstraHapticPolicy(),AstraHapticPolicy()];ah[0].entry=8
        var epoch:UInt64=0,count=0,draw=DrawingPrototype(),lastGoal:UInt64?
        var published=[String:PathUpdate]()
        for line in lines {
            let input=try decoder.decode(Input.self,from:Data(line.utf8))
            if CommandLine.arguments.count>3,count>=Int(CommandLine.arguments[3])! {break}
            let output:Output=try autoreleasepool {
                if epoch != input.epoch || input.reset {
                    analyzer.reset();predictors=[PathPredictor(),PathPredictor(),PathPredictor()];exp=experimental();fast=fasts()
                    speeches=[:];urgent=[AstraSpeechPolicy(),AstraSpeechPolicy(),AstraSpeechPolicy()];urgent[0].escalationDwell=0;urgent[2].escalationDwell=0
                    haptics=PathHapticPolicy();ah=[AstraHapticPolicy(),AstraHapticPolicy()];ah[0].entry=8;draw=DrawingPrototype();epoch=input.epoch;published=[:];lastGoal=nil
                }
                var observation:DepthObservation?,header:Header?
                if let ref=input.attachment {
                    guard ref.codec=="deflate-raw",!ref.file.contains("/"),ref.compressedBytes<64*1024*1024 else {fatalError("bad attachment")}
                    let encoded:Data
                    if let directory=ref.directory {
                        encoded=try Data(contentsOf:URL(fileURLWithPath:directory).appendingPathComponent(ref.file))
                        guard encoded.count==ref.compressedBytes else {fatalError("bad Dev attachment size")}
                    } else {
                        let f=try FileHandle(forReadingFrom:dir.appendingPathComponent(ref.file));defer{try? f.close()}
                        try f.seek(toOffset:ref.offset!)
                        let size=try f.read(upToCount:8)!
                        guard size.count==8,size.withUnsafeBytes({$0.loadUnaligned(as:UInt32.self).littleEndian})==ref.compressedBytes,
                            size.withUnsafeBytes({$0.loadUnaligned(fromByteOffset:4,as:UInt32.self).littleEndian})==ref.uncompressedBytes else {fatalError("bad size")}
                        encoded=try f.read(upToCount:ref.compressedBytes)!
                    }
                    let raw=try (encoded as NSData).decompressed(using:.zlib) as Data
                    guard raw.count==ref.uncompressedBytes,SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined()==ref.sha256 else {fatalError("checksum")}
                    let n=Int(raw.withUnsafeBytes{$0.loadUnaligned(as:UInt32.self).littleEndian})
                    let h=try decoder.decode(Header.self,from:raw.subdata(in:4..<4+n));header=h
                    guard h.epoch==input.epoch,h.frameID==input.frameID,h.source=="device",raw.count==4+n+h.depthBytes+h.confidenceBytes else {fatalError("identity")}
                    let depth=raw.withUnsafeBytes{b in (0..<h.width*h.height).map{Float(bitPattern:b.loadUnaligned(fromByteOffset:4+n+$0*4,as:UInt32.self).littleEndian)}}
                    observation = .init(width:h.width,height:h.height,depth:depth,confidence:h.confidenceBytes>0 ? Array(raw.suffix(h.confidenceBytes)):nil,intrinsics:h.intrinsics,pose:h.pose,timestamp:h.timestamp,frameID:h.frameID,epoch:h.epoch)
                }
                let r:AnalysisResult
                if let o=observation,let h=header,input.capture.trackingNormal {
                    r=analyzer.analyze(o,priors:h.priors,parameters:h.parameters,parameterVersion:h.parameterVersion,directionStable:h.directionStable,source:"device_replay")
                } else {
                    if input.capture.trackingNormal {analyzer.missingDepth(pose:input.capture.pose,time:input.timestamp,frameID:input.frameID,epoch:input.epoch,parameterVersion:input.parameterVersion)} else {analyzer.reset()}
                    var missing=AnalysisResult(epoch:input.epoch,frameID:input.frameID,timestamp:input.timestamp,parameters:input.parameters,parameterVersion:input.parameterVersion,status:"missing_depth")
                    missing.sourcePose=input.capture.pose;r=missing
                }
                let raw=rawEvidence(r), now=input.publication.publishTime ?? input.timestamp
                let view=RouteCameraView(intrinsics:input.capture.intrinsics)
                var updates=[PathUpdate]()
                for i in 0..<3 {
                    var options=input.options
                    if i==1 {options.minimumWidth=0.6};if i==2 {options.minimumWidth=0.9}
                    updates.append(predictors[i].update(result:r,observation:observation,options:options,cameraView:view))
                }
                for i in exp.indices {updates.append(exp[i].update(r,options:input.options,view:view))}
                let base=updates[0]
                func same(_ a:PathUpdate,_ b:PathUpdate?)->Bool {
                    guard let b else {return false}
                    let ap=a.path?.points ?? [],bp=b.path?.points ?? []
                    return a.reason==b.reason && a.waypointGuidance?.scenario==b.waypointGuidance?.scenario && ap.count==bp.count && zip(ap,bp).allSatisfy{simd_distance($0,$1)<0.0001}
                }
                var allNames=names
                for i in fast.indices {
                    let d=fast[i].update(raw,at:input.timestamp)
                    var u=base
                    if let d,u.waypointGuidance?.scenario == .clear {
                        u.waypointGuidance?.scenario = .nearObstacle;u.waypointGuidance?.obstacleDistance=d;u.reason="fast_raw_warning";u.path=nil
                    }
                    allNames.append(fastNames[i]);updates.append(u)
                }
                var variants=[String:Variant](),hpp=[String:String]()
                if let goal=base.goal?.id,goal != lastGoal {
                    haptics=PathHapticPolicy();ah=[AstraHapticPolicy(),AstraHapticPolicy()];ah[0].entry=8;lastGoal=goal
                }
                let heading=input.capture.directionStable ? base.path.flatMap{PathTracking.heading(path:$0,pose:input.capture.pose,lookAhead:input.options.lookAhead)} : nil
                if input.capture.trackingNormal {
                    if let p=haptics.update(heading:heading,now:now,enabled:true,threshold:12){hpp["baseline"]=p.kind}
                    for i in ah.indices {if let p=ah[i].update(heading:heading,now:now,enabled:true,threshold:12){hpp[i==0 ? "entry8":"entry12"]=p.kind}}
                }
                for (name,candidate) in zip(allNames,updates) {
                    var gate=ResultPresentationGate()
                    gate.enabled=input.capture.trackingNormal;gate.trackingNormal=input.capture.trackingNormal
                    gate.epoch=input.epoch;gate.parameterVersion=input.parameterVersion;gate.frameID=input.frameID
                    gate.frameTimestamp=input.timestamp;gate.maxAge=input.parameters.maxResultAge
                    // Source-frame publication gate; original wall-clock completion times.
                    // No model of UIKit scheduling/audio completion is invented.
                    let prior=candidate.reason == "fast_raw_warning" ? PathUpdate() : (published[name] ?? .init())
                    let decision=RoutePublicationPolicy.decide(current:prior,candidate:candidate,gate:gate,hazardWatermark:0,now:now,expectedPolicy:.obstacleVeto)
                    let u=decision.update;published[name]=u
                    let foot=u.path.map{$0.plane.project(input.capture.pose.position)}
                    let pts=u.path.map{[foot!]+$0.points}
                    let confirmed=u.confirmedObstacles ?? []
                    let h=input.capture.directionStable ? u.path.flatMap{PathTracking.heading(path:$0,pose:input.capture.pose,lookAhead:input.options.lookAhead)} : nil
                    let cue=input.capture.trackingNormal ? speeches[name,default:.init()].cue(update:u,heading:h,now:now,deviationDegrees:12):nil
                    let i=names.firstIndex(of:name)
                    variants[name] = .init(scenario:input.capture.trackingNormal ? (u.waypointGuidance?.scenario.rawValue ?? "unknown") : "unknown",reason:u.reason,distance:u.waypointGuidance?.obstacleDistance,path:u.path,reference:u.strategy?.reference,confirmedCount:confirmed.count,speech:cue?.chinese,speechSeverity:cue.map(severity),planningMS:u.milliseconds,heading:h?.angleDegrees,coverage:i.flatMap{$0>=3 ? exp[$0-3].planner.selectedCoverage:nil},rebases:i.flatMap{$0>=3 ? exp[$0-3].planner.rebaseCount:nil},pathCollision050:pts.map{collision($0,confirmed,0.5)},pathCollision060:pts.map{collision($0,confirmed,0.6)},pathCollision090:pts.map{collision($0,confirmed,0.9)})
                }
                for i in urgent.indices {
                    if i==2 {urgent[i].allowEscalation = input.timestamp<=fast[2].until}
                    let c=input.capture.trackingNormal ? urgent[i].cue(update:base,heading:heading,now:now,deviationDegrees:12):nil
                    var v=variants["baseline"]!;v.speech=c?.chinese;v.speechSeverity=c.map(severity);variants[["speech0","speech020","speechProof"][i]]=v
                }
                let confirmed=base.confirmedObstacles ?? []
                let fp:[OccupancyFootprint]=r.grid.map{g in g.cells.indices.filter{g.cells[$0].obstacleSamples>0}.map{i in .init(center:g.basis.world(x:g.center(i).x,h:0,z:g.center(i).y),right:g.basis.right,forward:g.basis.forward,size:g.cellSize)}} ?? []
                var groundSamples:[V3]=[]
                if let o=observation, let plane=r.plane,base.path != nil {
                    groundSamples=o.points(parameters:r.parameters).filter{abs(plane.height($0))<=r.parameters.planeTolerance}
                }
                let drawing=draw.process(update:base,result:r,observation:observation)
                return .init(epoch:input.epoch,frameID:input.frameID,timestamp:input.timestamp,publishTime:now,missingDepth:observation==nil,tracking:input.capture.trackingNormal,directionStable:input.capture.directionStable,pose:input.capture.pose,intrinsics:input.capture.intrinsics,plane:r.plane,groundConfirmed:r.diagnostics?.groundConfirmed ?? false,groundMode:r.diagnostics?.groundReferenceMode,raw:raw,variants:variants,confirmed:confirmed,rawFootprints:fp,haptics:hpp,baselineMatch:same(base,input.recorded),experimentalMatch:same(base,updates[3]),planeDelta:r.plane.flatMap{p in input.recordedPlane.map{abs(p.height(input.capture.pose.position)-$0.height(input.capture.pose.position))}},analysisMS:r.stageMilliseconds["analysisTotal"] ?? 0,groundSamples:Array(groundSamples.enumerated().filter{$0.offset%4==0}.map(\.element)),drawing:drawing)
            }
            print(String(decoding:try encoder.encode(output),as:UTF8.self));count+=1
            if count%200==0 {FileHandle.standardError.write(Data("replayed \(count)/\(lines.count)\n".utf8))}
        }
    }
}

func selfTests() {
    let route:[V3]=[V3(-1,0,0),.zero,V3(0,0,-1)]
    let obstacle=OccupancyFootprint(center:V3(-0.03,0,-0.03),right:V3(1,0,0),forward:V3(0,0,1),size:0.004)
    precondition(!collision(route,[obstacle],0.02))
    precondition(collision(rounded(route,radius:0.12),[obstacle],0.02),"rounding must be collision checked")
    precondition(!withinHorizontalDeviation([V3(-1,0,0.2),V3(0,0,0.2)],reference:route))
    let (mesh,widthError)=joinedRibbon(route,normal:V3(0,1,0),camera:.zero)
    precondition(!mesh.isEmpty && widthError<0.00001)
    precondition(mesh.allSatisfy{$0.point.x.isFinite && $0.point.y.isFinite && $0.point.z.isFinite})
    var f=FastHazard(support:12,hits:3,immediate:false)
    let raw=Raw(clusters:[Cluster(distance:0.4,support:12,center:V3(0,0,-0.4))])
    precondition(f.update(raw,at:0)==nil && f.update(raw,at:0.1)==nil && f.update(raw,at:0.2) != nil)
    var gap=FastHazard(support:12,hits:3,immediate:false)
    _=gap.update(raw,at:0);_=gap.update(raw,at:0.1)
    precondition(gap.update(raw,at:0.4)==nil,"missing frames must not complete evidence")
    print("7 Swift prototype assertions passed")
}
