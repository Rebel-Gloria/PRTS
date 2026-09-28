import ARKit
import CoreML
import CoreImage
import ImageIO
import SpatialCore

/// Immutable output; buffers are retained until the GPU completes. RGB is never written to disk.
final class MonocularFrame: @unchecked Sendable {
    let frame: FrameSnapshot
    let width: Int, height: Int
    let relative: [Float]
    let observation: DepthObservation?
    let calibration: InverseDepthCalibration?
    let planes: [NativePlaneObservation]
    let ground: NativePlaneObservation?
    let samples: [ScaleSample]
    let displayBuffer: CVPixelBuffer?
    let milliseconds: Double
    let timings: [String:Double]
    let scaleDecision: MetricScaleDecision
    let provisionalFit: InverseDepthCalibration?
    let groundReference: NativeGroundSelection
    let status: String
    let relativeCoverage: Float
    var groundStatus: String {
        switch groundReference.mode {
        case "confirmed": return "原生 floor 参考（非净空证明）"
        case "provisional_ground": return "待确认水平面（非 floor 分类）"
        case "retained_reference": return String(format:"短时参考 %.1f s（非当前地面观测）",groundReference.age)
        case "provisional": return "原生平面确认中"
        default: return "暂无可靠参考"
        }
    }
    init(frame: FrameSnapshot,width: Int,height: Int,relative: [Float],observation: DepthObservation?,
         calibration: InverseDepthCalibration?,planes: [NativePlaneObservation],ground: NativePlaneObservation?,samples: [ScaleSample],milliseconds: Double,timings: [String:Double],status: String,scaleDecision: MetricScaleDecision,provisionalFit: InverseDepthCalibration?,groundReference: NativeGroundSelection) {
        self.relativeCoverage = Float(relative.filter(\.isFinite).count)/Float(max(1,relative.count))
        self.scaleDecision = scaleDecision; self.provisionalFit = provisionalFit; self.groundReference = groundReference
        self.frame = frame; self.width = width; self.height = height; self.relative = relative; self.observation = observation
        self.calibration = calibration; self.planes = planes; self.ground = ground; self.samples = samples; self.status = status
        let displayStart = ProcessInfo.processInfo.systemUptime
        let values: [Float]
        if let observation { values = observation.depth }
        else {
            let finite = relative.filter(\.isFinite).sorted()
            let low = finite.isEmpty ? 0 : finite[finite.count/50], high = finite.isEmpty ? 1 : finite[finite.count*49/50]
            values = relative.map { $0.isFinite ? max(0.001,min(1,1-($0-low)/max(0.00001,high-low))) : 0 }
        }
        displayBuffer = Self.buffer(values,width:width,height:height)
        let displayMS = (ProcessInfo.processInfo.systemUptime-displayStart)*1000
        self.milliseconds = milliseconds+displayMS
        var stages = timings; stages["modelDisplayBuffer"] = displayMS; self.timings = stages
    }
    static func buffer(_ values: [Float],width: Int,height: Int) -> CVPixelBuffer? {
        guard values.count == width*height,width > 0,height > 0 else { return nil }
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_OneComponent32Float,
            [kCVPixelBufferMetalCompatibilityKey:true,kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&result) == kCVReturnSuccess,let result,
            CVPixelBufferLockBaseAddress(result,[]) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(result,[]) }
        guard let base = CVPixelBufferGetBaseAddress(result) else { return nil }
        for y in 0..<height { values.withUnsafeBufferPointer { ptr in
            base.advanced(by:y*CVPixelBufferGetBytesPerRow(result)).copyMemory(from:ptr.baseAddress!.advanced(by:y*width),byteCount:width*4)
        } }
        return result
    }
}

