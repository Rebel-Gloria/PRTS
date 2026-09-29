/// Scalar and binary spatial diagnostics recorder; captured RGB is intentionally excluded.

import ARKit
import Foundation
import SpatialCore
import Darwin

nonisolated struct CaptureDiagnostic: Codable, Sendable {
    let epoch: UInt64,frameID: UInt64,parameterVersion: UInt64
    let timestamp: Double,receivedAt: Double,captureMS: Double
    let pose: RigidPose,intrinsics: CameraIntrinsics
    let tracking: String,trackingNormal: Bool,directionStable: Bool
    let direction: DirectionDiagnostics?
    let worldMappingStatus: Int,featurePointCount: Int?
    let exposureSeconds: Double,exposureOffsetEV: Float
    let ambientIntensity: CGFloat?,ambientColorTemperature: CGFloat?
    let sceneDepthAvailable: Bool,confidenceAvailable: Bool,smoothedDepthAvailable: Bool
    let depthBackend: String,modelImageOrientation: Int
    let depthWidth: Int?,depthHeight: Int?,depthPixelFormat: UInt32?,confidencePixelFormat: UInt32?
    init(_ s: FrameSnapshot) {
        depthBackend = s.usesMonocular ? "apple_coreml_no_lidar" : "arkit_scene_depth"; modelImageOrientation = s.orientation.rawValue
        epoch = s.epoch; frameID = s.id; parameterVersion = s.parameterVersion
        timestamp = s.frame.timestamp; receivedAt = s.receivedAt; captureMS = s.captureMilliseconds
        pose = s.pose; intrinsics = s.intrinsics; tracking = s.tracking; trackingNormal = s.trackingNormal
        directionStable = s.directionStable; direction = s.directionDiagnostics
        worldMappingStatus = s.frame.worldMappingStatus.rawValue; featurePointCount = s.frame.rawFeaturePoints?.points.count
        exposureSeconds = s.frame.camera.exposureDuration; exposureOffsetEV = s.frame.camera.exposureOffset
        ambientIntensity = s.frame.lightEstimate?.ambientIntensity; ambientColorTemperature = s.frame.lightEstimate?.ambientColorTemperature
        sceneDepthAvailable = s.frame.sceneDepth != nil; confidenceAvailable = s.frame.sceneDepth?.confidenceMap != nil
        smoothedDepthAvailable = s.frame.smoothedSceneDepth != nil
        depthWidth = s.frame.sceneDepth.map { CVPixelBufferGetWidth($0.depthMap) }
        depthHeight = s.frame.sceneDepth.map { CVPixelBufferGetHeight($0.depthMap) }
        depthPixelFormat = s.frame.sceneDepth.map { CVPixelBufferGetPixelFormatType($0.depthMap) }
        confidencePixelFormat = s.frame.sceneDepth?.confidenceMap.map { CVPixelBufferGetPixelFormatType($0) }
    }
}
// Transport values are encoded on the journal queue, not on the UI actor.
nonisolated struct RenderDiagnostic: Codable, Sendable {
    let phase: String
    var routeContext: RouteContext? = nil
    var routePublicationReason: String? = nil
    var routePublishTime: Double? = nil
    var routePresentationReason: String? = nil
    var routeDisplayedVerifiedLength: Float? = nil
    var routeDisplayedPlannedLength: Float? = nil
    let renderID: UInt64,epoch: UInt64,frameID: UInt64?
    let uptime: Double,sourceTimestamp: Double?,analysisFrameID: UInt64?,analysisTimestamp: Double?
    let geometryBlockReason: String?,guidanceBlockReason: String?,modelBlockReasons: [String]
    let running: Bool,frozen: Bool
    let options: RenderOptions
    let surfaceVertices: Int,blockingVertices: Int,channelVertices: Int
    let cpuMS: Double,drawableWidth: Double,drawableHeight: Double
    let orientation: Int?
    let rgbSubmitted: Bool,imageDisplayTransform: [Double]?,contentRect: [Double]?
    var surfaceSourceFrameID: UInt64? = nil
    var surfacePresentationMode: String? = nil
    var surfaceAgeMS: Double? = nil
    var depthBackend: String? = nil
    var nativePlaneVertices: Int? = nil
    var predictionSourceFrameID: UInt64? = nil
    var predictionScaleConfirmed: Bool? = nil
    var pathID: UInt64? = nil
    var pathHistorical: Bool? = nil
    var pathAge: Double? = nil
    var pathVertices: Int? = nil
    var pathApproachVertices: Int? = nil
    var pathTargetVertices: Int? = nil
}
final class DiagnosticRecorder: @unchecked Sendable {
    let journal: DiagnosticJournal
    init() {
        var hardware = utsname(); uname(&hardware)
        let machine = withUnsafePointer(to:&hardware.machine) { $0.withMemoryRebound(to:CChar.self,capacity:256) { String(cString:$0) } }
        #if targetEnvironment(simulator)
        let environment = "simulator_no_LiDAR_evidence"
        #else
        let environment = "device"
        #endif
        #if DEBUG
        let buildConfiguration = "Debug"
        #else
        let buildConfiguration = "Release"
        #endif
        #if PRTS_DEV_CAPTURE
        let privacy = "PRTS_DEV_CAPTURE compiled; opt-in RGB video and full analysis may exist in dev-capture-* folders. No audio/GPS/upload."
        #else
        let privacy = "No RGB or video saved."
        #endif
        let metadata = ["buildConfiguration":buildConfiguration,
            "clearanceFramePixelBudget":String(VisibilityDepth.defaultFramePixelBudget),"applicationVersion":Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? "unknown",
            "build":Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? "unknown","bundleID":Bundle.main.bundleIdentifier ?? "unknown",
            "hardware":machine,"os":ProcessInfo.processInfo.operatingSystemVersionString,"environment":environment,
            "meshDiagnosticEncoding":"mesh_frame_binary_v1; full Float32 vertices, UInt32 indices and UInt8 classifications; no mesh subsampling by recorder",
            "surfaceTriangleBudget":String(SurfaceModelBuilder.triangleBudget),
            "groundConfirmationMetric":"local plane height at camera <4cm and normal angle <3deg; 3 current confirmations",
            "groundReferencePolicy":"Obstacle-veto: fixed world drawing reference from plane/grid/prior or initial camera height 1.4m. Ground/evidence TTL is diagnostic only. Epoch/reset changes still invalidate.",
            "planningPolicy":PRTSRuntimeProfile.routePlanningPolicy.rawValue, "routeSchemaVersion":"3",
            "routeAlgorithmRevision":"turn_tail_v2; yaw dwell 3s/10deg/0.75s gap; full-segment greedy prefix; collinear tail coalescing",
            "occupancyRule":"Only confirmed occupancy blocks search; other cells are hypothesis-searchable. Confirmation 0.3s, maximum matching gap 0.75s, missing hits reset. Raw sensor grid unchanged.",
            "routeEvidenceOptions":String(data:(try? DiagnosticJSON.encode(RouteEvidenceOptions())) ?? Data(),encoding:.utf8) ?? "unavailable",
            "routeContinuityOptions":String(data:(try? DiagnosticJSON.encode(RouteContinuityOptions())) ?? Data(),encoding:.utf8) ?? "unavailable",
            "commit":Bundle.main.object(forInfoDictionaryKey:"PRTSCommit") as? String ?? "unavailable",
            "coordinateConvention":"ARKit gravity world; camera forward -Z; pixel centers integer. depth_frame meters axial; relative_depth_frame inverse-relative, NOT meters.",
            "absentSensors":"No separate raw IMU or GPS acquisition. ARKit feature count, not its private SLAM map. " + privacy]
        let root = FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Diagnostics",isDirectory:true)
        journal = DiagnosticJournal(root:root,metadata:metadata)
        event("app_launched",details:environment,epoch:0)
    }
    func event(_ name: String,details: String,epoch: UInt64) {
        if name == "scene_phase" { journal.noteLifecycle(details) }
        if name == "will_terminate" { journal.noteLifecycle("will_terminate") }
        nonisolated struct Event: Encodable, Sendable { let name: String,details: String,epoch: UInt64,uptime: Double,wallTime: String }
        let event = Event(name:name,details:details,epoch:epoch,uptime:ProcessInfo.processInfo.systemUptime,wallTime:ISO8601DateFormatter().string(from:Date()))
        journal.submit(.events) { .init(json:try DiagnosticJSON.encode(event)) }
    }
    func capture(_ frame: FrameSnapshot) {
        let record = CaptureDiagnostic(frame) // Scalars only: does not retain ARFrame/capturedImage buffers.
        journal.submit(.capture) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func routePublication(candidate: PathUpdate,state: SharedSnapshot,now: Double,captureEnabled: Bool,analysisStart: Double,analysisEnd: Double,previousCaptureTimestamp: Double?) {
        nonisolated struct Record: Encodable, Sendable {
            let schemaVersion = 3
            let phase = "publication"
            let captureEnabled: Bool
            let context: RouteContext?
            let publishedContext: RouteContext?
            let publicationReason: String
            let publishTime: Double
            let hazardWatermark: UInt64
            let analysisStart: Double,analysisEnd: Double
            let actualAnalysisInterval: Double?
            let thermalState: String
        }
        let record = Record(captureEnabled:captureEnabled,context:candidate.continuity,publishedContext:state.pathUpdate.continuity,
                            publicationReason:state.routePublicationReason,publishTime:now,
                            hazardWatermark:state.routeHazardWatermark,analysisStart:analysisStart,analysisEnd:analysisEnd,
                            actualAnalysisInterval:previousCaptureTimestamp.flatMap { previous in candidate.continuity.map { $0.timestamp-previous } },
                            thermalState:state.thermal)
        journal.submit(.path) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func path(_ update: PathUpdate,frame: FrameSnapshot,options: PathOptions) {
        nonisolated struct Record: Encodable, Sendable {
            let phase = "prediction"
            let schemaVersion = 3
            let epoch: UInt64,frameID: UInt64,parameterVersion: UInt64
            let timestamp: Double
            let update: PathUpdate,options: PathOptions
        }
        let record = Record(epoch:frame.epoch,frameID:frame.id,parameterVersion:frame.parameterVersion,timestamp:frame.frame.timestamp,update:update,options:options)
        journal.submit(.path,estimatedBytes:16*1024) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func pathFeedback(epoch: UInt64,frameID: UInt64,pathID: UInt64?,heading: PathHeading?,pulse: PathHapticPulse?,status: String) {
        nonisolated struct Record: Encodable, Sendable {
            let phase = "feedback"
            let epoch: UInt64,frameID: UInt64,pathID: UInt64?
            let uptime: Double,heading: PathHeading?,pulse: PathHapticPulse?,status: String
        }
        let record = Record(epoch:epoch,frameID:frameID,pathID:pathID,uptime:ProcessInfo.processInfo.systemUptime,heading:heading,pulse:pulse,status:status)
        journal.submit(.path) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func analysis(_ result: AnalysisResult,frame: FrameSnapshot,observation: DepthObservation?,metrics: MetricContext) {
        nonisolated struct Record: Encodable, Sendable {
            let frame: FrameLog,capture: CaptureDiagnostic,diagnostics: AnalysisDiagnostics?
            let depthAttachmentExpected: Bool
            let depthAttachmentKind = "depth_frame"
        }
        let record = Record(frame:FrameLog(result,frame:frame,metrics:metrics),capture:CaptureDiagnostic(frame),diagnostics:result.diagnostics,depthAttachmentExpected:observation != nil)
        let cost = 64*1024+(observation.map { $0.depth.count*5 } ?? 0)+result.floorPriors.count*128
        let priors = result.floorPriors,parameters = result.parameters,version = result.parameterVersion,stable = frame.directionStable,source = result.source
        journal.submit(.analysis,estimatedBytes:cost) {
            let binary = try observation.map { try DepthFrameCodec.encode($0,parameters:parameters,parameterVersion:version,priors:priors,directionStable:stable,source:source) }
            return .init(json:try DiagnosticJSON.encode(record),binary:binary)
        }
    }
    func monocular(_ prediction: MonocularFrame,manual: Bool = false) {
        nonisolated struct Header: Encodable, Sendable {
            let schemaVersion = 1,kind = "relative_depth_frame"
            let model = "apple/coreml-depth-anything-v2-small/DepthAnythingV2SmallF16"
            let modelRevision = "cfef6f6f2a70783dedc0bfae40cecbc2052285d3"
            let units = "relative_inverse_depth_not_meters"
            let planeTimeSemantics = "ARFrame_anchor_snapshot_not_surface_observation_time"
            let width: Int,height: Int,depthBytes: Int,epoch: UInt64,frameID: UInt64,parameterVersion: UInt64,timestamp: Double
            let pose: RigidPose,intrinsics: CameraIntrinsics,orientation: Int
            let nativePlanes: [NativePlaneObservation],scaleSamples: [ScaleSample],calibration: InverseDepthCalibration?
            let status: String,milliseconds: Double,manual: Bool,timings: [String:Double]
            let scaleDecision: MetricScaleDecision,provisionalFit: InverseDepthCalibration?,groundReference: NativeGroundSelection
            let relativeCoverage: Float
            let temporalScalePolicy = "native_world_reference_reprojection_v1_no_equal_raw_q_comparison"
        }
        let f = prediction.frame
        let h = Header(width:prediction.width,height:prediction.height,depthBytes:prediction.relative.count*4,epoch:f.epoch,frameID:f.id,parameterVersion:f.parameterVersion,timestamp:f.frame.timestamp,
            pose:f.pose,intrinsics:f.intrinsics.scaled(width:prediction.width,height:prediction.height),orientation:f.orientation.rawValue,nativePlanes:prediction.planes,scaleSamples:prediction.samples,calibration:prediction.calibration,status:prediction.status,milliseconds:prediction.milliseconds,manual:manual,timings:prediction.timings,scaleDecision:prediction.scaleDecision,provisionalFit:prediction.provisionalFit,groundReference:prediction.groundReference,relativeCoverage:prediction.relativeCoverage)
        // Capture only scalar metadata and value arrays, never MonocularFrame/ARFrame/RGB buffers.
        let relative = prediction.relative
        let cost = relative.count*8+h.nativePlanes.reduce(0) { $0+$1.boundary.count*64+1024 }+h.scaleSamples.count*256+65536
        journal.submit(.prediction,estimatedBytes:cost) {
            let json = try DiagnosticJSON.encode(h)
            var length = UInt32(json.count).littleEndian
            var binary = withUnsafeBytes(of:&length) { Data($0) }; binary.append(json)
            relative.withUnsafeBytes { binary.append(contentsOf:$0) }
            return .init(json:json,binary:binary)
        }
    }
    func mesh(_ mesh: MeshSnapshot?,id: String,epoch: UInt64,revision: UInt64,callbackTime: Double,action: String) {
        nonisolated struct Record: Encodable, Sendable {
            let id: String,epoch: UInt64,revision: UInt64,callbackTime: Double,processedUptime: Double,action: String
            let vertices: Int,faces: Int,classificationCounts: [String:Int]
            let attachmentKind = "mesh_frame_binary_v1"
        }
        let counts = mesh.map { Dictionary(grouping:$0.classifications,by:{ String($0) }).mapValues(\.count) } ?? [:]
        let record = Record(id:id,epoch:epoch,revision:revision,callbackTime:callbackTime,processedUptime:ProcessInfo.processInfo.systemUptime,action:action,
                            vertices:mesh?.vertices.count ?? 0,faces:(mesh?.indices.count ?? 0)/3,classificationCounts:counts)
        journal.submit(.mesh,estimatedBytes:max(4096,(mesh?.byteCount ?? 0)*2+(mesh?.floorPriors.count ?? 0)*256+4096)) {
            .init(json:try DiagnosticJSON.encode(record),binary:try mesh.map {
                try MeshFrameCodec.encode(id:$0.id,epoch:$0.epoch,revision:$0.revision,callbackTime:$0.callbackTime,
                    transform:$0.transform,vertices:$0.vertices,indices:$0.indices,classifications:$0.classifications,
                    floorPriors:$0.floorPriors,source:"device")
            })
        }
    }
    func renderSkipped(renderID: UInt64,state: SharedSnapshot,reason: String) {
        guard state.running else { return }
        nonisolated struct Skip: Encodable, Sendable { let phase = "skipped"; let renderID: UInt64,epoch: UInt64,frameID: UInt64?,uptime: Double,reason: String }
        let value = Skip(renderID:renderID,epoch:state.epoch,frameID:state.frame?.id,uptime:ProcessInfo.processInfo.systemUptime,reason:reason)
        journal.submit(.render) { .init(json:try DiagnosticJSON.encode(value)) }
    }
    func render(_ record: RenderDiagnostic) { journal.submit(.render) { .init(json:try DiagnosticJSON.encode(record)) } }
    func gpu(renderID: UInt64,epoch: UInt64,frameID: UInt64?,status: String,error: String?,gpuMS: Double) {
        nonisolated struct GPU: Encodable, Sendable { let phase = "gpu_completed"; let renderID: UInt64,epoch: UInt64,frameID: UInt64?,uptime: Double,status: String,error: String?,gpuMS: Double }
        let record = GPU(renderID:renderID,epoch:epoch,frameID:frameID,uptime:ProcessInfo.processInfo.systemUptime,status:status,error:error,gpuMS:gpuMS)
        journal.submit(.render) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func presented(renderID: UInt64,epoch: UInt64,frameID: UInt64?,time: Double,sourceTime: Double?) {
        nonisolated struct Presented: Encodable, Sendable { let phase = "drawable_presented"; let renderID: UInt64,epoch: UInt64,frameID: UInt64?,presentedTime: Double,sourceTimestamp: Double? }
        let record = Presented(renderID:renderID,epoch:epoch,frameID:frameID,presentedTime:time,sourceTimestamp:sourceTime)
        journal.submit(.render) { .init(json:try DiagnosticJSON.encode(record)) }
    }
    func heartbeat(_ state: SharedSnapshot,permission: String,batteryLevel: Float,batteryState: Int,lowPower: Bool,appState: String) {
        nonisolated struct Heartbeat: Encodable, Sendable {
            let uptime: Double,epoch: UInt64,running: Bool,permission: String,appState: String
            let frameID: UInt64?,frameAge: Double?,analysisFrameID: UInt64?,analysisAge: Double?
            let tracking: String?,thermal: String,thermalRaw: Int,lowPower: Bool,batteryLevel: Float,batteryState: Int
            let residentBytes: UInt64?,meshCount: Int,meshBytes: Int,captureFPS: Double,analysisFPS: Double,renderFPS: Double
            let analysisDrops: Int,meshDrops: Int,parameters: ProbeParameters,parameterVersion: UInt64,options: RenderOptions
            let diagnosticStatus: DiagnosticStatus
            let depthBackend: String,modelStatus: String,nativePlaneCount: Int
        }
        let now = ProcessInfo.processInfo.systemUptime
        let record = Heartbeat(uptime:now,epoch:state.epoch,running:state.running,permission:permission,appState:appState,
            frameID:state.frame?.id,frameAge:state.frame.map { now-$0.frame.timestamp },analysisFrameID:state.diagnosticResult?.frameID,analysisAge:state.diagnosticResult.map { now-$0.timestamp },
            tracking:state.frame?.tracking,thermal:state.thermal,thermalRaw:state.thermalRaw,lowPower:lowPower,batteryLevel:batteryLevel,batteryState:batteryState,
            residentBytes:Self.residentBytes(),meshCount:state.meshes.count,meshBytes:state.meshes.values.reduce(0) { $0+$1.byteCount },captureFPS:state.captureFPS,
            analysisFPS:state.analysisFPS,renderFPS:state.renderMetrics.fps,analysisDrops:state.droppedFrames,meshDrops:state.meshDrops,
            parameters:state.parameters,parameterVersion:state.parameterVersion,options:state.options,diagnosticStatus:journal.status(),depthBackend:state.usesMonocular ? "apple_coreml_no_lidar" : "arkit_scene_depth",modelStatus:state.monocularStatus,nativePlaneCount:state.nativePlanes.count)
        journal.submit(.heartbeat) { .init(json:try DiagnosticJSON.encode(record)) }
        journal.requestCheckpoint()
    }
    private static func residentBytes() -> UInt64? {
        var info = mach_task_basic_info(),count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size/MemoryLayout<natural_t>.size)
        let code = withUnsafeMutablePointer(to:&info) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(MACH_TASK_BASIC_INFO),$0,&count) } }
        return code == KERN_SUCCESS ? UInt64(info.resident_size) : nil
    }
}
