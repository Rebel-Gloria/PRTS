/// Owns the single ARSession, bounded frame mailbox, analysis worker, mesh cache and diagnostic journal.
/// This is the app's runtime implementation; the same-named type in Experiments/SpatialProbe/
/// is a frozen reference excluded from the app build.

import ARKit
import AVFoundation
import Foundation
import SpatialCore

private struct AnalysisJob: Sendable {
    let frame: FrameSnapshot
    let priors: [FloorPrior]
}
/// ARSession owns capture. Session state and DirectionGate belong to sessionQueue;
/// SpatialAnalyzer belongs to analysisQueue; meshes are copied on meshQueue. SharedStore is lock-protected.
final class ProbeEngine: NSObject, ARSessionDelegate, @unchecked Sendable {
    let store = SharedStore()
    let diagnostics = DiagnosticRecorder()
    #if PRTS_DEV_CAPTURE
    let devCapture: DevCaptureRecorder
    #endif
    let capabilities: DeviceCapabilities
    private let session: any ProbeSession
    private let sessionQueue: DispatchQueue
    private let analysisQueue = DispatchQueue(label: "probe.analysis", qos: .userInitiated)
    private let meshQueue = DispatchQueue(label: "probe.mesh", qos: .utility)
    private let mailbox = LatestMailbox<AnalysisJob>()
    private let meshInbox = MeshInbox()
    private let analyzer = SpatialAnalyzer()
    // Recording is orthogonal to planning: both builds use the same explicit product policy.
    // analysisQueue only
    private var pathPredictor = PathPredictor(policy: PRTSRuntimeProfile.routePlanningPolicy)
    private let monocularProvider = MonocularDepthProvider()
    private var directionGate = DirectionGate()
    private var epoch: UInt64 = 0
    private var frameID: UInt64 = 0
    private var meshRevision: UInt64 = 0  // meshQueue only
    private var lastSubmitted: Double = 0
    private var lastFrameTime: Double = 0
    private var lastAnalyzedCaptureTimestamp: Double?
    private var lastAnalyzedEpoch: UInt64 = 0
    private var lastAnalysisCompletion: Double = 0  // analysisQueue only
    private var analysisBarrier: UInt64 = 0  // analysisQueue only
    private var captureFPS: Double = 0
    init(
        session: any ProbeSession = ARSession(),
        capabilities: DeviceCapabilities = .detect(),
        sessionQueue: DispatchQueue = DispatchQueue(label: "probe.session", qos: .userInitiated)
    ) {
        self.session = session
        self.capabilities = capabilities
        self.sessionQueue = sessionQueue
        #if PRTS_DEV_CAPTURE
        devCapture = DevCaptureRecorder(root: diagnostics.journal.directory)
        #endif
        super.init()
        session.configure(delegate: self, queue: sessionQueue)
        let mono = DepthBackendPolicy(
            supportsSceneDepth: capabilities.depth,
            requestedSimulation: ProcessInfo.processInfo.arguments.contains("--simulate-no-lidar")
        ).usesMonocular
        store.update {
            $0.status = capabilities.description
            $0.usesMonocular = mono
        }
        diagnostics.event(
            "capabilities",
            details: capabilities.description + "; initialBackend="
                + (mono ? "apple_coreml_no_lidar" : "arkit_sceneDepth"),
            epoch: 0
        )
    }
    func start(device: [String: String], completion: @escaping @Sendable () -> Void = {}) {
        sessionQueue.async { [self] in
            defer { completion() }
            guard !store.read().running else { return }
            guard capabilities.world else {
                store.update { $0.status = "缺少世界追踪；模拟器仅验证界面，不能验收 LiDAR" }
                diagnostics.event(
                    "session_start_rejected",
                    details: capabilities.description,
                    epoch: epoch
                )
                return
            }
            epoch &+= 1
            frameID = 0
            lastSubmitted = 0
            lastFrameTime = 0
            captureFPS = 0
            directionGate.reset()
            mailbox.discardPending(resetDropCount: true)
            meshInbox.clear()
            let s = store.read()
            let config = ARWorldTrackingConfiguration()
            config.worldAlignment = .gravity
            if s.usesMonocular { config.planeDetection = [.horizontal, .vertical] }
            if !s.usesMonocular && capabilities.depth { config.frameSemantics.insert(.sceneDepth) }
            if !s.usesMonocular && s.options.smoothedDisplay && capabilities.smooth {
                config.frameSemantics.insert(.smoothedSceneDepth)
            }
            if !s.usesMonocular && capabilities.meshClassification {
                config.sceneReconstruction = .meshWithClassification
            }
            store.update {
                $0.minimumGeometryFrameID = 0
                $0.minimumGuidanceFrameID = 0
                $0.routeHazardWatermark = 0
                $0.epoch = epoch
                $0.running = true
                $0.geometryEnabled = false
                $0.frame = nil
                $0.frozen = nil
                $0.result = nil
                $0.surfaceHistory.reset()
                $0.pathUpdate = .init(reason: "invalidated")
                $0.diagnosticResult = nil
                $0.analyzedFrame = nil
                $0.meshes = [:]
                $0.monocular = nil
                $0.frozenMonocular = nil
                $0.nativePlanes = []
                $0.nativePlaneFrameID = 0
                $0.monocularStatus = "等待当前预测及尺度确认"
                $0.status = "会话启动中；" + capabilities.description
                $0.captureFPS = 0
                $0.analysisFPS = 0
                $0.droppedFrames = 0
                $0.meshDrops = 0
            }
            diagnostics.event(
                "session_configuration",
                details:
                    "backend=\(s.usesMonocular ? "monocular" : "lidar"),frameSemantics=\(config.frameSemantics.rawValue),sceneReconstruction=\(config.sceneReconstruction.rawValue),planeDetection=\(config.planeDetection.rawValue)",
                epoch: epoch
            )
            session.run(config)
            diagnostics.event(
                "session_started",
                details: capabilities.description + "; backend="
                    + (s.usesMonocular ? "apple_coreml_no_lidar" : "arkit_sceneDepth")
                    + "; nativePlaneClassification=\(ARPlaneAnchor.isClassificationSupported)",
                epoch: epoch
            )
        }
    }
    func stop(
        reason: String = "用户停止",
        completion: @escaping @Sendable () -> Void = {}
    ) {
        diagnostics.event("stop_requested", details: reason, epoch: store.read().epoch)
        sessionQueue.async { [self] in
            #if PRTS_DEV_CAPTURE
            devCapture.stop()
            #endif
            store.update {
                $0.running = false
                $0.geometryEnabled = false
                $0.frame = nil
                $0.frozen = nil
                $0.result = nil
                $0.surfaceHistory.reset()
                $0.pathUpdate = .init(reason: "invalidated")
                $0.diagnosticResult = nil
                $0.analyzedFrame = nil
                $0.meshes = [:]
                $0.monocular = nil
                $0.frozenMonocular = nil
                $0.nativePlanes = []
                $0.nativePlaneFrameID = 0
                $0.monocularStatus = "已停止；无当前预测或尺度"
                $0.status = reason
            }
            mailbox.discardPending()
            meshInbox.clear()
            session.pause()
            directionGate.reset()
            diagnostics.event("invalidated", details: reason, epoch: epoch)
            diagnostics.event(
                "session_stopped",
                details: "Channel evidence invalidated",
                epoch: epoch
            )
            completion()
        }
    }
    func flushDiagnostics(lifecycle: String, completion: @escaping @Sendable () -> Void) {
        diagnostics.journal.noteLifecycle(lifecycle)
        let finish: @Sendable () -> Void = {
            Task {
                // Disk errors are observable through the log's flush API; app suspension still ends.
                try? await ErrorLog.application.flush()
                completion()
            }
        }
        sessionQueue.async { [self] in
            analysisQueue.async { [self] in
                meshQueue.async { [self] in
                    #if PRTS_DEV_CAPTURE
                    devCapture.stop { [self] in diagnostics.journal.flush(completion: finish) }
                    #else
                    diagnostics.journal.flush(completion: finish)
                    #endif
                }
            }
        }
    }
    func updateParameters(_ parameters: ProbeParameters) {
        store.update {
            $0.parameters = parameters.validated()
            $0.parameterVersion &+= 1
            $0.result = nil
            $0.monocular = nil
            $0.frozenMonocular = nil
            $0.surfaceHistory.reset()
            $0.pathUpdate = .init(reason: "invalidated")
            $0.geometryEnabled = false
        }
        let s = store.read()
        diagnostics.event(
            "parameters_changed",
            details: String(
                data: (try? JSONEncoder().encode(s.parameters)) ?? Data(),
                encoding: .utf8
            ) ?? "",
            epoch: s.epoch
        )
    }
    func updateOptions(_ options: RenderOptions) {
        store.update { $0.options = options }
        diagnostics.event(
            "render_options",
            details: String(data: (try? DiagnosticJSON.encode(options)) ?? Data(), encoding: .utf8)
                ?? "encode_failed",
            epoch: store.read().epoch
        )
    }
    func setThermal(raw: Int, name: String) {
        store.update {
            $0.thermalRaw = raw
            $0.thermal = name
            if raw >= 3 {
                $0.result = nil
                $0.monocular = nil
                $0.surfaceHistory.reset()
                $0.pathUpdate = .init(reason: "invalidated")
                $0.geometryEnabled = false
                $0.minimumGeometryFrameID = ($0.frame?.id ?? 0) + 1
                $0.minimumGuidanceFrameID = $0.minimumGeometryFrameID
            }
        }
        let s = store.read()
        diagnostics.event("thermal_changed", details: name, epoch: s.epoch)
    }
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let received = ProcessInfo.processInfo.systemUptime
        let s = store.read()
        guard s.running else { return }
        let normal: Bool
        if case .normal = frame.camera.trackingState { normal = true } else { normal = false }
        let stable = directionGate.update(
            pose: RigidPose(frame.camera.transform),
            time: frame.timestamp,
            trackingNormal: normal,
            parameters: s.parameters
        )
        frameID &+= 1
        if lastFrameTime > 0, frame.timestamp > lastFrameTime {
            let instant = 1 / (frame.timestamp - lastFrameTime)
            captureFPS = captureFPS == 0 ? instant : captureFPS * 0.9 + instant * 0.1
        }
        lastFrameTime = frame.timestamp
        let snapshot = FrameSnapshot(
            frame: frame,
            epoch: epoch,
            id: frameID,
            receivedAt: received,
            directionStable: stable,
            parameters: s.parameters,
            parameterVersion: s.parameterVersion,
            directionDiagnostics: directionGate.diagnostics,
            usesMonocular: s.usesMonocular,
            orientation: s.orientation
        )
        diagnostics.capture(snapshot)
        if case .limited(.relocalizing) = frame.camera.trackingState {
            stop(reason: "重定位：旧证据已清空，请重新开始")
            return
        }
        store.update {
            guard $0.running, $0.epoch == epoch else { return }
            $0.frame = snapshot
            $0.captureFPS = captureFPS
            $0.geometryEnabled = normal && $0.thermalRaw < 3
            if !$0.geometryEnabled {
                $0.result = nil
                $0.monocular = nil
                $0.surfaceHistory.reset()
                $0.pathUpdate = .init(reason: "invalidated")
                $0.minimumGeometryFrameID = snapshot.id + 1
            }
            if !stable || !$0.geometryEnabled { $0.minimumGuidanceFrameID = snapshot.id + 1 }
            $0.status =
                s.usesMonocular
                ? "无LiDAR模式 · " + snapshot.tracking
                : frame.sceneDepth == nil
                    ? "sceneDepth 未提供；" + snapshot.tracking : snapshot.tracking
        }
        if s.geometryEnabled != (normal && s.thermalRaw < 3)
            || s.frame?.tracking != snapshot.tracking || s.frame?.directionStable != stable
        {
            diagnostics.event(
                "output_gate",
                details:
                    "tracking=\(snapshot.tracking),directionStable=\(stable),geometryEnabled=\(normal && s.thermalRaw < 3),guidanceEnabled=\(normal && stable && s.thermalRaw < 3),thermal=\(s.thermalRaw)",
                epoch: epoch
            )
        }
        guard s.thermalRaw < 3 else { return }
        let hz = s.thermalRaw >= 2 ? min(5, s.parameters.processingHz) : s.parameters.processingHz
        guard frame.timestamp - lastSubmitted >= 1 / hz else { return }
        lastSubmitted = frame.timestamp
        // Priors only; current depth must independently support the ground. Cache age isn't surface age.
        let priors = s.meshes.values.sorted { $0.id < $1.id }.flatMap(\.floorPriors)
        let job = AnalysisJob(frame: snapshot, priors: priors)
        if mailbox.submit(job) { analysisQueue.async { [self] in drainAnalysis() } }
        store.update { $0.droppedFrames = mailbox.dropped }
    }
    private func drainAnalysis() {
        while let job = mailbox.next() {
            autoreleasepool {
                let frame = job.frame
                let before = store.read()
                guard before.running, before.epoch == frame.epoch,
                    before.parameterVersion == frame.parameterVersion
                else { return }
                // A tracking interruption can be shorter than the analysis interval. Observe the
                // capture-side barrier so skipped limited frames cannot leave an old reference alive.
                if analysisBarrier != before.minimumGeometryFrameID {
                    analyzer.reset()
                    pathPredictor.reset()
                    monocularProvider.reset()
                    analysisBarrier = before.minimumGeometryFrameID
                }
                guard frame.id >= before.minimumGeometryFrameID || !frame.trackingNormal else {
                    return
                }
                var result: AnalysisResult
                let copyStart = ProcessInfo.processInfo.systemUptime
                var prediction: MonocularFrame?
                var depthRead: FrameSnapshot.DepthRead
                if frame.usesMonocular {
                    do {
                        prediction = try monocularProvider.predict(frame)
                        depthRead = .init(
                            observation: prediction?.observation,
                            status: prediction?.calibration == nil
                                ? "relative_depth_scale_unconfirmed"
                                : "predicted_depth_arkit_aligned",
                            confidenceStatus: "not_provided_by_model"
                        )
                        if let prediction { diagnostics.monocular(prediction) }
                    } catch {
                        ErrorLog.application.record(error, source: .camera)
                        monocularProvider.reset()
                        depthRead = .init(
                            status: "coreml_error: \(error.localizedDescription)",
                            confidenceStatus: "not_provided_by_model"
                        )
                        diagnostics.event(
                            "coreml_error",
                            details: error.localizedDescription,
                            epoch: frame.epoch
                        )
                    }
                } else {
                    depthRead = frame.readDepth()
                }
                let observation = depthRead.observation
                let copyMS = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000
                if let observation, frame.trackingNormal {
                    if frame.usesMonocular {
                        result = PredictedGeometry.analyze(
                            observation,
                            ground: prediction?.ground,
                            parameters: frame.parameters,
                            parameterVersion: frame.parameterVersion,
                            groundReference: prediction?.groundReference
                        )
                    } else {
                        result = analyzer.analyze(
                            observation,
                            priors: job.priors,
                            parameters: frame.parameters,
                            parameterVersion: frame.parameterVersion,
                            directionStable: frame.directionStable
                        )
                    }
                } else {
                    if frame.trackingNormal {
                        analyzer.missingDepth(
                            pose: frame.pose,
                            time: frame.frame.timestamp,
                            frameID: frame.id,
                            epoch: frame.epoch,
                            parameterVersion: frame.parameterVersion
                        )
                    } else {
                        analyzer.reset()
                    }
                    result = AnalysisResult(
                        epoch: frame.epoch,
                        frameID: frame.id,
                        timestamp: frame.frame.timestamp,
                        parameters: frame.parameters,
                        parameterVersion: frame.parameterVersion,
                        status: frame.trackingNormal
                            ? (frame.usesMonocular ? "当前米制预测不可用；相对输出不代表尺度已确认" : "未知：sceneDepth 不可用")
                            : "未知：追踪受限"
                    )
                }
                if frame.usesMonocular {
                    result.source = "apple_coreml_relative_depth_arkit_alignment"
                    if observation == nil { result.status = prediction?.status ?? depthRead.status }
                    result.stageMilliseconds["modelPipeline"] = prediction?.milliseconds ?? copyMS
                    if let prediction {
                        result.stageMilliseconds.merge(prediction.timings, uniquingKeysWith: { $1 })
                    }
                }
                if result.diagnostics == nil {
                    result.diagnostics = AnalysisDiagnostics()
                    result.diagnostics?.modelState = "blocked"
                    result.diagnostics?.modelBlockReasons = [
                        frame.trackingNormal ? depthRead.status : "tracking_not_normal"
                    ]
                }
                if let prediction {
                    result.diagnostics?.groundReferenceMode =
                        prediction.groundReference.mode == "retained_reference"
                        ? "retained_native_reference" : "native_\(prediction.groundReference.mode)"
                    result.diagnostics?.groundReferenceAge = prediction.groundReference.age
                    if prediction.scaleDecision.invalidatesHistory {
                        result.diagnostics?.groundReferenceInvalidation =
                            "metric_world_reference_conflict"
                    }
                    if ["native_ground_conflict", "new_plane_conflict_reconfirming"].contains(
                        prediction.groundReference.reason
                    ) {
                        result.diagnostics?.groundReferenceInvalidation =
                            prediction.groundReference.reason
                    }
                }
                result.diagnostics?.depthReadStatus = depthRead.status
                result.diagnostics?.confidenceReadStatus = depthRead.confidenceStatus
                if result.diagnostics?.depth == nil, let observation {
                    result.diagnostics?.depth = DepthStatistics(
                        observation,
                        parameters: frame.parameters
                    )
                }
                result.stageMilliseconds[frame.usesMonocular ? "modelWorker" : "depthCopy"] = copyMS
                result.sourcePose = frame.pose
                // Fast hazard publication precedes search and is not conditional on replacement
                // freshness. Work is bounded on the serial worker; no second planner queue.
                let hazardSnapshot = store.read()
                if PRTSRuntimeProfile.routePlanningPolicy == .verified,
                    let active = hazardSnapshot.pathUpdate.path,
                    active.epoch == frame.epoch, active.parameterVersion == frame.parameterVersion,
                    let invalidation = RouteSafety.invalidationReason(
                        active,
                        result: result,
                        observation: observation,
                        includeCurrentObstacles: PRTSRuntimeProfile.routePlanningPolicy == .verified
                    )
                {
                    store.update { s in
                        guard s.epoch == frame.epoch, s.parameterVersion == frame.parameterVersion,
                            frame.id >= s.minimumGeometryFrameID,
                            s.pathUpdate.path?.id == active.id
                        else { return }
                        s.routeHazardWatermark = max(s.routeHazardWatermark, frame.id)
                        s.pathUpdate = .init(reason: invalidation)
                        s.routePublicationReason = "\(invalidation)_preempted_before_search"
                    }
                    diagnostics.event(
                        "route_hazard",
                        details:
                            "frame=\(frame.id) route=\(active.id) reason=\(invalidation) source=\(frame.frame.timestamp)",
                        epoch: frame.epoch
                    )
                }
                let pathUpdate = pathPredictor.update(
                    result: result,
                    observation: observation,
                    options: before.pathOptions,
                    directionStable: frame.directionStable,
                    cameraView: RouteCameraView(intrinsics: frame.intrinsics),
                    hazardWatermark: store.read().routeHazardWatermark,
                    committedPath: store.read().pathUpdate.path,
                    onOccupancyConflict: { [self] watermark in
                        store.update { s in
                            guard s.running, s.epoch == frame.epoch,
                                s.parameterVersion == frame.parameterVersion,
                                frame.id >= s.minimumGeometryFrameID
                            else { return }
                            s.routeHazardWatermark = max(s.routeHazardWatermark, watermark)
                            s.pathUpdate = .init(reason: "confirmed_occupancy_conflict")
                            s.routePublicationReason = "confirmed_occupancy_preempted_before_search"
                        }
                        diagnostics.event(
                            "route_hazard",
                            details: "confirmed_occupancy frame=\(frame.id)",
                            epoch: frame.epoch
                        )
                    }
                )
                result.stageMilliseconds["pathPrediction"] = pathUpdate.milliseconds
                diagnostics.path(pathUpdate, frame: frame, options: before.pathOptions)
                let now = ProcessInfo.processInfo.systemUptime
                let hz =
                    lastAnalysisCompletion > 0 ? 1 / max(0.001, now - lastAnalysisCompletion) : 0
                lastAnalysisCompletion = now
                store.update { s in
                    guard s.running, s.epoch == frame.epoch,
                        s.parameterVersion == frame.parameterVersion
                    else { return }
                    let decision = RoutePublicationPolicy.decide(
                        current: s.pathUpdate,
                        candidate: pathUpdate,
                        gate: s.presentationGate,
                        hazardWatermark: s.routeHazardWatermark,
                        now: now,
                        expectedPolicy: PRTSRuntimeProfile.routePlanningPolicy
                    )
                    s.pathUpdate = decision.update
                    s.routePublicationReason = decision.reason
                    s.routePublishTime = now
                    s.diagnosticResult = result
                    s.analyzedFrame = frame
                    if frame.usesMonocular, frame.id >= s.minimumGeometryFrameID {
                        s.monocular = prediction
                        s.monocularStatus = prediction?.status ?? depthRead.status
                        s.nativePlanes = prediction?.planes ?? MonocularDepthProvider.planes(frame)
                        s.nativePlaneFrameID = frame.id
                    }
                    s.analysisFPS = s.analysisFPS == 0 ? hz : s.analysisFPS * 0.8 + hz * 0.2
                    // Log all results, but never publish stale, future, or out-of-order results.
                    if s.presentationGate.allowsGeometry(result, now: now),
                        result.frameID > (s.result?.frameID ?? 0)
                    {
                        s.result = result
                        s.surfaceHistory.ingest(result)
                    }
                }
                let s = store.read()
                #if PRTS_DEV_CAPTURE
                let captureEnabled = devCapture.status().enabled
                #else
                let captureEnabled = false
                #endif
                if lastAnalyzedEpoch != frame.epoch {
                    lastAnalyzedCaptureTimestamp = nil
                    lastAnalyzedEpoch = frame.epoch
                }
                diagnostics.routePublication(
                    candidate: pathUpdate,
                    state: s,
                    now: now,
                    captureEnabled: captureEnabled,
                    analysisStart: copyStart,
                    analysisEnd: now,
                    previousCaptureTimestamp: lastAnalyzedCaptureTimestamp
                )
                lastAnalyzedCaptureTimestamp = frame.frame.timestamp
                let metrics = MetricContext(
                    captureFPS: s.captureFPS,
                    analysisFPS: s.analysisFPS,
                    droppedFrames: mailbox.dropped,
                    meshDrops: s.meshDrops,
                    captureMS: frame.captureMilliseconds,
                    meshMS: s.meshMS,
                    render: RenderMetricRecord(s.renderMetrics),
                    tracking: frame.tracking,
                    thermal: s.thermal,
                    sourceAgeMS: (now - frame.frame.timestamp) * 1000,
                    outputEligible: s.activeGuidanceResult(now: now)?.frameID == result.frameID,
                    displayedFrameID: s.renderMetrics.renderedFrameID,
                    geometryOutputEligible: s.activeGeometryResult(now: now)?.frameID
                        == result.frameID
                )
                #if PRTS_DEV_CAPTURE
                if s.running, s.epoch == frame.epoch, s.parameterVersion == frame.parameterVersion {
                    devCapture.submit(
                        frame: frame,
                        result: result,
                        path: pathUpdate,
                        observation: observation,
                        prediction: prediction,
                        meshes: s.meshes,
                        pathOptions: before.pathOptions
                    )
                }
                #endif
                diagnostics.analysis(
                    result,
                    frame: frame,
                    observation: observation,
                    metrics: metrics
                )
            }
        }
    }
    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        enqueueMeshes(anchors, removed: false)
    }
    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        enqueueMeshes(anchors, removed: false)
    }
    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        enqueueMeshes(anchors, removed: true)
    }
    private func enqueueMeshes(_ anchors: [ARAnchor], removed: Bool) {
        let s = store.read()
        guard s.running else { return }
        for case let anchor as ARMeshAnchor in anchors {
            let id = anchor.identifier.uuidString
            if removed {
                diagnostics.mesh(
                    nil,
                    id: id,
                    epoch: epoch,
                    revision: 0,
                    callbackTime: ProcessInfo.processInfo.systemUptime,
                    action: "removed"
                )
                store.update {
                    $0.meshes.removeValue(forKey: id)
                    $0.result = nil
                }
            }
            let submission = meshInbox.submit(
                .init(
                    anchor: removed ? nil : anchor,
                    id: id,
                    epoch: epoch,
                    time: ProcessInfo.processInfo.systemUptime
                )
            )
            if let evicted = submission.evicted {
                store.update {
                    $0.meshes.removeValue(forKey: evicted)
                    $0.result = nil
                    $0.surfaceHistory.reset()
                    if PRTSRuntimeProfile.routePlanningPolicy == .verified {
                        $0.pathUpdate = .init(reason: "invalidated")
                    }
                    $0.meshDrops += 1
                }
                diagnostics.event("mesh_update_dropped", details: evicted, epoch: epoch)
            }
            if submission.schedule { meshQueue.async { [self] in drainMeshes() } }
        }
    }
    private func drainMeshes() {
        while let job = meshInbox.next() {
            autoreleasepool {
                let s = store.read()
                guard s.running, s.epoch == job.epoch else { return }
                let start = ProcessInfo.processInfo.systemUptime
                meshRevision &+= 1
                let copied = job.anchor.flatMap {
                    MeshSnapshot.copy($0, epoch: job.epoch, revision: meshRevision, time: job.time)
                }
                diagnostics.mesh(
                    copied,
                    id: job.id,
                    epoch: job.epoch,
                    revision: meshRevision,
                    callbackTime: job.time,
                    action: job.anchor == nil
                        ? "removed_applied" : (copied == nil ? "copy_failed" : "updated")
                )
                store.update { state in
                    guard state.running, state.epoch == job.epoch else { return }
                    state.meshes[job.id] = copied
                    // Bound world-background cache. Eviction removes evidence; never preserves stale certainty.
                    while state.meshes.count > 64
                        || state.meshes.values.reduce(0, { $0 + $1.byteCount }) > 32 * 1024 * 1024
                    {
                        guard
                            let id = state.meshes.min(by: {
                                $0.value.callbackTime < $1.value.callbackTime
                            })?.key
                        else { break }
                        state.meshes.removeValue(forKey: id)
                        state.meshDrops += 1
                        state.result = nil
                        diagnostics.event("mesh_cache_evicted", details: id, epoch: state.epoch)
                    }
                    state.meshMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
                }
            }
        }
    }
    func sessionWasInterrupted(_ session: ARSession) { stop(reason: "会话中断；旧证据已清空") }
    func sessionInterruptionEnded(_ session: ARSession) {
        diagnostics.event(
            "session_interruption_ended",
            details: "restart_required",
            epoch: store.read().epoch
        )
        store.update { $0.status = "中断结束，请点击开始建立新会话" }
    }
    func session(_ session: ARSession, didFailWithError error: Error) {
        ErrorLog.application.record(error, source: .camera)
        diagnostics.event(
            "session_failure",
            details:
                "domain=\((error as NSError).domain),code=\((error as NSError).code): \(error.localizedDescription)",
            epoch: store.read().epoch
        )
        stop(reason: "ARSession 失败：\(error.localizedDescription)")
    }
    func sessionShouldAttemptRelocalization(_ session: ARSession) -> Bool { false }
}
