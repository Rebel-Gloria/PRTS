#if PRTS_DEV_CAPTURE
import ARKit
import AVFoundation
import CoreImage
import CryptoKit
import Foundation
import SpatialCore

/// Development-only, opt-in RGB recording. One pending sample; never blocks analysis on encoding.
/// Video is the unoverlaid camera image (lossy/resized), not a screen recording or sensor-raw video.
nonisolated final class DevCaptureRecorder: @unchecked Sendable {
    struct Status: Sendable {
        var enabled = false
        var busy = false
        var finalizing = false
        var text = "未开启；不会保存视频"
        var saved = 0
        var dropped = 0
    }
    private let lock = NSLock()
    private var state = Status()
    private var lastTimestamp = -Double.infinity
    private let queue = DispatchQueue(label:"prts.dev.capture",qos:.utility)
    private let context = CIContext(options:[.cacheIntermediates:false])
    private let root: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var index: FileHandle?
    private var directory: URL?
    private var origin: Double = 0
    private var epoch: UInt64 = 0
    private var dimensions = CGSize.zero
    private var bytes = 0
    private var totalBytes = 0
    private var lastVideoBytes = 0
    private var finishing = false
    private var completions: [@Sendable () -> Void] = []
    private static let limit = 256 * 1024 * 1024
    init(root: URL) { self.root = root }
    func status() -> Status { lock.lock(); defer { lock.unlock() }; return state }
    private func update(_ body: (inout Status) -> Void) { lock.lock(); defer { lock.unlock() }; body(&state) }
    func enable() {
        lock.lock(); defer { lock.unlock() }
        guard !state.busy, !state.finalizing else { return }
        state.enabled = true; state.text = "已开启：5 FPS 上限，最长边 960，H.264；等待分析帧"
        lastTimestamp = -.infinity
    }
    /// Disarms immediately. Completion runs only after queued samples and MP4 finalization finish.
    func stop(completion: @escaping @Sendable () -> Void = {}) {
        lock.lock(); state.enabled = false; state.busy = true; state.finalizing = true
        queue.async { [self] in completions.append(completion); finish() }
        lock.unlock()
    }
    struct ModelOutput: Encodable, Sendable {
        let model = "DepthAnythingV2SmallF16"
        let units = "relative_inverse_depth_not_meters"
        let layout = "camera_aligned_model_output_not_heatmap"
        let width: Int, height: Int
        let calibration: InverseDepthCalibration?
        let provisionalFit: InverseDepthCalibration?
        let scaleDecision: MetricScaleDecision
        let scaleSamples: [ScaleSample]
        let groundReference: NativeGroundSelection
        let timings: [String:Double]
        let status: String
    }
    struct Feature: Encodable, Sendable { let id: UInt64; let world: V3 }
    struct MeshReference: Encodable, Sendable { let id: String; let revision: UInt64; let callbackTime: Double }
    struct Packet: @unchecked Sendable {
        let image: CVPixelBuffer
        let timestamp: Double
        let epoch: UInt64
        let capture: CaptureDiagnostic?
        let result: AnalysisResult
        let path: PathUpdate
        let source: String
        var observation: DepthObservation? = nil
        var relative: [Float]? = nil
        var model: ModelOutput? = nil
        var planes: [NativePlaneObservation] = []
        var features: [Feature] = []
        var featureCount = 0
        var featureStep = 1
        var meshes: [MeshReference] = []
        var pathOptions = PathOptions()
    }
    func submit(frame: FrameSnapshot,result: AnalysisResult,path: PathUpdate,observation: DepthObservation?,prediction: MonocularFrame?,meshes: [String:MeshSnapshot],pathOptions: PathOptions) {
        guard status().enabled else { return }
        var packet = Packet(image:frame.frame.capturedImage,timestamp:frame.frame.timestamp,epoch:frame.epoch,
            capture:CaptureDiagnostic(frame),result:result,path:path,source:result.source)
        packet.observation = observation; packet.pathOptions = pathOptions
        packet.planes = prediction?.planes ?? MonocularDepthProvider.planes(frame)
        packet.meshes = meshes.values.map { MeshReference(id:$0.id,revision:$0.revision,callbackTime:$0.callbackTime) }.sorted { $0.id < $1.id }
        if let cloud = frame.frame.rawFeaturePoints {
            packet.featureCount = cloud.points.count; packet.featureStep = max(1,(cloud.points.count+511)/512)
            packet.features = stride(from:0,to:cloud.points.count,by:packet.featureStep).map { Feature(id:cloud.identifiers[$0],world:cloud.points[$0]) }
        }
        if let p = prediction {
            packet.relative = p.relative
            packet.model = ModelOutput(width:p.width,height:p.height,calibration:p.calibration,provisionalFit:p.provisionalFit,
                scaleDecision:p.scaleDecision,scaleSamples:p.samples,groundReference:p.groundReference,timings:p.timings,status:p.status)
        }
        submit(packet)
    }
    func submit(_ packet: Packet) {
        lock.lock()
        guard state.enabled else { lock.unlock(); return }
        let timestamp = packet.timestamp
        guard timestamp-lastTimestamp >= 0.2 else { lock.unlock(); return }
        guard !state.busy else { state.dropped += 1; lock.unlock(); return }
        lastTimestamp = timestamp; state.busy = true
        // Enqueue under the admission lock so stop cannot overtake an accepted sample.
        queue.async { [self] in
            defer { if !finishing { update { if !$0.finalizing { $0.busy = false } } } }
            do { try append(packet) }
            catch {
                update { $0.enabled = false; $0.text = "采集停止：\(error.localizedDescription)" }
                finish()
            }
        }
        lock.unlock()
    }
    private func fail(_ message: String) -> NSError { NSError(domain:"PRTSDevCapture",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    private func open(_ packet: Packet) throws {
        guard totalBytes < Self.limit else { throw fail("本次启动的开发采集达到 256 MiB 上限") }
        let folder = root.appendingPathComponent("dev-capture-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        var excluded = folder; var values = URLResourceValues(); values.isExcludedFromBackup = true; try excluded.setResourceValues(values)
        let source = packet.image
        let w = CVPixelBufferGetWidth(source),h = CVPixelBufferGetHeight(source)
        let scale = min(1,960 / Double(max(w,h)))
        let width = max(2,Int(Double(w)*scale)/2*2),height = max(2,Int(Double(h)*scale)/2*2)
        let asset = try AVAssetWriter(outputURL:folder.appendingPathComponent("camera.mp4"),fileType:.mp4)
        let track = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,
            AVVideoWidthKey:width,AVVideoHeightKey:height,
            AVVideoCompressionPropertiesKey:[AVVideoAllowFrameReorderingKey:false,AVVideoAverageBitRateKey:800_000,AVVideoExpectedSourceFrameRateKey:5,AVVideoMaxKeyFrameIntervalKey:10]])
        track.expectsMediaDataInRealTime = true
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:track,sourcePixelBufferAttributes:[
            kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String:width,kCVPixelBufferHeightKey as String:height,
            kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
        guard asset.canAdd(track) else { throw fail("视频编码器不可用") }
        asset.add(track)
        guard asset.startWriting() else { throw asset.error ?? fail("无法启动视频写入") }
        asset.startSession(atSourceTime:.zero)
        writer = asset; input = track; adaptor = adapter; directory = folder
        origin = packet.timestamp; epoch = packet.epoch; dimensions = CGSize(width:width,height:height); bytes = 0; lastVideoBytes = 0
        let url = folder.appendingPathComponent("samples.jsonl")
        guard FileManager.default.createFile(atPath:url.path,contents:nil) else { throw fail("无法建立帧索引") }
        index = try FileHandle(forWritingTo:url)
        let manifest: [String:Any] = ["source":packet.source,"schemaVersion":1,"compileTag":"PRTS_DEV_CAPTURE","containsRGB":true,
            "video":"camera.mp4","index":"samples.jsonl","maxFPS":5,"codec":"H264","bitrate":800000,
            "sourceWidth":w,"sourceHeight":h,"videoWidth":width,"videoHeight":height,
            "originARTimestamp":origin,"epoch":epoch,"maximumSeconds":600,"launchByteLimit":Self.limit,
            "coordinates":"Unrotated full camera image, no overlay; intrinsics in capture use source dimensions. Scale x and y separately for video pixels.",
            "depthLink":"Per-sample lossless depth_frame attachment; absent means unavailable, never zero. Parent analysis.jsonl provides additional frames.",
            "meshLink":"Parent mesh.jsonl and data-*.bin by epoch, anchor ID and revision; missing/dropped mesh attachments remain unknown.",
            "ARKit":"Sampled sparse world features (<=512), horizontal plane boundaries used by analysis; not raw IMU or private SLAM map.",
            "attachmentCodec":"raw DEFLATE; SHA256 of uncompressed payload. DA relative output Float32 little-endian, camera-aligned before metric calibration.",
            "privacy":"Opt-in local camera video; no audio/GPS/upload. Deleted only by user. Abrupt termination may leave incomplete MP4."]
        try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
        try writeStatus("recording")
    }
    private func append(_ packet: Packet) throws {
        if writer == nil { try open(packet) }
        guard let writer,let input,let adaptor,let index else { throw fail("采集资源不可用") }
        guard packet.epoch == epoch,packet.timestamp-origin < 600 else { throw fail("会话变化或达到10分钟上限；请重新手动开启") }
        let disk = try root.resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity ?? 0
        guard disk > 256*1024*1024 else { throw fail("可用空间低于256 MiB") }
        guard input.isReadyForMoreMediaData else { update { $0.dropped += 1 }; return }
        guard let pool = adaptor.pixelBufferPool else { throw fail("视频缓冲池不可用") }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil,pool,&pixel) == kCVReturnSuccess,let pixel else { throw fail("视频缓冲区分配失败") }
        let source = packet.image
        let image = CIImage(cvPixelBuffer:source).transformed(by:CGAffineTransform(scaleX:dimensions.width/CGFloat(CVPixelBufferGetWidth(source)),y:dimensions.height/CGFloat(CVPixelBufferGetHeight(source))))
        context.render(image,to:pixel,bounds:CGRect(origin:.zero,size:dimensions),colorSpace:CGColorSpaceCreateDeviceRGB())
        let pts = CMTime(seconds:packet.timestamp-origin,preferredTimescale:60000)
        struct Evidence: Encodable {
            let capture: CaptureDiagnostic?
            let analysis: AnalysisResult
            let path: PathUpdate
            let pathOptions: PathOptions
            let model: ModelOutput?
            let nativePlanes: [NativePlaneObservation]
            let sparseFeatures: [Feature]
            let totalFeatureCount: Int, featureSamplingStep: Int
            let meshReferences: [MeshReference]
            let source: String
        }
        struct Attachment: Encodable {
            let file: String, codec: String, sha256: String
            let compressedBytes: Int, uncompressedBytes: Int
        }
        struct Sample: Encodable {
            let epoch: UInt64, frameID: UInt64
            let timestamp: Double
            let videoPTSValue: Int64
            let videoPTSTimescale: Int32
            let evidence: Attachment
            let depth: Attachment?
            let relative: Attachment?
        }
        guard let directory else { throw fail("采集目录不可用") }
        let stem = "\(packet.epoch)-\(packet.result.frameID)"
        var attachments: [(Attachment,Data)] = []
        func pack(_ raw: Data,_ suffix: String) throws -> Attachment {
            let encoded = try (raw as NSData).compressed(using:.zlib) as Data
            let ref = Attachment(file:stem+suffix,codec:"deflate-raw",sha256:SHA256.hash(data:raw).map { String(format:"%02x",$0) }.joined(),compressedBytes:encoded.count,uncompressedBytes:raw.count)
            attachments.append((ref,encoded)); return ref
        }
        let evidence = Evidence(capture:packet.capture,analysis:packet.result,path:packet.path,pathOptions:packet.pathOptions,
            model:packet.model,nativePlanes:packet.planes,sparseFeatures:packet.features,totalFeatureCount:packet.featureCount,
            featureSamplingStep:packet.featureStep,meshReferences:packet.meshes,source:packet.source)
        let evidenceRef = try pack(DiagnosticJSON.encode(evidence),".evidence.json.deflate")
        let depthRef = try packet.observation.map { try pack(DepthFrameCodec.encode($0,parameters:packet.result.parameters,
            parameterVersion:packet.result.parameterVersion,priors:packet.result.floorPriors,directionStable:packet.result.sourceDirectionStable ?? false,source:packet.source),".depth.bin.deflate") }
        let relativeRef = try packet.relative.map { values -> Attachment in
            var raw = Data(capacity:values.count*4)
            for value in values { var bits = value.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { raw.append(contentsOf:$0) } }
            return try pack(raw,".relative.f32.deflate")
        }
        let data = try DiagnosticJSON.encode(Sample(epoch:packet.epoch,frameID:packet.result.frameID,timestamp:packet.timestamp,
            videoPTSValue:pts.value,videoPTSTimescale:pts.timescale,evidence:evidenceRef,depth:depthRef,relative:relativeRef))
        let size = (try? directory.appendingPathComponent("camera.mp4").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
        totalBytes += max(0,size-lastVideoBytes); lastVideoBytes = size
        let added = attachments.reduce(data.count+1) { $0+$1.1.count }
        guard totalBytes+added < Self.limit else { throw fail("本次启动的开发采集达到256 MiB上限") }
        for (ref,raw) in attachments { try raw.write(to:directory.appendingPathComponent(ref.file),options:.atomic) }
        guard adaptor.append(pixel,withPresentationTime:pts) else { throw writer.error ?? fail("视频帧写入失败") }
        try index.write(contentsOf:data); try index.write(contentsOf:Data([10]))
        bytes += data.count+1; totalBytes += added
        update { $0.saved += 1; $0.text = "正在保存摄像机视频＋分析数据（\($0.saved)帧，丢弃\($0.dropped)）" }
    }
    private func writeStatus(_ phase: String) throws {
        guard let directory else { return }
        let s = status()
        try JSONSerialization.data(withJSONObject:["phase":phase,"savedLaunchSamples":s.saved,"droppedLaunchSamples":s.dropped,"indexBytes":bytes,"message":s.text],options:.prettyPrinted).write(to:directory.appendingPathComponent("status.json"),options:.atomic)
    }
    private func finish() {
        guard !finishing else { return }
        guard let asset = writer else { complete(); return }
        finishing = true
        do { try index?.synchronize(); try index?.close() } catch { update { $0.text = "索引落盘失败：\(error.localizedDescription)" } }
        index = nil
        guard asset.status == .writing else {
            update { $0.text = "视频未完整结束：\(asset.error?.localizedDescription ?? "writer_not_writing")" }
            do { try writeStatus("failed") } catch { update { $0.text = "结束状态写入失败：\(error.localizedDescription)" } }
            writer = nil; input = nil; adaptor = nil; finishing = false; complete(); return
        }
        input?.markAsFinished()
        asset.finishWriting { [self] in queue.async { [self] in
            guard let asset = writer else { finishing = false; complete(); return }
            if asset.status != .completed { update { $0.text = "视频未完整结束：\(asset.error?.localizedDescription ?? "unknown")" } }
            do { try writeStatus(asset.status == .completed ? "completed" : "failed") }
            catch { update { $0.text = "结束状态写入失败：\(error.localizedDescription)" } }
            if let directory {
                let finalSize = (try? directory.appendingPathComponent("camera.mp4").resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? lastVideoBytes
                totalBytes += max(0,finalSize-lastVideoBytes)
            }
            writer = nil; input = nil; adaptor = nil; finishing = false; complete()
        }}
    }
    private func complete() {
        update { $0.busy = false; $0.finalizing = false; if $0.text.hasPrefix("正在保存") || $0.text.hasPrefix("已开启") { $0.text = "已停止；可随完整 DIAG 导出" } }
        let callbacks = completions; completions.removeAll(); callbacks.forEach { $0() }
    }
}
#endif
