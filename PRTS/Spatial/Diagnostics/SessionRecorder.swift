/// Manual spatial sample recorder for depth, confidence, mesh and analysis metadata.

import ARKit

import Foundation
import CoreVideo
import UniformTypeIdentifiers
import SpatialCore

// Value-only transport records must stay usable by the bounded background writer.
nonisolated struct MetricContext: Codable, Sendable {
    var captureFPS: Double
    var analysisFPS: Double
    var droppedFrames: Int
    var meshDrops: Int
    var captureMS: Double
    var meshMS: Double
    var render: RenderMetricRecord
    var tracking: String
    var thermal: String
    var sourceAgeMS: Double
    var outputEligible: Bool
    var displayedFrameID: UInt64
    var geometryOutputEligible: Bool? = nil
    var sensorSkew: String = "not_exposed_by_API"
}
nonisolated struct RenderMetricRecord: Codable, Sendable {
    var fps: Double; var cpuMS: Double; var gpuMS: Double; var presentAgeMS: Double?; var sourceDeltaMS: Double?
    init(_ m: RenderMetrics) { fps = m.fps; cpuMS = m.cpuMS; gpuMS = m.gpuMS; presentAgeMS = m.presentAgeMS; sourceDeltaMS = m.analysisDisplayDeltaMS }
}
nonisolated struct CompactGrid: Codable, Sendable {
    let columns: Int,rows: Int
    let cellSize: Float
    let halfWidth: Float
    let basis: GroundBasis
    let states: Data // 0 unknown, 1 obstacle, 2 candidate; one row-major byte/cell, Base64 in JSON
    let reasons: [String]
    let reasonIndices: Data
    let footprint: Data
    let unknownFraction: Float
    init(_ g: LocalGrid,mask: [Bool]) {
        columns = g.columns; rows = g.rows; cellSize = g.cellSize; halfWidth = g.halfWidth; basis = g.basis
        states = Data(g.cells.map { $0.state == .unknown ? 0 : ($0.state == .obstacle ? 1 : 2) })
        reasons = Array(Set(g.cells.map { $0.reason.rawValue })).sorted()
        let lookup = Dictionary(uniqueKeysWithValues:reasons.enumerated().map { ($0.element,UInt8($0.offset)) })
        reasonIndices = Data(g.cells.map { lookup[$0.reason.rawValue] ?? 0 })
        footprint = Data(mask.map { $0 ? 1 : 0 }); unknownFraction = g.unknownFraction
    }
}
nonisolated struct FrameLog: Encodable, Sendable {
    let schemaVersion = 1
    let source: String,epoch: UInt64,frameID: UInt64,timestamp: Double,parameterVersion: UInt64
    let sourceDirectionStable: Bool
    let pose: RigidPose,intrinsics: CameraIntrinsics
    let parameters: ProbeParameters
    let plane: GroundPlane?
    let meshSources: [String]
    let grid: CompactGrid?
    let surfaceModel: SurfaceModelSummary?
    let distances: [ObstacleDistance],segments: [CandidateSegment]
    let status: String,validDepthCoverage: Float,unknownFraction: Float,stageMilliseconds: [String:Double]
    let metrics: MetricContext
    init(_ r: AnalysisResult,frame: FrameSnapshot,metrics: MetricContext) {
        source = r.source; epoch = r.epoch; frameID = r.frameID; timestamp = r.timestamp; parameterVersion = r.parameterVersion
        sourceDirectionStable = frame.directionStable
        pose = frame.pose; intrinsics = frame.intrinsics; parameters = r.parameters; plane = r.plane
        meshSources = Array(Set(r.floorPriors.map { "\($0.anchorID)/\($0.revision)@\($0.callbackTime)" })).sorted()
        surfaceModel = r.surfaceModel?.summary
        grid = r.grid.map { CompactGrid($0,mask:r.footprintMask) }; distances = r.distances; segments = r.segments
        status = r.status; validDepthCoverage = r.validDepthCoverage; unknownFraction = r.grid?.unknownFraction ?? 1; stageMilliseconds = r.stageMilliseconds; self.metrics = metrics
    }
}
nonisolated struct RecorderStatus: Sendable {
    var directory: URL?
    var droppedRecords = 0
    var message = "尚无记录"
    var error: String?
}

