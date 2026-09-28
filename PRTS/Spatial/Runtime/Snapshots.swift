/// Immutable-ish runtime snapshots shared by capture, analysis, rendering and diagnostics.

import ARKit
import Foundation
import SpatialCore
import simd

extension RigidPose {
    init(_ matrix: simd_float4x4) {
        self.init(right:V3(matrix.columns.0.x,matrix.columns.0.y,matrix.columns.0.z),
                  up:V3(matrix.columns.1.x,matrix.columns.1.y,matrix.columns.1.z),
                  back:V3(matrix.columns.2.x,matrix.columns.2.y,matrix.columns.2.z),
                  position:V3(matrix.columns.3.x,matrix.columns.3.y,matrix.columns.3.z))
    }
}

/// Retains immutable ARFrame pixel buffers until CPU reads/GPU commands finish. No buffer is mutated.
final class FrameSnapshot: @unchecked Sendable {
    let frame: ARFrame
    let usesMonocular: Bool
    let orientation: ImageOrientation
    let epoch: UInt64
    let id: UInt64
    let receivedAt: Double
    let directionDiagnostics: DirectionDiagnostics?
    let directionStable: Bool
    let trackingNormal: Bool
    let tracking: String
    let parameters: ProbeParameters
    let parameterVersion: UInt64
    let captureMilliseconds: Double
    let pose: RigidPose
    let intrinsics: CameraIntrinsics
    init(frame: ARFrame,epoch: UInt64,id: UInt64,receivedAt: Double,directionStable: Bool,parameters: ProbeParameters,parameterVersion: UInt64,directionDiagnostics: DirectionDiagnostics? = nil, usesMonocular: Bool = false, orientation: ImageOrientation = .portrait) {
        self.usesMonocular = usesMonocular; self.orientation = orientation
        self.frame = frame; self.epoch = epoch; self.id = id; self.receivedAt = receivedAt; self.directionStable = directionStable
        self.directionDiagnostics = directionDiagnostics
        self.parameters = parameters; self.parameterVersion = parameterVersion
        pose = RigidPose(frame.camera.transform)
        let k = frame.camera.intrinsics,s = frame.camera.imageResolution
        intrinsics = CameraIntrinsics(fx:k[0][0],fy:k[1][1],cx:k[2][0],cy:k[2][1],width:Int(s.width),height:Int(s.height))
        switch frame.camera.trackingState {
        case .normal: trackingNormal = true; tracking = "正常"
        case .notAvailable: trackingNormal = false; tracking = "不可用"
        case .limited(let reason):
            trackingNormal = false
            switch reason {
            case .initializing: tracking = "受限：初始化"
            case .excessiveMotion: tracking = "受限：移动过快"
            case .insufficientFeatures: tracking = "受限：特征不足"
            case .relocalizing: tracking = "受限：重定位"
            @unknown default: tracking = "受限：未知原因"
            }
        }
        captureMilliseconds = (ProcessInfo.processInfo.systemUptime-receivedAt)*1000
    }
    struct DepthRead {
        var observation: DepthObservation?
        var status: String
        var confidenceStatus: String = "not_read"
    }
    func depthObservation() -> DepthObservation? { readDepth().observation }
    func readDepth() -> DepthRead {
        guard !usesMonocular else { return .init(status:"monocular_backend_no_scene_depth_read") }
        guard let data = frame.sceneDepth else { return .init(status:"scene_depth_missing") }
        let buffer = data.depthMap
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_DepthFloat32 else { return .init(status:"unsupported_depth_format") }
        let w = CVPixelBufferGetWidth(buffer),h = CVPixelBufferGetHeight(buffer)
        guard CVPixelBufferLockBaseAddress(buffer,.readOnly) == kCVReturnSuccess else { return .init(status:"depth_lock_failed") }; defer { CVPixelBufferUnlockBaseAddress(buffer,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .init(status:"depth_base_address_missing") }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var values = [Float](repeating:0,count:w*h)
        for row in 0..<h {
            let ptr = base.advanced(by:row*stride).assumingMemoryBound(to:Float.self)
            values.replaceSubrange(row*w..<(row+1)*w,with:UnsafeBufferPointer(start:ptr,count:w))
        }
        var confidence: [UInt8]?
        var confidenceStatus = data.confidenceMap == nil ? "missing" : "size_or_format_mismatch"
        if let cb = data.confidenceMap,CVPixelBufferGetWidth(cb) == w,CVPixelBufferGetHeight(cb) == h,
           CVPixelBufferGetPixelFormatType(cb) == kCVPixelFormatType_OneComponent8 {
            guard CVPixelBufferLockBaseAddress(cb,.readOnly) == kCVReturnSuccess else {
                return .init(observation:.init(width:w,height:h,depth:values,confidence:nil,intrinsics:intrinsics.scaled(width:w,height:h),pose:pose,timestamp:frame.timestamp,frameID:id,epoch:epoch),status:"available",confidenceStatus:"confidence_lock_failed")
            }
            confidenceStatus = "base_address_missing"
            if let cbase = CVPixelBufferGetBaseAddress(cb) {
                let cs = CVPixelBufferGetBytesPerRow(cb)
                var bytes = [UInt8](repeating:0,count:w*h)
                for row in 0..<h { bytes.replaceSubrange(row*w..<(row+1)*w,with:UnsafeBufferPointer(start:cbase.advanced(by:row*cs).assumingMemoryBound(to:UInt8.self),count:w)) }
                confidence = bytes; confidenceStatus = "available"
            }
            CVPixelBufferUnlockBaseAddress(cb,.readOnly)
        }
        return .init(observation:.init(width:w,height:h,depth:values,confidence:confidence,intrinsics:intrinsics.scaled(width:w,height:h),pose:pose,
                     timestamp:frame.timestamp,frameID:id,epoch:epoch),status:"available",confidenceStatus:confidenceStatus)
    }
}

struct MeshSnapshot: Codable, Sendable {
    let id: String
    let epoch: UInt64
    let revision: UInt64
    let callbackTime: Double
    let transform: RigidPose
    let vertices: [V3] // anchor-local
    let indices: [UInt32]
    let classifications: [UInt8]
    let floorPriors: [FloorPrior]
    var byteCount: Int { vertices.count*16+indices.count*4+classifications.count }
    static func copy(_ anchor: ARMeshAnchor,epoch: UInt64,revision: UInt64,time: Double) -> MeshSnapshot? {
        let geometry = anchor.geometry,source = geometry.vertices,faces = geometry.faces
        guard source.format == .float3, faces.indexCountPerPrimitive == 3,
              faces.bytesPerIndex == 2 || faces.bytesPerIndex == 4,
              source.count <= 150_000,faces.count <= 200_000 else { return nil }
        var vertices: [V3] = []; vertices.reserveCapacity(source.count)
        let ptr = source.buffer.contents()
        for i in 0..<source.count {
            let p = ptr.advanced(by:source.offset+i*source.stride).assumingMemoryBound(to:Float.self)
            let vertex = V3(p[0],p[1],p[2])
            guard vertex.x.isFinite,vertex.y.isFinite,vertex.z.isFinite else { return nil }
            vertices.append(vertex)
        }
        let ip = faces.buffer.contents(); var indices: [UInt32] = []; indices.reserveCapacity(faces.count*3)
        for i in 0..<(faces.count*3) {
            let index = faces.bytesPerIndex == 2 ? UInt32(ip.load(fromByteOffset:i*2,as:UInt16.self)) : ip.load(fromByteOffset:i*4,as:UInt32.self)
            guard index < vertices.count else { return nil }; indices.append(index)
        }
        var classes = [UInt8](repeating:0,count:faces.count)
        if let source = geometry.classification,source.format == .uchar,source.count == faces.count {
            for i in 0..<source.count { classes[i] = source.buffer.contents().load(fromByteOffset:source.offset+i*source.stride,as:UInt8.self) }
        }
        let transform = RigidPose(anchor.transform)
        var priors: [FloorPrior] = []
        let sampleStep = max(1,faces.count/128)
        for face in stride(from:0,to:faces.count,by:sampleStep) where classes[face] == UInt8(ARMeshClassification.floor.rawValue) {
            let a = transform.world(vertices[Int(indices[face*3])]),b = transform.world(vertices[Int(indices[face*3+1])]),c = transform.world(vertices[Int(indices[face*3+2])])
            let cross = simd_cross(b-a,c-a)
            guard simd_length(cross) > 0.0001 else { continue }
            var normal = simd_normalize(cross); if normal.y < 0 { normal = -normal }
            priors.append(.init(center:(a+b+c)/3,normal:normal,anchorID:anchor.identifier.uuidString,revision:revision,callbackTime:time))
        }
        return .init(id:anchor.identifier.uuidString,epoch:epoch,revision:revision,callbackTime:time,transform:transform,
                     vertices:vertices,indices:indices,classifications:classes,floorPriors:priors)
    }
}

enum SensorLayer: Int, CaseIterable, Identifiable, Codable, Sendable { case rgb,depth,confidence
    var id: Int { rawValue }
    var title: String { switch self { case .rgb: "RGB"; case .depth: "深度"; case .confidence: "置信度" } }
}
struct RenderOptions: Codable, Sendable, Equatable {
    // Optional backing keys preserve decoding of older diagnostic records.
    var cameraImageVisible: Bool? = nil
    var geometryOverlaysVisible: Bool? = nil
    var pathVisible: Bool? = nil
    var legendsVisible: Bool? = nil
    var showCameraImage: Bool { get { cameraImageVisible ?? true } set { cameraImageVisible = newValue } }
    var showOverlays: Bool { get { geometryOverlaysVisible ?? true } set { geometryOverlaysVisible = newValue } }
    var showPath: Bool { get { pathVisible ?? true } set { pathVisible = newValue } }
    var showLegends: Bool { get { legendsVisible ?? true } set { legendsVisible = newValue } }
    var layer: SensorLayer = .rgb
    var overlayDepth = false
    var overlayAlpha: Float = 0.45
    var smoothedDisplay = false
    var showMesh = false
    var showFloor = true
    var showSurfaceModel = true
    var showBlockingColumns = true
    var showGrid = true
    var showChannels = true
    var showHUD = true
    var heatMax: Float = 5
}
struct RenderMetrics: Sendable {
    var fps: Double = 0; var cpuMS: Double = 0; var gpuMS: Double = 0; var presentAgeMS: Double?
    var analysisDisplayDeltaMS: Double?; var renderedFrameID: UInt64 = 0
}
struct SharedSnapshot: Sendable {
    var usesMonocular = false
    var orientation: ImageOrientation = .portrait
    var monocular: MonocularFrame?
    var frozenMonocular: MonocularFrame?
    var monocularStatus = "等待模型推理"
    var nativePlanes: [NativePlaneObservation] = []
    var nativePlaneFrameID: UInt64 = 0
    var frame: FrameSnapshot?
    var frozen: FrameSnapshot?
    var result: AnalysisResult?
    var surfaceHistory = SurfaceHistory()
    var pathOptions = PathOptions()
    var pathUpdate = PathUpdate()
    var diagnosticResult: AnalysisResult?
    var analyzedFrame: FrameSnapshot?
    var meshes: [String:MeshSnapshot] = [:]
    var options = RenderOptions()
    var renderMetrics = RenderMetrics()
    var captureFPS: Double = 0
    var analysisFPS: Double = 0
    var meshMS: Double = 0
    var running = false
    var geometryEnabled = false
    var minimumGeometryFrameID: UInt64 = 0
    var minimumGuidanceFrameID: UInt64 = 0
    var epoch: UInt64 = 0
    var parameterVersion: UInt64 = 0
    var parameters = ProbeParameters()
    var status = "未开始"
    var renderStatus = "正在后台编译 Metal shader"
    var droppedFrames = 0
    var thermal = "nominal"
    var thermalRaw = 0
    var meshDrops = 0
    var recording = true
    var activeMonocular: MonocularFrame? {
        let prediction = frozen != nil ? frozenMonocular : monocular
        guard usesMonocular,running,let prediction,prediction.frame.epoch == epoch,prediction.frame.parameterVersion == parameterVersion else { return nil }
        if frozen == nil && ProcessInfo.processInfo.systemUptime-prediction.frame.frame.timestamp > parameters.maxResultAge { return nil }
        return prediction
    }
    var currentMonocularStatus: String {
        guard running else { return "已停止；无当前预测或尺度" }
        guard frame?.trackingNormal == true else { return "ARKit 追踪受限；尺度与模型不发布" }
        guard let prediction = activeMonocular else { return "等待及时的当前预测；旧尺度不沿用" }
        return prediction.status
    }
    /// Only a bounded historical OUTLINE can survive a brief missing native plane snapshot.
    func retainedNativeGround(now: Double) -> NativePlaneObservation? {
        guard running,geometryEnabled,frozen == nil,let prediction = activeMonocular,
              prediction.frame.id >= minimumGeometryFrameID,prediction.groundReference.mode == "retained_reference",
              let plane = prediction.groundReference.plane,
              prediction.groundReference.age+max(0,now-prediction.frame.frame.timestamp) <= 2 else { return nil }
        return plane
    }
    var displayedFrame: FrameSnapshot? {
        if let frozen { return frozen }
        if usesMonocular && (options.layer != .rgb || options.overlayDepth) { return activeMonocular?.frame ?? frame }
        return frame
    }
    var presentationGate: ResultPresentationGate {
        var gate = ResultPresentationGate()
        guard let frame else { return gate }
        gate.enabled = running && geometryEnabled && frozen == nil && thermalRaw < 3 &&
            frame.epoch == epoch && frame.parameterVersion == parameterVersion
        gate.trackingNormal = frame.trackingNormal; gate.directionStable = frame.directionStable
        gate.epoch = epoch; gate.parameterVersion = parameterVersion
        gate.frameID = frame.id; gate.frameTimestamp = frame.frame.timestamp; gate.maxAge = parameters.maxResultAge
        gate.minimumGeometryFrameID = minimumGeometryFrameID; gate.minimumGuidanceFrameID = minimumGuidanceFrameID
        return gate
    }
    func activeGeometryResult(now: Double) -> AnalysisResult? {
        guard let result,presentationGate.allowsGeometry(result,now:now) else { return nil }
        return result
    }
    func activeSurfacePresentation(now: Double) -> SurfacePresentation? {
        surfaceHistory.presentation(current:activeGeometryResult(now:now),gate:presentationGate,pose:frame?.pose,now:now)
    }
    func activePath(now: Double) -> PathPresentation? {
        guard pathOptions.enabled,let path = pathUpdate.path,let frame else { return nil }
        return PathPresentation.make(path:path,gate:presentationGate,pose:frame.pose,options:pathOptions,now:now)
    }
    func pathHeading(now: Double) -> PathHeading? {
        // Angle feedback follows the LIVE tracked pose during a normal turn. The fixed goal
        // is not reselected here; fresh tracking/epoch/TTL and near-vertical checks still apply.
        guard let path = activePath(now:now),let pose = frame?.pose else { return nil }
        return PathTracking.heading(path:path.path,pose:pose,lookAhead:pathOptions.lookAhead)
    }
    func activeGuidanceResult(now: Double) -> AnalysisResult? {
        guard let result,presentationGate.allowsGuidance(result,now:now) else { return nil }
        return result
    }
}
/// All shared mutable fields are protected by one short-held lock. No processing or I/O under the lock.
final class SharedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SharedSnapshot()
    func read() -> SharedSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    func update(_ block: (inout SharedSnapshot) -> Void) { lock.lock(); defer { lock.unlock() }; block(&value) }
}
