/// Owns the single ARSession, bounded frame mailbox, analysis worker, mesh cache and diagnostic journal.

import ARKit
import AVFoundation
import Foundation
import SpatialCore

private struct AnalysisJob: Sendable { let frame: FrameSnapshot; let priors: [FloorPrior] }
private struct MeshJob: @unchecked Sendable {
    let anchor: ARMeshAnchor?; let id: String; let epoch: UInt64; let time: Double
}
private final class MeshInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String:MeshJob] = [:]
    private var running = false
    func submit(_ job: MeshJob) -> (schedule: Bool,evicted: String?) {
        lock.lock(); defer { lock.unlock() }
        var evicted: String?
        if pending[job.id] == nil,pending.count >= 32,let oldest = pending.min(by:{ $0.value.time < $1.value.time })?.key {
            pending.removeValue(forKey:oldest); evicted = oldest
        }
        pending[job.id] = job
        if running { return (false,evicted) }
        running = true; return (true,evicted)
    }
    func next() -> MeshJob? {
        lock.lock(); defer { lock.unlock() }
        guard let key = pending.min(by:{ $0.value.time < $1.value.time })?.key else { running = false; return nil }
        return pending.removeValue(forKey:key)
    }
    func clear() { lock.lock(); pending.removeAll(); lock.unlock() }
}

struct DeviceCapabilities: Sendable {
    let world: Bool,depth: Bool,meshClassification: Bool,smooth: Bool,planeClassification: Bool
    static func detect() -> DeviceCapabilities {
        #if targetEnvironment(simulator)
        return .init(world:false,depth:false,meshClassification:false,smooth:false,planeClassification:false)
        #else
        return .init(world:ARWorldTrackingConfiguration.isSupported,
                     depth:ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
                     meshClassification:ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification),
                     smooth:ARWorldTrackingConfiguration.supportsFrameSemantics([.sceneDepth,.smoothedSceneDepth]),planeClassification:ARPlaneAnchor.isClassificationSupported)
        #endif
    }
    var description: String {
        "世界追踪 \(world ? "✓" : "缺失") · sceneDepth \(depth ? "✓" : "缺失") · 网格分类 \(meshClassification ? "✓" : "缺失") · 平面分类 \(planeClassification ? "✓" : "缺失")"
    }
}