/// Serial disk owner, bounded admission (8 records + one manual sample), no capture-thread disk I/O.
final class SessionRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label:"probe.disk",qos:.utility)
    private let lock = NSLock()
    private var pending = 0
    private var sampling = false
    private var state = RecorderStatus()
    private var current: URL?
    private var handles: [String:FileHandle] = [:]
    private var bytesWritten = 0
    private var activeEpoch: UInt64 = 0
    private let encoder = JSONEncoder()
    private let diagnostics: DiagnosticRecorder
    init(diagnostics: DiagnosticRecorder) { self.diagnostics = diagnostics }
    func status() -> RecorderStatus { lock.lock(); defer { lock.unlock() }; return state }
    private func setStatus(_ action: (inout RecorderStatus) -> Void) { lock.lock(); action(&state); lock.unlock() }
    private func admit(sample: Bool = false) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending < 8, !sample || !sampling else { state.droppedRecords += 1; return false }
        pending += 1; if sample { sampling = true }; return true
    }
    private func complete(sample: Bool = false) { lock.lock(); pending -= 1; if sample { sampling = false }; lock.unlock() }
    private func report(_ error: Error) { setStatus { $0.error = error.localizedDescription; $0.message = "记录失败；感知继续运行" } }
    func begin(epoch: UInt64,parameters: ProbeParameters,device: [String:String]) {
        queue.async { [self] in
            closeHandles(); current = nil; activeEpoch = epoch; bytesWritten = 0
            do {
                let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Sessions",isDirectory:true)
                let date = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
                let dir = root.appendingPathComponent("\(date)-\(epoch)-\(UUID().uuidString.prefix(6))",isDirectory:true)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                current = dir
                let manifest: [String:Any] = ["schemaVersion":1,"source":"device","createdAt":ISO8601DateFormatter().string(from:Date()),"epoch":epoch,
                    "device":device,"parameters":try JSONSerialization.jsonObject(with:encoder.encode(parameters)),
                    "privacy":"No RGB images saved. Automatic depth/confidence frames and mesh are stored in Diagnostics; manual samples contain spatial data only.",
                    "sensorTimeSkew":"sceneDepth has no independent public hardware timestamp",
                    "coordinateConvention":"ARKit world gravity; camera forward -Z; pixel centers at integer indices",
                    "gridEncoding":"row-major one byte per cell: 0 unknown/1 obstacle/2 candidate; Data encoded as Base64",
                    "observationWindow":"current raw sceneDepth only; no persistent free-space fusion; plane confirmation is temporal",
                    "warning":"实验验证，候选通道不等于安全路线"]
                try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("manifest.json"),options:.atomic)
                try append(Data("epoch,frameID,timestamp,coverage,unknownFraction,captureFPS,analysisFPS,displayFPS,captureMS,depthMS,groundGridMS,meshMS,channelMS,cpuDrawMS,gpuMS,presentAgeMS,sourceAgeMS,droppedFrames,thermal,surfaceModelMS,geometryOutputEligible,guidanceOutputEligible\n".utf8),to:"metrics.csv")
                setStatus { $0.directory = dir; $0.error = nil; $0.message = "记录中：\(dir.lastPathComponent)" }
            } catch { current = nil; report(error) }
        }
    }
    func event(_ name: String,details: String,epoch: UInt64) {
        diagnostics.event(name,details:details,epoch:epoch)
        guard admit() else { return }
        queue.async { [self] in
            defer { complete() }
            guard epoch == activeEpoch,current != nil else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject:["name":name,"details":details,"epoch":epoch,"uptime":ProcessInfo.processInfo.systemUptime],options:[.sortedKeys])
                try append(data+Data([10]),to:"events.jsonl")
            } catch { report(error) }
        }
    }
    func record(_ result: AnalysisResult,frame: FrameSnapshot,metrics: MetricContext) {
        guard admit() else { return }
        queue.async { [self] in
            defer { complete() }
            guard result.epoch == activeEpoch,current != nil else { return }
            do {
                try append(try encoder.encode(FrameLog(result,frame:frame,metrics:metrics))+Data([10]),to:"frames.jsonl")
                let r = result.stageMilliseconds
                let values: [String] = [String(result.epoch),String(result.frameID),String(result.timestamp),String(result.validDepthCoverage),
                    String(result.grid?.unknownFraction ?? 1),String(metrics.captureFPS),String(metrics.analysisFPS),String(metrics.render.fps),
                    String(metrics.captureMS),String((r["depth"] ?? 0)+(r["depthCopy"] ?? 0)),String(r["groundGrid"] ?? 0),String(metrics.meshMS),String(r["channel"] ?? 0),
                    String(metrics.render.cpuMS),String(metrics.render.gpuMS),metrics.render.presentAgeMS.map(String.init(describing:)) ?? "",
                    String(metrics.sourceAgeMS),String(metrics.droppedFrames),metrics.thermal,String(r["surfaceModel"] ?? 0),
                    metrics.geometryOutputEligible == true ? "1" : "0",metrics.outputEligible ? "1" : "0"]
                try append(Data((values.joined(separator:",")+"\n").utf8),to:"metrics.csv")
            } catch { report(error) }
        }
    }
    func predictionSampleSubmitted() { setStatus { $0.message = "预测样本已提交本次DIAG（无RGB）；请导出完整DIAG并检查丢弃计数" } }
    func manualSample(frame: FrameSnapshot,result: AnalysisResult?,meshes: [MeshSnapshot],display: [String:String]) {
        guard admit(sample:true) else { setStatus { $0.message = "采样队列忙；本次未保存" }; return }
        queue.async { [self] in
            defer { complete(sample:true) }
            guard frame.epoch == activeEpoch,let current else { setStatus { $0.message = "当前会话未开启记录，未保存" }; return }
            let estimatedBytes = (frame.frame.sceneDepth.map { CVPixelBufferGetWidth($0.depthMap)*CVPixelBufferGetHeight($0.depthMap)*5 } ?? 0)
                + meshes.reduce(0) { $0+$1.byteCount*12 } + 8*1024*1024
            guard bytesWritten+estimatedBytes <= 512*1024*1024 else {
                setStatus { $0.error = "剩余会话配额不足以保存手动样本（512 MiB，含样本）；请导出并开始新会话" }; return
            }
            do {
                let dir = current.appendingPathComponent("samples/\(frame.id)-\(UUID().uuidString.prefix(6))",isDirectory:true)
                try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
                defer {
                    if let files = try? FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:[.fileSizeKey]) {
                        bytesWritten += files.reduce(0) { $0+((try? $1.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
                    }
                }
                guard let data = frame.depthObservation() else { throw NSError(domain:"Sample",code:1,userInfo:[NSLocalizedDescriptionKey:"当前帧没有可导出的 Float32 深度"]) }
                let raw = data.depth.withUnsafeBytes { Data($0) }; try raw.write(to:dir.appendingPathComponent("depth.f32le"))
                if let confidence = data.confidence { try Data(confidence).write(to:dir.appendingPathComponent("confidence.u8")) }
                let metadata: [String:Any] = ["source":"device","epoch":frame.epoch,"frameID":frame.id,"timestamp":frame.frame.timestamp,
                    "receivedAt":frame.receivedAt,"tracking":frame.tracking,"directionStable":frame.directionStable,
                    "pose":try JSONSerialization.jsonObject(with:encoder.encode(frame.pose)),
                    "rgbIntrinsics":try JSONSerialization.jsonObject(with:encoder.encode(frame.intrinsics)),
                    "depthIntrinsics":try JSONSerialization.jsonObject(with:encoder.encode(data.intrinsics)),
                    "depthWidth":data.width,"depthHeight":data.height,"depthEncoding":"IEEE754 float32 little-endian, row-major, meters axial depth",
                    "confidenceAvailable":data.confidence != nil,"confidenceEncoding":"0 low,1 medium,2 high",
                    "display":display,"parameters":try JSONSerialization.jsonObject(with:encoder.encode(frame.parameters)),
                    "parameterVersion":frame.parameterVersion,"observationWindow":"This raw frame only. Matching analysis and mesh priors if available; not a recording of preceding frames.",
                    "matchingAnalysis":result?.frameID == frame.id,"sensorSkew":"not_exposed_by_API"]
                try JSONSerialization.data(withJSONObject:metadata,options:[.prettyPrinted,.sortedKeys]).write(to:dir.appendingPathComponent("metadata.json"))
                if let result,result.frameID == frame.id { try encoder.encode(result).write(to:dir.appendingPathComponent("analysis.json")) }
                try encoder.encode(meshes).write(to:dir.appendingPathComponent("mesh-snapshots.json"))
                setStatus { $0.message = "已保存同帧手动样本 \(frame.id)；不保存 RGB 图像" }
            } catch { report(error) }
        }
    }
    func finish(epoch: UInt64) {
        event("session_stopped",details:"Channel evidence invalidated",epoch:epoch)
        queue.async { [self] in
            guard activeEpoch == epoch else { return }
            activeEpoch = 0; closeHandles(); setStatus { $0.message = "记录已停止，可导出" }
        }
    }
    func export(completion: @escaping @Sendable (Result<URL,Error>) -> Void) {
        queue.async { [self] in
            do {
                for handle in handles.values { try handle.synchronize() }
                guard let current else { throw NSError(domain:"Export",code:1,userInfo:[NSLocalizedDescriptionKey:"尚无记录，请先开始会话"]) }
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("ProbeExports",isDirectory:true)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                let target = root.appendingPathComponent(current.lastPathComponent+"-"+String(UUID().uuidString.prefix(6)),isDirectory:true)
                try FileManager.default.copyItem(at:current,to:target)
                let summary: [String:Any] = ["exportedAt":ISO8601DateFormatter().string(from:Date()),"droppedRecords":status().droppedRecords,"error":status().error ?? "none",
                                           "note":"Snapshot copy at export; No new RGB imagery; depth/confidence/geometry only"]
                try JSONSerialization.data(withJSONObject:summary,options:[.prettyPrinted]).write(to:target.appendingPathComponent("export-status.json"))
                completion(.success(target))
            } catch { completion(.failure(error)) }
        }
    }
    private func append(_ data: Data,to name: String) throws {
        guard let current else { return }
        guard bytesWritten + data.count <= 512*1024*1024 else {
            throw NSError(domain:"Recorder",code:2,userInfo:[NSLocalizedDescriptionKey:"本会话日志已达512 MiB上限，停止新增记录；请停止并导出"])
        }
        let handle: FileHandle
        if let existing = handles[name] { handle = existing } else {
            let url = current.appendingPathComponent(name)
            handle = try AppendFile.open(at:url); handles[name] = handle
        }
        try handle.write(contentsOf:data); bytesWritten += data.count
    }
    private func closeHandles() { for h in handles.values { try? h.synchronize(); try? h.close() }; handles.removeAll() }
}
