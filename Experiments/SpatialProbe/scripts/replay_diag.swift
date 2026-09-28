// Offline measured-depth replay, NOT a live-device/Metal/performance/safety acceptance test.
// Compile together with Core/Sources/SpatialCore/*.swift using swiftc -O -parse-as-library.
import Foundation
import CryptoKit
import Darwin

private struct ReplayHeader: Decodable {
    let width: Int,height: Int,depthBytes: Int,confidenceBytes: Int
    let epoch: UInt64,frameID: UInt64,timestamp: Double,parameterVersion: UInt64
    let pose: RigidPose,intrinsics: CameraIntrinsics
    let parameters: ProbeParameters,priors: [FloorPrior],directionStable: Bool,source: String
}
private struct ReplayAttachment: Decodable {
    let file: String,codec: String,sha256: String,offset: UInt64,compressedBytes: Int,uncompressedBytes: Int
}
private struct ReplayFrame: Decodable {
    let epoch: UInt64,frameID: UInt64,timestamp: Double
    let surfaceModel: SurfaceModelSummary?
}
private struct ReplayCapture: Decodable { let epoch: UInt64,frameID: UInt64,trackingNormal: Bool }
private struct ReplayCaptureRow: Decodable { let payload: ReplayCapture }
private struct ReplayPayload: Decodable {
    let frame: ReplayFrame,capture: ReplayCapture
    let diagnostics: AnalysisDiagnostics?
}
private struct ReplayRow: Decodable { let payload: ReplayPayload,attachment: ReplayAttachment? }
private enum ReplayError: Error { case invalid(String) }
@main private enum ReplayDiagnostics {
    static func main() {
        do { try run() } catch {
            FileHandle.standardError.write(Data("Replay failed: \(error)\n".utf8)); exit(1)
        }
    }
    private static func run() throws {
        guard CommandLine.arguments.count == 2 else { throw ReplayError.invalid("usage: replay-diag <launch-directory>") }
        let directory = URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true),decoder = JSONDecoder()
        let manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:directory.appendingPathComponent("manifest.json"))) as? [String:Any]
        guard manifest?["source"] as? String == "device" else {
            throw ReplayError.invalid("This measured-device replay tool rejects synthetic/simulator/unknown sources; never relabel them as device data.")
        }
        let captureText = try String(contentsOf:directory.appendingPathComponent("capture.jsonl"),encoding:.utf8)
        let limited = try captureText.split(separator:"\n").map { try decoder.decode(ReplayCaptureRow.self,from:Data($0.utf8)).payload }.filter { !$0.trackingNormal }
        let lines = try String(contentsOf:directory.appendingPathComponent("analysis.jsonl"),encoding:.utf8).split(separator:"\n")
        let analyzer = SpatialAnalyzer()
        var processed = 0,beforeNonempty = 0,afterNonempty = 0,beforeAnyModel = 0,afterAnyModel = 0,retainedGuidance = 0
        var excluded = 0,missingDepth = 0,lastFrame: UInt64 = 0,lastEpoch: UInt64 = 0
        var modes: [String:Int] = [:],blocks: [String:Int] = [:],rows: [[String:Any]] = []
        for line in lines {
            let row = try decoder.decode(ReplayRow.self,from:Data(line.utf8)),f = row.payload.frame
            if f.epoch != lastEpoch || limited.contains(where:{ $0.epoch == f.epoch && $0.frameID > lastFrame && $0.frameID <= f.frameID }) {
                analyzer.reset()
            }
            lastFrame = f.frameID; lastEpoch = f.epoch
            guard row.payload.capture.trackingNormal else { analyzer.reset(); excluded += 1; continue }
            guard let attachment = row.attachment else { analyzer.reset(); missingDepth += 1; continue }
            guard attachment.file.range(of:#"^data-[0-9]{5,}\.bin$"#,options:.regularExpression) != nil,
                  attachment.codec == "deflate-raw",attachment.compressedBytes > 0,attachment.compressedBytes <= 64*1024*1024,
                  attachment.uncompressedBytes > 0,attachment.uncompressedBytes <= 64*1024*1024 else { throw ReplayError.invalid("attachment limits") }
            let file = try FileHandle(forReadingFrom:directory.appendingPathComponent(attachment.file)); defer { try? file.close() }
            try file.seek(toOffset:attachment.offset)
            guard let size = try file.read(upToCount:8),size.count == 8,
                  size.withUnsafeBytes({ $0.loadUnaligned(as:UInt32.self).littleEndian }) == attachment.compressedBytes,
                  size.withUnsafeBytes({ $0.loadUnaligned(fromByteOffset:4,as:UInt32.self).littleEndian }) == attachment.uncompressedBytes,
                  let encoded = try file.read(upToCount:attachment.compressedBytes),encoded.count == attachment.compressedBytes else { throw ReplayError.invalid("truncated attachment") }
            let raw = try (encoded as NSData).decompressed(using:.zlib) as Data
            guard raw.count == attachment.uncompressedBytes,raw.count >= 4,
                  SHA256.hash(data:raw).map({ String(format:"%02x",$0) }).joined() == attachment.sha256 else { throw ReplayError.invalid("checksum") }
            let n = Int(raw.withUnsafeBytes { $0.loadUnaligned(as:UInt32.self).littleEndian })
            guard n > 0,n <= raw.count-4 else { throw ReplayError.invalid("header") }
            let h = try decoder.decode(ReplayHeader.self,from:raw.subdata(in:4..<4+n))
            guard h.source == "device",h.epoch == f.epoch,h.frameID == f.frameID,h.width > 0,h.height > 0,h.width < 8192,h.height < 8192,
                  h.depthBytes == h.width*h.height*4,[0,h.width*h.height].contains(h.confidenceBytes),
                  raw.count == 4+n+h.depthBytes+h.confidenceBytes else { throw ReplayError.invalid("depth identity/size") }
            let depth: [Float] = raw.withUnsafeBytes { bytes in (0..<(h.width*h.height)).map {
                Float(bitPattern:bytes.loadUnaligned(fromByteOffset:4+n+$0*4,as:UInt32.self).littleEndian)
            }}
            let confidence = h.confidenceBytes == 0 ? nil : Array(raw.suffix(h.confidenceBytes))
            let o = DepthObservation(width:h.width,height:h.height,depth:depth,confidence:confidence,intrinsics:h.intrinsics,
                pose:h.pose,timestamp:h.timestamp,frameID:h.frameID,epoch:h.epoch)
            let r = analyzer.analyze(o,priors:h.priors,parameters:h.parameters,parameterVersion:h.parameterVersion,
                directionStable:h.directionStable,source:"device_replay")
            processed += 1
            let before = (f.surfaceModel?.groundTriangles ?? 0)+(f.surfaceModel?.protrusionTriangles ?? 0)
            let after = r.surfaceModel?.triangles.count ?? 0
            if f.surfaceModel != nil { beforeAnyModel += 1 }; if r.surfaceModel != nil { afterAnyModel += 1 }
            if before > 0 { beforeNonempty += 1 }; if after > 0 { afterNonempty += 1 }
            let mode = r.diagnostics?.groundReferenceMode ?? "none"; modes[mode,default:0] += 1
            for reason in r.diagnostics?.modelBlockReasons ?? [] { blocks[reason,default:0] += 1 }
            if mode == "retained_world_reference",!r.segments.isEmpty || !r.distances.isEmpty || r.grid?.cells.contains(where:{ $0.state == .candidate }) == true { retainedGuidance += 1 }
            rows.append(["epoch":f.epoch,"frameID":f.frameID,"timestamp":f.timestamp,"beforeTriangles":before,"afterTriangles":after,
                         "referenceMode":mode,"modelBlocks":r.diagnostics?.modelBlockReasons ?? [],"source":"device_replay",
                         "confirmationCount":r.diagnostics?.groundConfirmationCount ?? 0,
                         "worldPlaneOffsetDelta":r.diagnostics?.planeOffsetDelta ?? -1,
                         "localPlaneHeightDelta":r.diagnostics?.planeLocalHeightDelta ?? -1,
                         "planeNormalDeltaDegrees":r.diagnostics?.planeNormalDeltaDegrees ?? -1,
                         "samplingStep":r.surfaceModel?.summary.samplingStep ?? 0,
                         "surfaceMS":r.stageMilliseconds["surfaceModel"] ?? 0,
                         "groundFitMS":r.stageMilliseconds["groundFit"] ?? 0,
                         "gridClearanceMS":r.stageMilliseconds["gridClearance"] ?? 0,
                         "groundGridMS":r.stageMilliseconds["groundGrid"] ?? 0,
                         "analysisMS":r.stageMilliseconds["analysisTotal"] ?? 0,
                         "candidateCells":r.grid?.cells.filter { $0.state == .candidate }.count ?? 0])
        }
        let summary: [String:Any] = ["source":"device_replay","run":directory.lastPathComponent,"replayedDepthFrames":processed,
            "excludedTrackingLimited":excluded,"normalFramesWithoutDepth":missingDepth,
            "beforeAnyModel":beforeAnyModel,"afterAnyModel":afterAnyModel,"beforeNonemptyModel":beforeNonempty,"afterNonemptyModel":afterNonempty,
            "referenceModes":modes,"modelBlockReasons":blocks,"retainedReferenceWithCandidatesOrGuidance":retainedGuidance,"frames":rows,
            "limitations":"Saved analysis frames only; dropped records are absent. Not a full ARSession replay, live rendering test, ground truth or device performance measurement. History wireframes are not counted. Tracking interruptions use recorded capture metadata; unrecorded events cannot be reconstructed."]
        print(String(decoding:try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
