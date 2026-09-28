// Offline gate replay of RECORDED MODEL OUTPUT, never real-time performance or physical GT.
// Build with the local SpatialCore module; see Docs/NO_LIDAR.md.
import Foundation
import CryptoKit
import SpatialCore
struct ReplayPrediction: Decodable {
    let epoch: UInt64, frameID: UInt64, parameterVersion: UInt64
    let timestamp: Double, orientation: ImageOrientation
    let pose: RigidPose, intrinsics: CameraIntrinsics
    let nativePlanes: [NativePlaneObservation], scaleSamples: [ScaleSample]
    let calibration: InverseDepthCalibration?
    let manual: Bool?
}
struct ReplayCapture: Decodable { let epoch: UInt64,frameID: UInt64; let trackingNormal: Bool;let directionStable: Bool? }
struct ReplayAttachment: Decodable { let file: String,codec: String,sha256: String; let offset: UInt64; let compressedBytes: Int,uncompressedBytes: Int }
struct ReplayRow<T:Decodable>: Decodable { let payload: T; let attachment: ReplayAttachment? }
struct ReplayResult: Encodable {
    let source = "offline_recorded_model_output_replay_not_ground_truth"
    let epoch: UInt64,frameID: UInt64
    let timestamp: Double
    let recordedConfirmed: Bool,fitSucceeded: Bool
    let decision: MetricScaleDecision,ground: NativeGroundSelection
    var path: PathUpdate? = nil
}
@main struct ReplayMonocular {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else { throw NSError(domain:"usage: replay_monocular DIAG_DIRECTORY [--paths]",code:1) }
        let root = URL(fileURLWithPath:CommandLine.arguments[1]),decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity:"+inf",negativeInfinity:"-inf",nan:"nan")
        func rows<T:Decodable>(_ name: String, _: T.Type) throws -> [ReplayRow<T>] {
            try String(contentsOf:root.appendingPathComponent(name),encoding:.utf8).split(separator:"\n").map { try decoder.decode(ReplayRow<T>.self,from:Data($0.utf8)) }
        }
        let captures = try rows("capture.jsonl",ReplayCapture.self).map(\.payload)
        let limited = captures.filter { !$0.trackingNormal }
        let normal = Dictionary(uniqueKeysWithValues:captures.map { ("\($0.epoch):\($0.frameID)",$0.trackingNormal) })
        let directions = Dictionary(uniqueKeysWithValues:captures.map { ("\($0.epoch):\($0.frameID)",$0.directionStable ?? false) })
        let predictions = try rows("prediction.jsonl",ReplayPrediction.self)
        let replayPaths = CommandLine.arguments.contains("--paths")
        var pathPredictor = PathPredictor()
        var tracker = MetricScaleTracker(),ground = NativeGroundTracker(),last: ReplayPrediction?,output: [ReplayResult] = []
        for row in predictions {
            let r = row.payload
            if r.manual == true { continue }
            let tracked = normal["\(r.epoch):\(r.frameID)"] ?? false
            let reset = last == nil || last!.epoch != r.epoch || last!.parameterVersion != r.parameterVersion || last!.orientation != r.orientation || !tracked || limited.contains { $0.epoch == r.epoch && $0.frameID > (last?.frameID ?? 0) && $0.frameID < r.frameID }
            if reset { tracker.reset(); ground.reset(); pathPredictor.reset() }
            guard let ref = row.attachment,ref.codec == "deflate-raw",ref.file.range(of:"^data-[0-9]{5,}\\.bin$",options:.regularExpression) != nil,
                  ref.uncompressedBytes > 0,ref.uncompressedBytes <= 64*1024*1024,ref.compressedBytes > 0,ref.compressedBytes <= 64*1024*1024 else { throw NSError(domain:"Invalid attachment",code:2) }
            let handle = try FileHandle(forReadingFrom:root.appendingPathComponent(ref.file))
            try handle.seek(toOffset:ref.offset)
            let block = try handle.read(upToCount:ref.compressedBytes+8) ?? Data(); try handle.close()
            guard block.count == ref.compressedBytes+8,block.withUnsafeBytes({ Int(UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self))) }) == ref.compressedBytes,
                  block.withUnsafeBytes({ Int(UInt32(littleEndian:$0.loadUnaligned(fromByteOffset:4,as:UInt32.self))) }) == ref.uncompressedBytes else { throw NSError(domain:"Attachment length mismatch",code:3) }
            let raw = try (Data(block.dropFirst(8)) as NSData).decompressed(using:.zlib) as Data
            guard raw.count == ref.uncompressedBytes,SHA256.hash(data:raw).map({String(format:"%02x",$0)}).joined() == ref.sha256 else { throw NSError(domain:"Attachment checksum mismatch",code:4) }
            let headerLength = raw.withUnsafeBytes { Int(UInt32(littleEndian:$0.loadUnaligned(as:UInt32.self))) }
            let start = 4+headerLength,n = r.intrinsics.width*r.intrinsics.height
            guard headerLength > 0,n > 0,raw.count == start+n*4 else { throw NSError(domain:"Prediction payload mismatch",code:5) }
            let values = raw.withUnsafeBytes { p in (0..<n).map { Float(bitPattern:UInt32(littleEndian:p.loadUnaligned(fromByteOffset:start+$0*4,as:UInt32.self))) } }
            let fit = tracked ? InverseDepthCalibration.fit(r.scaleSamples) : nil
            let g = tracked ? ground.update(r.nativePlanes,camera:r.pose,time:r.timestamp) : NativeGroundSelection(mode:"invalid",reason:"tracking_not_normal")
            let d = tracker.update(.init(timestamp:r.timestamp,epoch:r.epoch,parameterVersion:r.parameterVersion,orientation:r.orientation,intrinsics:r.intrinsics,pose:r.pose,relative:values,samples:r.scaleSamples,fit:fit))
            var pathUpdate: PathUpdate?
            if replayPaths {
                let parameters = ProbeParameters()
                var observation: DepthObservation?
                if tracked,let calibration = d.calibration {
                    let depths = values.map { calibration.meters($0) ?? .nan }
                    var o = DepthObservation(width:r.intrinsics.width,height:r.intrinsics.height,depth:depths,confidence:nil,intrinsics:r.intrinsics,pose:r.pose,timestamp:r.timestamp,frameID:r.frameID,epoch:r.epoch)
                    o.predictionSupport = depths.map { $0.isFinite && $0 >= parameters.minDepth && $0 <= parameters.maxDepth ? 1 : 0 }; observation = o
                }
                var analysis = observation.map { PredictedGeometry.analyze($0,ground:g.plane,parameters:parameters,parameterVersion:r.parameterVersion,groundReference:g) }
                    ?? AnalysisResult(epoch:r.epoch,frameID:r.frameID,timestamp:r.timestamp,parameters:parameters,parameterVersion:r.parameterVersion,status:"replay unavailable scale")
                analysis.sourcePose = r.pose
                if d.invalidatesHistory { if analysis.diagnostics == nil { analysis.diagnostics = AnalysisDiagnostics() }; analysis.diagnostics?.groundReferenceInvalidation = "metric_world_reference_conflict" }
                if tracked { pathUpdate = pathPredictor.update(result:analysis,observation:observation,options:.init(),directionStable:directions["\(r.epoch):\(r.frameID)"]) }
                else { pathPredictor.reset(); pathUpdate = .init(reason:"tracking_not_normal") }
            }
            output.append(.init(epoch:r.epoch,frameID:r.frameID,timestamp:r.timestamp,recordedConfirmed:r.calibration != nil,fitSucceeded:fit != nil,decision:d,ground:g,path:pathUpdate)); last = r
        }
        print(String(data:try DiagnosticJSON.encode(output),encoding:.utf8)!)
    }
}