/// ARSession owns capture. Session state and DirectionGate belong to sessionQueue;
/// SpatialAnalyzer belongs to analysisQueue; meshes are copied on meshQueue. SharedStore is lock-protected.
final class ProbeEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let store = SharedStore()
    let diagnostics = DiagnosticRecorder()
    #if PRTS_DEV_CAPTURE
    let devCapture: DevCaptureRecorder
    #endif
    let recorder: SessionRecorder
    let capabilities = DeviceCapabilities.detect()
    private let session = ARSession()
    private let sessionQueue = DispatchQueue(label:"probe.session",qos:.userInitiated)
    private let analysisQueue = DispatchQueue(label:"probe.analysis",qos:.userInitiated)
    private let meshQueue = DispatchQueue(label:"probe.mesh",qos:.utility)
    private let mailbox = LatestMailbox<AnalysisJob>()
    private let meshInbox = MeshInbox()
    private let analyzer = SpatialAnalyzer()
    private var pathPredictor = PathPredictor() // analysisQueue only
    private let monocularProvider = MonocularDepthProvider()
    private var directionGate = DirectionGate()
    private var epoch: UInt64 = 0
    private var frameID: UInt64 = 0
    private var meshRevision: UInt64 = 0 // meshQueue only
    private var lastSubmitted: Double = 0
    private var lastFrameTime: Double = 0
    private var lastAnalysisCompletion: Double = 0 // analysisQueue only
    private var analysisBarrier: UInt64 = 0 // analysisQueue only
    private var captureFPS: Double = 0
    override init() {
        #if PRTS_DEV_CAPTURE
        devCapture = DevCaptureRecorder(root:diagnostics.journal.directory)
        #endif
        recorder = SessionRecorder(diagnostics:diagnostics)
        super.init(); session.delegate = self; session.delegateQueue = sessionQueue
        let mono = DepthBackendPolicy(supportsSceneDepth:capabilities.depth,requestedSimulation:UserDefaults.standard.bool(forKey:"simulateNoLiDAR") || ProcessInfo.processInfo.arguments.contains("--simulate-no-lidar")).usesMonocular
        store.update { $0.status = capabilities.description; $0.usesMonocular = mono }
        diagnostics.event("capabilities",details:capabilities.description+"; initialBackend="+(mono ? "apple_coreml_no_lidar" : "arkit_sceneDepth"),epoch:0)
    }
    func start(device: [String:String]) {
        sessionQueue.async { [self] in
            guard !store.read().running else { return }
            guard capabilities.world else { store.update { $0.status = "缺少世界追踪；模拟器仅验证界面，不能验收 LiDAR" }; diagnostics.event("session_start_rejected",details:capabilities.description,epoch:epoch); return }
            epoch &+= 1; frameID = 0; lastSubmitted = 0; lastFrameTime = 0; captureFPS = 0
            directionGate.reset(); mailbox.discardPending(resetDropCount:true); meshInbox.clear()
            let s = store.read(),config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            if s.usesMonocular { config.planeDetection = [.horizontal,.vertical] }
            if !s.usesMonocular && capabilities.depth { config.frameSemantics.insert(.sceneDepth) }
            if !s.usesMonocular && s.options.smoothedDisplay && capabilities.smooth { config.frameSemantics.insert(.smoothedSceneDepth) }
            if !s.usesMonocular && capabilities.meshClassification { config.sceneReconstruction = .meshWithClassification }
            store.update {
                $0.minimumGeometryFrameID = 0; $0.minimumGuidanceFrameID = 0
                $0.epoch = epoch; $0.running = true; $0.geometryEnabled = false; $0.frame = nil; $0.frozen = nil; $0.result = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.diagnosticResult = nil; $0.analyzedFrame = nil; $0.meshes = [:]; $0.monocular = nil; $0.frozenMonocular = nil; $0.nativePlanes = []; $0.nativePlaneFrameID = 0; $0.monocularStatus = "等待当前预测及尺度确认"
                $0.status = "会话启动中；" + capabilities.description; $0.captureFPS = 0; $0.analysisFPS = 0; $0.droppedFrames = 0; $0.meshDrops = 0
            }
            recorder.begin(epoch:epoch,parameters:s.parameters,device:device)
            diagnostics.event("session_configuration",details:"backend=\(s.usesMonocular ? "monocular" : "lidar"),frameSemantics=\(config.frameSemantics.rawValue),sceneReconstruction=\(config.sceneReconstruction.rawValue),planeDetection=\(config.planeDetection.rawValue)",epoch:epoch)
            session.run(config,options:[.resetTracking,.removeExistingAnchors])
            recorder.event("session_started",details:capabilities.description+"; backend="+(s.usesMonocular ? "apple_coreml_no_lidar" : "arkit_sceneDepth")+"; nativePlaneClassification=\(ARPlaneAnchor.isClassificationSupported)",epoch:epoch)
        }
    }
    func stop(reason: String = "用户停止") {
        #if PRTS_DEV_CAPTURE
        devCapture.stop()
        #endif
        diagnostics.event("stop_requested",details:reason,epoch:store.read().epoch)
        // Immediately blank outputs, without waiting for background work.
        store.update { $0.running = false; $0.geometryEnabled = false; $0.frame = nil; $0.frozen = nil; $0.result = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.diagnosticResult = nil; $0.analyzedFrame = nil; $0.meshes = [:]; $0.monocular = nil; $0.frozenMonocular = nil; $0.nativePlanes = []; $0.nativePlaneFrameID = 0; $0.monocularStatus = "已停止；无当前预测或尺度"; $0.status = reason }
        mailbox.discardPending(); meshInbox.clear()
        sessionQueue.async { [self] in session.pause(); directionGate.reset(); recorder.event("invalidated",details:reason,epoch:epoch); recorder.finish(epoch:epoch) }
    }
    func flushDiagnostics(lifecycle: String,completion: @escaping @Sendable () -> Void) {
        diagnostics.journal.noteLifecycle(lifecycle)
        sessionQueue.async { [self] in
            analysisQueue.async { [self] in
                meshQueue.async { [self] in
                    #if PRTS_DEV_CAPTURE
                    devCapture.stop { [self] in diagnostics.journal.flush(completion:completion) }
                    #else
                    diagnostics.journal.flush(completion:completion)
                    #endif
                }
            }
        }
    }
    func setSimulatedNoLiDAR(_ requested: Bool,device: [String:String]) {
        let effective = DepthBackendPolicy(supportsSceneDepth:capabilities.depth,requestedSimulation:requested).usesMonocular
        let wasRunning = store.read().running
        guard effective != store.read().usesMonocular else { return }
        stop(reason:"深度来源切换，旧证据已清空")
        UserDefaults.standard.set(requested,forKey:"simulateNoLiDAR")
        store.update { $0.usesMonocular = effective; $0.monocularStatus = "等待模型推理" }
        diagnostics.event("depth_backend_changed",details:effective ? "apple_coreml_no_lidar" : "arkit_sceneDepth",epoch:store.read().epoch)
        if wasRunning { start(device:device) }
    }
    func updateParameters(_ parameters: ProbeParameters) {
        store.update { $0.parameters = parameters.validated(); $0.parameterVersion &+= 1; $0.result = nil; $0.monocular = nil; $0.frozenMonocular = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.geometryEnabled = false }
        let s = store.read()
        recorder.event("parameters_changed",details:String(data:(try? JSONEncoder().encode(s.parameters)) ?? Data(),encoding:.utf8) ?? "",epoch:s.epoch)
    }
    func updatePathOptions(_ options: PathOptions) {
        store.update {
            $0.pathOptions = options.validated()
            if !options.enabled { $0.pathUpdate = .init(reason:"disabled") }
            // Feedback/display controls do not restart ground or metric-scale confirmation.
            // Geometry/body parameters retain their separate version/barrier path.
        }
        diagnostics.event("path_options",details:String(data:(try? DiagnosticJSON.encode(options.validated())) ?? Data(),encoding:.utf8) ?? "",epoch:store.read().epoch)
    }
    func updateOptions(_ options: RenderOptions) { store.update { $0.options = options }; diagnostics.event("render_options",details:String(data:(try? DiagnosticJSON.encode(options)) ?? Data(),encoding:.utf8) ?? "encode_failed",epoch:store.read().epoch) }
    func freeze() {
        diagnostics.event("freeze_toggle",details:store.read().frozen == nil ? "frozen" : "live",epoch:store.read().epoch)
        store.update { s in
            if s.frozen != nil { s.frozen = nil; s.frozenMonocular = nil } else {
                let prediction = s.activeMonocular
                s.frozen = s.usesMonocular ? (prediction?.frame ?? s.frame) : s.frame
                s.frozenMonocular = prediction
            }
            s.result = nil; s.surfaceHistory.reset(); s.pathUpdate = .init(reason:"invalidated")
            s.minimumGeometryFrameID = (s.frame?.id ?? 0) + 1
            s.minimumGuidanceFrameID = s.minimumGeometryFrameID
        }
    }
    func manualSample(display: [String:String]) {
        let s = store.read()
        if s.usesMonocular {
            if let prediction = s.activeMonocular { diagnostics.monocular(prediction,manual:true); recorder.predictionSampleSubmitted() }
            else { diagnostics.event("manual_prediction_unavailable",details:"no fresh matching prediction",epoch:s.epoch) }
            return
        }
        guard let frame = s.frozen ?? s.analyzedFrame ?? s.displayedFrame else { return }
        recorder.manualSample(frame:frame,result:s.diagnosticResult?.frameID == frame.id ? s.diagnosticResult : nil,meshes:Array(s.meshes.values),display:display)
    }
    func setThermal(raw: Int,name: String) {
        store.update {
            $0.thermalRaw = raw; $0.thermal = name
            if raw >= 3 {
                $0.result = nil; $0.monocular = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.geometryEnabled = false
                $0.minimumGeometryFrameID = ($0.frame?.id ?? 0) + 1
                $0.minimumGuidanceFrameID = $0.minimumGeometryFrameID
            }
        }
        let s = store.read(); recorder.event("thermal_changed",details:name,epoch:s.epoch)
    }
    func session(_ session: ARSession,didUpdate frame: ARFrame) {
        let received = ProcessInfo.processInfo.systemUptime
        let s = store.read(); guard s.running else { return }
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        let stable = directionGate.update(pose:RigidPose(frame.camera.transform),time:frame.timestamp,trackingNormal:normal,parameters:s.parameters)
        frameID &+= 1
        if lastFrameTime > 0,frame.timestamp > lastFrameTime {
            let instant = 1/(frame.timestamp-lastFrameTime); captureFPS = captureFPS == 0 ? instant : captureFPS*0.9+instant*0.1
        }
        lastFrameTime = frame.timestamp
        let snapshot = FrameSnapshot(frame:frame,epoch:epoch,id:frameID,receivedAt:received,directionStable:stable,parameters:s.parameters,parameterVersion:s.parameterVersion,directionDiagnostics:directionGate.diagnostics,usesMonocular:s.usesMonocular,orientation:s.orientation)
        diagnostics.capture(snapshot)
        if case .limited(.relocalizing) = frame.camera.trackingState { stop(reason:"重定位：旧证据已清空，请重新开始"); return }
        store.update {
            guard $0.running,$0.epoch == epoch else { return }
            $0.frame = snapshot; $0.captureFPS = captureFPS
            $0.geometryEnabled = normal && $0.thermalRaw < 3
            if !$0.geometryEnabled {
                $0.result = nil; $0.monocular = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.minimumGeometryFrameID = snapshot.id + 1
            }
            if !stable || !$0.geometryEnabled { $0.minimumGuidanceFrameID = snapshot.id + 1 }
            $0.status = s.usesMonocular ? "无LiDAR模式 · "+snapshot.tracking : frame.sceneDepth == nil ? "sceneDepth 未提供；" + snapshot.tracking : snapshot.tracking
        }
        if s.geometryEnabled != (normal && s.thermalRaw < 3) || s.frame?.tracking != snapshot.tracking || s.frame?.directionStable != stable {
            recorder.event("output_gate",details:"tracking=\(snapshot.tracking),directionStable=\(stable),geometryEnabled=\(normal && s.thermalRaw < 3),guidanceEnabled=\(normal && stable && s.thermalRaw < 3),thermal=\(s.thermalRaw)",epoch:epoch)
        }
        guard s.thermalRaw < 3 else { return }
        let hz = s.thermalRaw >= 2 ? min(5,s.parameters.processingHz) : s.parameters.processingHz
        guard frame.timestamp-lastSubmitted >= 1/hz else { return }
        lastSubmitted = frame.timestamp
        // Priors only; current depth must independently support the ground. Cache age isn't surface age.
        let priors = s.meshes.values.sorted { $0.id < $1.id }.flatMap(\.floorPriors)
        let job = AnalysisJob(frame:snapshot,priors:priors)
        if mailbox.submit(job) { analysisQueue.async { [self] in drainAnalysis() } }
        store.update { $0.droppedFrames = mailbox.dropped }
    }
    private func drainAnalysis() {
        while let job = mailbox.next() {
            autoreleasepool {
                let frame = job.frame,before = store.read()
                guard before.running,before.epoch == frame.epoch,before.parameterVersion == frame.parameterVersion else { return }
                // A tracking interruption can be shorter than the analysis interval. Observe the
                // capture-side barrier so skipped limited frames cannot leave an old reference alive.
                if analysisBarrier != before.minimumGeometryFrameID {
                    analyzer.reset(); pathPredictor.reset(); monocularProvider.reset(); analysisBarrier = before.minimumGeometryFrameID
                }
                guard frame.id >= before.minimumGeometryFrameID || !frame.trackingNormal else { return }
                var result: AnalysisResult
                let copyStart = ProcessInfo.processInfo.systemUptime
                var prediction: MonocularFrame?
                var depthRead: FrameSnapshot.DepthRead
                if frame.usesMonocular {
                    do {
                        prediction = try monocularProvider.predict(frame)
                        depthRead = .init(observation:prediction?.observation,status:prediction?.calibration == nil ? "relative_depth_scale_unconfirmed" : "predicted_depth_arkit_aligned",confidenceStatus:"not_provided_by_model")
                        if let prediction { diagnostics.monocular(prediction) }
                    } catch {
                        monocularProvider.reset()
                        depthRead = .init(status:"coreml_error: \(error.localizedDescription)",confidenceStatus:"not_provided_by_model")
                        diagnostics.event("coreml_error",details:error.localizedDescription,epoch:frame.epoch)
                    }
                } else { depthRead = frame.readDepth() }
                let observation = depthRead.observation
                let copyMS = (ProcessInfo.processInfo.systemUptime-copyStart)*1000
                if let observation,frame.trackingNormal {
                    if frame.usesMonocular {
                        result = PredictedGeometry.analyze(observation,ground:prediction?.ground,parameters:frame.parameters,parameterVersion:frame.parameterVersion,groundReference:prediction?.groundReference)
                    } else { result = analyzer.analyze(observation,priors:job.priors,parameters:frame.parameters,parameterVersion:frame.parameterVersion,directionStable:frame.directionStable) }
                } else {
                    if frame.trackingNormal {
                        analyzer.missingDepth(pose:frame.pose,time:frame.frame.timestamp,frameID:frame.id,epoch:frame.epoch,parameterVersion:frame.parameterVersion)
                    } else { analyzer.reset() }
                    result = AnalysisResult(epoch:frame.epoch,frameID:frame.id,timestamp:frame.frame.timestamp,parameters:frame.parameters,
                                            parameterVersion:frame.parameterVersion,status:frame.trackingNormal ? (frame.usesMonocular ? "当前米制预测不可用；相对输出不代表尺度已确认" : "未知：sceneDepth 不可用") : "未知：追踪受限")
                }
                if frame.usesMonocular {
                    result.source = "apple_coreml_relative_depth_arkit_alignment"
                    if observation == nil { result.status = prediction?.status ?? depthRead.status }
                    result.stageMilliseconds["modelPipeline"] = prediction?.milliseconds ?? copyMS
                    if let prediction { result.stageMilliseconds.merge(prediction.timings,uniquingKeysWith:{$1}) }
                }
                if result.diagnostics == nil { result.diagnostics = AnalysisDiagnostics(); result.diagnostics?.modelState = "blocked"; result.diagnostics?.modelBlockReasons = [frame.trackingNormal ? depthRead.status : "tracking_not_normal"] }
                if let prediction {
                    result.diagnostics?.groundReferenceMode = prediction.groundReference.mode == "retained_reference" ? "retained_native_reference" : "native_\(prediction.groundReference.mode)"
                    result.diagnostics?.groundReferenceAge = prediction.groundReference.age
                    if prediction.scaleDecision.invalidatesHistory { result.diagnostics?.groundReferenceInvalidation = "metric_world_reference_conflict" }
                    if ["native_ground_conflict","new_plane_conflict_reconfirming"].contains(prediction.groundReference.reason) {
                        result.diagnostics?.groundReferenceInvalidation = prediction.groundReference.reason
                    }
                }
                result.diagnostics?.depthReadStatus = depthRead.status
                result.diagnostics?.confidenceReadStatus = depthRead.confidenceStatus
                if result.diagnostics?.depth == nil,let observation { result.diagnostics?.depth = DepthStatistics(observation,parameters:frame.parameters) }
                result.stageMilliseconds[frame.usesMonocular ? "modelWorker" : "depthCopy"] = copyMS
                result.sourcePose = frame.pose
                let pathUpdate = pathPredictor.update(result:result,observation:observation,options:before.pathOptions,directionStable:frame.directionStable)
                result.stageMilliseconds["pathPrediction"] = pathUpdate.milliseconds
                diagnostics.path(pathUpdate,frame:frame,options:before.pathOptions)
                let now = ProcessInfo.processInfo.systemUptime
                let hz = lastAnalysisCompletion > 0 ? 1/max(0.001,now-lastAnalysisCompletion) : 0
                lastAnalysisCompletion = now
                store.update { s in
                    guard s.running,s.epoch == frame.epoch,s.parameterVersion == frame.parameterVersion else { return }
                    // Even a delayed obstacle/conflict may REMOVE a line; it may never publish
                    // a delayed replacement. Safety invalidation is not tied to display freshness.
                    if frame.id >= s.minimumGeometryFrameID,
                       (["current_obstacle_invalidated","replanned_around_obstacle","ground_or_metric_conflict","ground_evidence_expired"].contains(pathUpdate.reason) ||
                        ["target_reached","target_out_of_range","target_blocked"].contains(pathUpdate.goalChangeReason ?? "")) {
                        s.pathUpdate = .init(reason:pathUpdate.reason)
                    }
                    s.diagnosticResult = result; s.analyzedFrame = frame
                    if frame.usesMonocular,frame.id >= s.minimumGeometryFrameID {
                        s.monocular = prediction; s.monocularStatus = prediction?.status ?? depthRead.status
                        s.nativePlanes = prediction?.planes ?? MonocularDepthProvider.planes(frame); s.nativePlaneFrameID = frame.id
                    }
                    s.analysisFPS = s.analysisFPS == 0 ? hz : s.analysisFPS*0.8+hz*0.2
                    // Log all results, but never publish stale, future, or out-of-order results.
                    if s.presentationGate.allowsGeometry(result,now:now),
                       result.frameID > (s.result?.frameID ?? 0) {
                        s.result = result; s.surfaceHistory.ingest(result); s.pathUpdate = pathUpdate
                    }
                }
                let s = store.read()
                let metrics = MetricContext(captureFPS:s.captureFPS,analysisFPS:s.analysisFPS,droppedFrames:mailbox.dropped,meshDrops:s.meshDrops,
                                            captureMS:frame.captureMilliseconds,meshMS:s.meshMS,render:RenderMetricRecord(s.renderMetrics),tracking:frame.tracking,
                                            thermal:s.thermal,sourceAgeMS:(now-frame.frame.timestamp)*1000,outputEligible:s.activeGuidanceResult(now:now)?.frameID == result.frameID,displayedFrameID:s.renderMetrics.renderedFrameID,
                                            geometryOutputEligible:s.activeGeometryResult(now:now)?.frameID == result.frameID)
                #if PRTS_DEV_CAPTURE
                if s.running,s.epoch == frame.epoch,s.parameterVersion == frame.parameterVersion {
                    devCapture.submit(frame:frame,result:result,path:pathUpdate,observation:observation,prediction:prediction,meshes:s.meshes,pathOptions:before.pathOptions)
                }
                #endif
                diagnostics.analysis(result,frame:frame,observation:observation,metrics:metrics)
                if s.recording,s.running,s.epoch == frame.epoch,s.parameterVersion == frame.parameterVersion { recorder.record(result,frame:frame,metrics:metrics) }
            }
        }
    }
    func session(_ session: ARSession,didAdd anchors: [ARAnchor]) { enqueueMeshes(anchors,removed:false) }
    func session(_ session: ARSession,didUpdate anchors: [ARAnchor]) { enqueueMeshes(anchors,removed:false) }
    func session(_ session: ARSession,didRemove anchors: [ARAnchor]) { enqueueMeshes(anchors,removed:true) }
    private func enqueueMeshes(_ anchors: [ARAnchor],removed: Bool) {
        let s = store.read(); guard s.running else { return }
        for case let anchor as ARMeshAnchor in anchors {
            let id = anchor.identifier.uuidString
            if removed { diagnostics.mesh(nil,id:id,epoch:epoch,revision:0,callbackTime:ProcessInfo.processInfo.systemUptime,action:"removed"); store.update { $0.meshes.removeValue(forKey:id); $0.result = nil } }
            let submission = meshInbox.submit(.init(anchor:removed ? nil : anchor,id:id,epoch:epoch,time:ProcessInfo.processInfo.systemUptime))
            if let evicted = submission.evicted {
                store.update { $0.meshes.removeValue(forKey:evicted); $0.result = nil; $0.surfaceHistory.reset(); $0.pathUpdate = .init(reason:"invalidated"); $0.meshDrops += 1 }
                recorder.event("mesh_update_dropped",details:evicted,epoch:epoch)
            }
            if submission.schedule { meshQueue.async { [self] in drainMeshes() } }
        }
    }
    private func drainMeshes() {
        while let job = meshInbox.next() {
            autoreleasepool {
                let s = store.read(); guard s.running,s.epoch == job.epoch else { return }
                let start = ProcessInfo.processInfo.systemUptime
                meshRevision &+= 1
                let copied = job.anchor.flatMap { MeshSnapshot.copy($0,epoch:job.epoch,revision:meshRevision,time:job.time) }
                diagnostics.mesh(copied,id:job.id,epoch:job.epoch,revision:meshRevision,callbackTime:job.time,action:job.anchor == nil ? "removed_applied" : (copied == nil ? "copy_failed" : "updated"))
                store.update { state in
                    guard state.running,state.epoch == job.epoch else { return }
                    state.meshes[job.id] = copied
                    // Bound world-background cache. Eviction removes evidence; never preserves stale certainty.
                    while state.meshes.count > 64 || state.meshes.values.reduce(0,{ $0+$1.byteCount }) > 32*1024*1024 {
                        guard let id = state.meshes.min(by:{ $0.value.callbackTime < $1.value.callbackTime })?.key else { break }
                        state.meshes.removeValue(forKey:id); state.meshDrops += 1; state.result = nil
                        diagnostics.event("mesh_cache_evicted",details:id,epoch:state.epoch)
                    }
                    state.meshMS = (ProcessInfo.processInfo.systemUptime-start)*1000
                }
            }
        }
    }
    func sessionWasInterrupted(_ session: ARSession) { stop(reason:"会话中断；旧证据已清空") }
    func sessionInterruptionEnded(_ session: ARSession) { diagnostics.event("session_interruption_ended",details:"restart_required",epoch:store.read().epoch); store.update { $0.status = "中断结束，请点击开始建立新会话" } }
    func session(_ session: ARSession,didFailWithError error: Error) { diagnostics.event("session_failure",details:"domain=\((error as NSError).domain),code=\((error as NSError).code): \(error.localizedDescription)",epoch:store.read().epoch); stop(reason:"ARSession 失败：\(error.localizedDescription)") }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
}
