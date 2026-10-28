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
    var drawing:ProductDrawing?
    var actualDrawing:ProductDrawing?
    var successfulCheck: Double?
}
@main enum Replay {
    static func main() throws {
        
        guard CommandLine.arguments.count>=3 else {fatalError("Replay <run> <index.jsonl> [limit]")}
        let dir=URL(fileURLWithPath:CommandLine.arguments[1]), index=URL(fileURLWithPath:CommandLine.arguments[2])
        let decoder=JSONDecoder();decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys];encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"Infinity",negativeInfinity:"-Infinity",nan:"NaN")
        let lines=try String(contentsOf:index,encoding:.utf8).split(separator:"\n")
        let analyzer=SpatialAnalyzer()
        var predictor=PathPredictor(), speech=ObstacleRouteAnnouncementPolicy(), haptics=PathHapticPolicy()
        var epoch:UInt64=0,count=0,lastGoal:UInt64?
        var published=PathUpdate()
        var tickHistory:[(Double,PathUpdate)] = []
        for line in lines {
            let input=try decoder.decode(Input.self,from:Data(line.utf8))
            if CommandLine.arguments.count>3,count>=Int(CommandLine.arguments[3])! {break}
            let output:Output=try autoreleasepool {
                if epoch != input.epoch || input.reset {
                    analyzer.reset();predictor=PathPredictor();speech=ObstacleRouteAnnouncementPolicy()
                    haptics=PathHapticPolicy();epoch=input.epoch;published=PathUpdate();lastGoal=nil

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
                let base=predictor.update(result:r,observation:observation,options:input.options,cameraView:view)
                var gate=ResultPresentationGate()
                gate.enabled=input.capture.trackingNormal;gate.trackingNormal=input.capture.trackingNormal
                gate.epoch=input.epoch;gate.parameterVersion=input.parameterVersion;gate.frameID=input.frameID
                gate.frameTimestamp=input.timestamp;gate.maxAge=input.parameters.maxResultAge
                let decision=RoutePublicationPolicy.decide(current:published,candidate:base,gate:gate,hazardWatermark:0,now:now,expectedPolicy:.obstacleVeto)
                let u=decision.update;published=u
                var slim=u;slim.confirmedObstacles=nil
                tickHistory.append((now,slim))
                let allowed=feedbackAllowed(u,gate:gate,now:now)
                if let goal=u.goal?.id,goal != lastGoal {haptics=PathHapticPolicy();lastGoal=goal}
                let heading=allowed && input.capture.directionStable ? u.path.flatMap{PathTracking.heading(path:$0,pose:input.capture.pose,lookAhead:input.options.lookAhead)}:nil
                var hpp=[String:String]()
                if input.capture.trackingNormal,let pulse=haptics.update(heading:heading,now:now,enabled:true,threshold:12) {hpp["baseline"]=pulse.kind}
                let cue=allowed && input.capture.trackingNormal ? speech.cue(update:u,heading:heading,now:now,deviationDegrees:12):nil
                let pts=u.path.map{[$0.plane.project(input.capture.pose.position)]+$0.points}
                let footprints=u.confirmedObstacles ?? []
                let state=input.capture.trackingNormal ? (u.waypointGuidance?.scenario.rawValue ?? "unknown") : "unknown"
                let v=Variant(scenario:state,reason:u.reason,distance:u.waypointGuidance?.obstacleDistance,path:u.path,reference:u.strategy?.reference,confirmedCount:footprints.count,speech:cue?.chinese,speechSeverity:cue.map(severity),planningMS:base.milliseconds,heading:heading?.angleDegrees,pathCollision050:pts.map{collision($0,footprints,0.5)},pathCollision060:pts.map{collision($0,footprints,0.6)},pathCollision090:pts.map{collision($0,footprints,0.9)})
                var feedback=v
                if !allowed {feedback.scenario="unknown";feedback.path=nil}
                let variants=["baseline":v,"feedback":feedback]
                func same(_ a:PathUpdate,_ b:PathUpdate?)->Bool {
                    guard let b else {return false}
                    let ap=a.path?.points ?? [],bp=b.path?.points ?? []
                    return a.reason==b.reason && a.waypointGuidance?.scenario==b.waypointGuidance?.scenario && ap.count==bp.count && zip(ap,bp).allSatisfy{simd_distance($0,$1)<0.0001}
                }
                let confirmed=base.confirmedObstacles ?? []
                let fp:[OccupancyFootprint]=r.grid.map{g in g.cells.indices.filter{g.cells[$0].obstacleSamples>0}.map{i in .init(center:g.basis.world(x:g.center(i).x,h:0,z:g.center(i).y),right:g.basis.right,forward:g.basis.forward,size:g.cellSize)}} ?? []
                var groundSamples:[V3]=[]
                if let o=observation, let plane=r.plane,base.path != nil {
                    groundSamples=o.points(parameters:r.parameters).filter{abs(plane.height($0))<=r.parameters.planeTolerance}
                }
                let drawing=productDrawing(update:base,recorded:input.recorded,result:r)
                return .init(epoch:input.epoch,frameID:input.frameID,timestamp:input.timestamp,publishTime:now,missingDepth:observation==nil,tracking:input.capture.trackingNormal,directionStable:input.capture.directionStable,pose:input.capture.pose,intrinsics:input.capture.intrinsics,plane:r.plane,groundConfirmed:r.diagnostics?.groundConfirmed ?? false,groundMode:r.diagnostics?.groundReferenceMode,raw:raw,variants:variants,confirmed:confirmed,rawFootprints:fp,haptics:hpp,baselineMatch:same(base,input.recorded),experimentalMatch:true,planeDelta:r.plane.flatMap{p in input.recordedPlane.map{abs(p.height(input.capture.pose.position)-$0.height(input.capture.pose.position))}},analysisMS:r.stageMilliseconds["analysisTotal"] ?? 0,groundSamples:Array(groundSamples.enumerated().filter{$0.offset%4==0}.map(\.element)),drawing:drawing,actualDrawing:productDrawing(update:base,recorded:base,result:r),successfulCheck:successfulCheck(base))
            }
            print(String(decoding:try encoder.encode(output),as:UTF8.self));count+=1
            if count%200==0 {FileHandle.standardError.write(Data("replayed \(count)/\(lines.count)\n".utf8))}
        }
        // Actual capture ticks, evaluated by the same product freshness gate as the App.
        let captureURL=index.deletingLastPathComponent().appendingPathComponent("captures.jsonl")
        let tickURL=index.deletingLastPathComponent().appendingPathComponent("product-ticks.jsonl")
        FileManager.default.createFile(atPath:tickURL.path,contents:nil)
        let tickFile=try FileHandle(forWritingTo:tickURL);defer{try? tickFile.close()}
        var cursor = -1
        for line in try String(contentsOf:captureURL,encoding:.utf8).split(separator:"\n") {
            let c=try decoder.decode(Capture.self,from:Data(line.utf8))
            while cursor+1<tickHistory.count && tickHistory[cursor+1].0<=c.receivedAt {cursor+=1}
            guard cursor>=0 else{continue}
            let u=tickHistory[cursor].1
            var g=ResultPresentationGate();g.enabled=true;g.trackingNormal=c.trackingNormal
            g.epoch=c.epoch;g.parameterVersion=c.parameterVersion;g.frameID=c.frameID;g.frameTimestamp=c.timestamp
            let eligible=legacyFeedbackAllowed(u,gate:g,now:c.receivedAt)
            let allowed=feedbackAllowed(u,gate:g,now:c.receivedAt)
            let tick=Tick(epoch:c.epoch,frameID:c.frameID,eligible:eligible,allowed:allowed,
                scenario:u.waypointGuidance?.scenario.rawValue ?? "unknown",hasPath:u.path != nil,
                successfulCheck:successfulCheck(u),now:c.receivedAt)
            try tickFile.write(contentsOf:encoder.encode(tick));try tickFile.write(contentsOf:Data([10]))
        }
    }
}
struct Tick:Encodable {
    var epoch:UInt64,frameID:UInt64,eligible:Bool,allowed:Bool,scenario:String,hasPath:Bool
    var successfulCheck:Double?,now:Double
}