/// Exclusively owned by the existing single analysis worker; never creates per-camera-frame tasks.
final class MonocularDepthProvider {
    private let network = CoreMLDepthModel()
    private var groundTracker = NativeGroundTracker()
    private var scaleTracker = MetricScaleTracker()
    private var epoch: UInt64 = 0,version: UInt64 = 0
    private var previousOrientation: ImageOrientation?
    func reset() { groundTracker.reset(); scaleTracker.reset(); previousOrientation = nil }
    static func planes(_ frame: FrameSnapshot) -> [NativePlaneObservation] {
        frame.frame.anchors.compactMap { anchor -> NativePlaneObservation? in
            guard let plane = anchor as? ARPlaneAnchor,plane.alignment == .horizontal else { return nil }
            let classification: String
            switch plane.classification { case .floor: classification = "floor"; case .none: classification = "unknown"; case .table: classification = "table"; default: classification = "other" }
            let vertices = plane.geometry.boundaryVertices
            guard vertices.count >= 3,vertices.count <= 512 else { return nil }
            return .init(id:plane.identifier.uuidString,classification:classification,pose:RigidPose(plane.transform),boundary:vertices,timestamp:frame.frame.timestamp)
        }.sorted { $0.id < $1.id }.prefix(64).map { $0 }
    }
    func predict(_ frame: FrameSnapshot) throws -> MonocularFrame {
        let start = ProcessInfo.processInfo.systemUptime
        if epoch != frame.epoch || version != frame.parameterVersion || previousOrientation != frame.orientation || !frame.trackingNormal {
            reset(); epoch = frame.epoch; version = frame.parameterVersion; previousOrientation = frame.orientation
        }
        let planes = Self.planes(frame)
        let groundReference = frame.trackingNormal ? groundTracker.update(planes,camera:frame.pose,time:frame.frame.timestamp) : NativeGroundSelection(mode:"invalid",reason:"tracking_not_normal")
        let ground = groundReference.plane
        let afterPlane = ProcessInfo.processInfo.systemUptime
        let inferred = try network.infer(imageBuffer:frame.frame.capturedImage,orientation:frame.orientation)
        let w = inferred.width,h = inferred.height,raw = inferred.relative
        let alignmentStart = ProcessInfo.processInfo.systemUptime
        let k = frame.intrinsics.scaled(width:w,height:h)
        var samples: [ScaleSample] = []
        if frame.trackingNormal,let features = frame.frame.rawFeaturePoints {
            let points = features.points,identifiers = features.identifiers,step = max(1,points.count/384)
            for i in stride(from:0,to:points.count,by:step) {
                let point = frame.pose.camera(points[i]); guard let p = k.project(point),p.x >= 2,p.y >= 2,p.x < Float(w-2),p.y < Float(h-2) else { continue }
                let x = Int(p.x.rounded()),y = Int(p.y.rounded())
                samples.append(.init(relative:raw[y*w+x],meters:-point.z,u:p.x/Float(w),v:p.y/Float(h),source:"arkit_sparse_feature",featureID:identifiers[i]))
            }
        }
        // Classified native plane only; don't use a guessed camera height, mesh or sceneDepth.
        if frame.trackingNormal,groundReference.canSupplyScaleSamples,let ground {
            for y in stride(from:8,to:h-8,by:16) { for x in stride(from:8,to:w-8,by:24) {
                if let depth = ground.rayDepth(u:Float(x),v:Float(y),intrinsics:k,camera:frame.pose) {
                    samples.append(.init(relative:raw[y*w+x],meters:depth,u:Float(x)/Float(w),v:Float(y)/Float(h),source:"arkit_floor_bounded_plane"))
                }
            }}
        }
        let fitScale = frame.trackingNormal ? InverseDepthCalibration.fit(samples) : nil
        let decision = scaleTracker.update(.init(timestamp:frame.frame.timestamp,epoch:frame.epoch,parameterVersion:frame.parameterVersion,
            orientation:frame.orientation,intrinsics:k,pose:frame.pose,relative:raw,samples:samples,fit:fitScale))
        let calibration = decision.calibration
        var observation: DepthObservation?
        if let calibration {
            let depths = raw.map { calibration.meters($0) ?? .nan }
            var o = DepthObservation(width:w,height:h,depth:depths,confidence:nil,intrinsics:k,pose:frame.pose,timestamp:frame.frame.timestamp,frameID:frame.id,epoch:frame.epoch)
            o.predictionSupport = depths.map { $0.isFinite && $0 >= frame.parameters.minDepth && $0 <= frame.parameters.maxDepth ? 1 : 0 }
            observation = o
        }
        let status = !frame.trackingNormal ? "预测相对深度；ARKit追踪受限，尺度未知" : (calibration == nil ? "预测相对深度；等待原生特征/平面尺度确认（\(decision.confirmations)/3）" : "预测深度已按ARKit尺度对齐；非LiDAR测量，通道未知")
        return MonocularFrame(frame:frame,width:w,height:h,relative:raw,observation:observation,calibration:calibration,planes:planes,ground:ground,samples:samples,
            milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000,
            timings:inferred.timings.merging(["nativePlane":(afterPlane-start)*1000,"scaleAlignment":(ProcessInfo.processInfo.systemUptime-alignmentStart)*1000],uniquingKeysWith:{$1}),status:status,scaleDecision:decision,provisionalFit:fitScale,groundReference:groundReference)
    }
    private func failure(_ description: String) -> NSError { NSError(domain:"Monocular",code:2,userInfo:[NSLocalizedDescriptionKey:description]) }
}
