import Foundation
import simd

/// Analysis-worker owned facade: session/order validation stays outside route strategy.
/// Spatial runtime and UI continue to use the same PathUpdate contract.
public struct PathPredictor: Sendable {
    private var planner = ForwardRoutePlanner()  // Explicit verified/legacy comparisons only.
    private var waypointPlanner = ObstacleWaypointPlanner()
    private var usesWaypoints = true
    private var verifiedPolicy = true
    private var evidenceMap = RouteEvidenceMap()
    private var continuityOptions = RouteContinuityOptions()
    private var geometryVersion: UInt64 = 0
    private var previousOutput: PredictedPath?
    private var previousPose: RigidPose?
    private var previousPoseTime: Double?
    private var lastFrame: UInt64 = 0
    private var lastTimestamp: Double = 0
    private var epoch: UInt64 = 0
    private var version: UInt64 = 0
    private var obstacleConfirmationSeconds: Double = 0.3
    private var experimentalOccupancyPlanning = false
    private var occupancyFilter = TemporalOccupancyGrid()
    public init(policy: RoutePlanningPolicy) {
        self.init(experimentalOccupancyPlanning: policy == .obstacleVeto)
    }
    public init(
        experimentalOccupancyPlanning: Bool = true,
        evidenceOptions: RouteEvidenceOptions = .init(),
        continuityOptions: RouteContinuityOptions = .init()
    ) {
        evidenceMap = RouteEvidenceMap(options: evidenceOptions)
        self.continuityOptions = continuityOptions
        self.experimentalOccupancyPlanning = experimentalOccupancyPlanning
        verifiedPolicy = !experimentalOccupancyPlanning
        planner.verifiedEvidence = verifiedPolicy
        if experimentalOccupancyPlanning {
            obstacleConfirmationSeconds = 0  // Input cells have already passed the 300ms filter.
            planner.obstacleConfirmationSeconds = 0
            planner.locksWorldGeometry = true
        }
    }
    /// Internal regression seam: retain build18 continuous geometry comparisons without
    /// exposing the retired product behaviour through settings or compile flags.
    init(legacyContinuousOccupancy: Bool) {
        self.init(experimentalOccupancyPlanning: true)
        usesWaypoints = !legacyContinuousOccupancy
    }
    // Test seam for geometry-only suites. Production always uses the default 300ms.
    init(obstacleConfirmationSeconds: Double) {
        verifiedPolicy = false
        self.obstacleConfirmationSeconds = obstacleConfirmationSeconds
        planner.obstacleConfirmationSeconds = obstacleConfirmationSeconds
    }
    public mutating func reset() {
        evidenceMap.reset()
        previousOutput = nil
        previousPose = nil
        previousPoseTime = nil
        waypointPlanner = .init()
        occupancyFilter.reset()
        planner = .init()
        planner.verifiedEvidence = verifiedPolicy
        planner.obstacleConfirmationSeconds = obstacleConfirmationSeconds
        planner.locksWorldGeometry = experimentalOccupancyPlanning
        lastFrame = 0
        lastTimestamp = 0
    }
    public mutating func update(
        result: AnalysisResult,
        observation: DepthObservation?,
        options: PathOptions,
        directionStable: Bool? = nil,
        cameraView: RouteCameraView? = nil,
        hazardWatermark: UInt64 = 0,
        committedPath: PredictedPath? = nil,
        onOccupancyConflict: ((UInt64) -> Void)? = nil
    ) -> PathUpdate {
        if epoch != result.epoch || version != result.parameterVersion {
            reset()
            epoch = result.epoch
            version = result.parameterVersion
        }
        guard options.enabled else {
            reset()
            return .init(reason: "disabled")
        }
        guard result.frameID > lastFrame else {
            return experimentalOccupancyPlanning && usesWaypoints
                ? waypointPlanner.held(reason: "out_of_order_ignored")
                : planner.held(
                    at: result.timestamp,
                    options: options.validated(),
                    reason: "out_of_order_ignored"
                )
        }
        guard result.timestamp.isFinite, result.timestamp >= lastTimestamp else {
            reset()
            return verifiedEmpty(
                result,
                options: options,
                watermark: hazardWatermark,
                reason: "ground_or_metric_conflict"
            )
        }
        lastFrame = result.frameID
        lastTimestamp = result.timestamp
        if !experimentalOccupancyPlanning,
            result.diagnostics?.groundReferenceInvalidation == "reference_expired_or_clock_reversed"
        {
            occupancyFilter.reset()
            planner.withdrawEvidence()
            evidenceMap.reset()
            return verifiedEmpty(
                result,
                options: options,
                watermark: hazardWatermark,
                reason: "ground_evidence_expired"
            )
        }
        if !experimentalOccupancyPlanning, result.diagnostics?.groundReferenceInvalidation != nil {
            reset()
            return verifiedEmpty(
                result,
                options: options,
                watermark: hazardWatermark,
                reason: "ground_or_metric_conflict"
            )
        }
        if verifiedPolicy {
            let start = ProcessInfo.processInfo.systemUptime
            guard evidenceMap.ingest(result) else {
                reset()
                return verifiedEmpty(
                    result,
                    options: options,
                    watermark: hazardWatermark,
                    reason: "ground_or_metric_conflict"
                )
            }
            var bodyOptions = options.validated()
            bodyOptions.minimumWidth = max(
                bodyOptions.minimumWidth,
                result.parameters.bodyWidth + 2 * result.parameters.sideMargin
            )
            let snapshot = evidenceMap.snapshot(result)
            var speed: Float = 0
            if let old = previousPose, let time = previousPoseTime, let pose = result.sourcePose,
                result.timestamp > time
            {
                speed = simd_distance(old.position, pose.position) / Float(result.timestamp - time)
            }
            let displacement =
                result.sourcePose.flatMap { pose in
                    previousPose.map { simd_distance(pose.position, $0.position) }
                } ?? 0
            previousPose = result.sourcePose
            previousPoseTime = result.timestamp
            planner.renewalDistance = continuityOptions.renewalDistance(speed: speed)
            if let old = planner.retainedPath {
                let remaining =
                    result.sourcePose.map {
                        RouteProgressWindow.remaining(
                            old.points,
                            plane: old.plane,
                            pose: $0,
                            maximumAdvance: max(0.5, displacement + 0.3)
                        )
                    } ?? old.points
                let prefix = evidenceMap.prefix(
                    remaining,
                    width: bodyOptions.minimumWidth,
                    at: result.timestamp
                )
                planner.replaceRetainedPrefix(prefix.points)
            }
            var update = planner.update(
                result: snapshot,
                observation: observation,
                options: bodyOptions,
                directionStable: directionStable,
                currentGrid: result.grid
            )
            if var path = update.path {
                let proof = evidenceMap.prefix(
                    path.points,
                    width: bodyOptions.minimumWidth,
                    at: result.timestamp
                )
                if proof.length >= 0.03 {
                    path.points = proof.points
                    path.planningPolicy = .verified
                    path.verifiedEvidence = true
                    path.worldLocked = false
                    path.evidenceIntervals = proof.evidence
                    update.path = path
                    planner.replaceRetainedPrefix(proof.points)
                } else {
                    update.path = nil
                    planner.replaceRetainedPrefix([])
                }
            }
            if update.path?.points != previousOutput?.points { geometryVersion &+= 1 }
            previousOutput = update.path
            let oldest = update.path?.evidenceIntervals?.map(\.observedAt).min()
            update.continuity = .init(
                epoch: result.epoch,
                parameterVersion: result.parameterVersion,
                frameID: result.frameID,
                timestamp: result.timestamp,
                requestID: result.frameID,
                sourceMapVersion: evidenceMap.version,
                hazardWatermark: hazardWatermark,
                routeID: update.path?.id,
                geometryVersion: geometryVersion,
                status: update.path == nil
                    ? (update.strategy?.mode == .blocked ? .hazardBlocked : .needsObservation)
                    : ((oldest.map { result.timestamp - $0 > 0.2 } ?? false)
                        ? .historical : .current),
                remainingVerifiedLength: update.path?.length ?? 0,
                evidenceAge: oldest.map { result.timestamp - $0 },
                renewalDistance: planner.renewalDistance,
                requiredWidth: bodyOptions.minimumWidth
            )
            update.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return update
        }
        if experimentalOccupancyPlanning {
            return occupancyUpdate(
                result: result,
                options: options,
                directionStable: directionStable,
                cameraView: cameraView
                    ?? observation.map { RouteCameraView(intrinsics: $0.intrinsics) },
                hazardWatermark: hazardWatermark,
                committedPath: committedPath,
                onConflict: onOccupancyConflict
            )
        }
        return planner.update(
            result: result,
            observation: observation,
            options: options.validated(),
            directionStable: directionStable
        )
    }
    /// Occupancy-only search uses a PRIVATE transformed grid. The measured result is never
    /// rewritten, and published length is not labeled as body-clear evidence.
    private mutating func occupancyUpdate(
        result: AnalysisResult,
        options: PathOptions,
        directionStable: Bool?,
        cameraView: RouteCameraView?,
        hazardWatermark: UInt64,
        committedPath: PredictedPath?,
        onConflict: ((UInt64) -> Void)?
    ) -> PathUpdate {
        let started = ProcessInfo.processInfo.systemUptime
        guard
            let planning = occupancyFilter.apply(
                result,
                forwardLength: options.validated().forwardBufferLength,
                routeForward: usesWaypoints
                    ? waypointPlanner.planningForward : planner.planningForward
            )
        else {
            let held =
                usesWaypoints
                ? waypointPlanner.held(reason: "occupancy_waiting_reference")
                : planner.held(
                    at: result.timestamp,
                    options: options.validated(),
                    reason: "occupancy_waiting_reference"
                )
            return occupancyContext(
                held,
                result: result,
                options: options,
                watermark: hazardWatermark,
                started: started
            )
        }
        var watermark = hazardWatermark
        if let active = committedPath
            ?? (usesWaypoints ? waypointPlanner.retainedPath : planner.retainedPath),
            active.epoch == result.epoch, active.parameterVersion == result.parameterVersion,
            RouteSafety.conflicts(active, result: planning, observation: nil)
        {
            watermark = max(watermark, result.frameID)
            // Preempt BEFORE search, even if the candidate is later rejected.
            onConflict?(watermark)
        }
        if usesWaypoints {
            let cameraResult = result.sourcePose.flatMap {
                occupancyFilter.projected(
                    result,
                    forwardLength: options.validated().forwardBufferLength,
                    forward: -$0.back
                )
            }
            var update = waypointPlanner.update(
                result: planning,
                cameraResult: cameraResult,
                options: options.validated(),
                view: cameraView
            )
            update.occupancyFilter = occupancyFilter.diagnostics
            update.confirmedObstacles = planning.planningObstacles
            return occupancyContext(
                update,
                result: result,
                options: options,
                watermark: watermark,
                started: started
            )
        }
        let displacement =
            result.sourcePose.flatMap { pose in
                previousPose.map { simd_distance(pose.position, $0.position) }
            } ?? 0
        if let old = planner.retainedPath, let pose = result.sourcePose {
            planner.replaceRetainedPrefix(
                RouteProgressWindow.remaining(
                    old.points,
                    plane: old.plane,
                    pose: pose,
                    maximumAdvance: max(0.5, displacement + 0.3)
                )
            )
        }
        let dt = previousPoseTime.map { result.timestamp - $0 } ?? 0
        planner.renewalDistance = continuityOptions.renewalDistance(
            speed: dt > 0 ? displacement / Float(dt) : 0
        )
        previousPose = result.sourcePose
        previousPoseTime = result.timestamp
        let turnPlanning = result.sourcePose.flatMap {
            occupancyFilter.projected(
                result,
                forwardLength: options.validated().forwardBufferLength,
                forward: -$0.back
            )
        }
        var update = planner.update(
            result: planning,
            observation: nil,
            options: options.validated(),
            directionStable: directionStable,
            turnResult: turnPlanning
        )
        update.occupancyFilter = occupancyFilter.diagnostics
        return occupancyContext(
            update,
            result: result,
            options: options,
            watermark: watermark,
            started: started
        )
    }
    private mutating func occupancyContext(
        _ value: PathUpdate,
        result: AnalysisResult,
        options: PathOptions,
        watermark: UInt64,
        started: Double
    ) -> PathUpdate {
        var update = value
        // The worker retains geometry, while the facade owns explicit publication semantics.
        if var path = update.path {
            path.planningPolicy = .obstacleVeto
            path.verifiedEvidence = false
            path.evidenceIntervals = nil
            update.path = RouteEvidencePresentation.validPrefix(path, now: result.timestamp)
        }
        if update.path?.points != previousOutput?.points { geometryVersion &+= 1 }
        previousOutput = update.path
        var context = RouteContext(
            epoch: result.epoch,
            parameterVersion: result.parameterVersion,
            frameID: result.frameID,
            timestamp: result.timestamp,
            requestID: result.frameID,
            sourceMapVersion: result.frameID,
            hazardWatermark: watermark,
            routeID: update.path?.id,
            geometryVersion: geometryVersion,
            status: update.path == nil
                ? (update.waypointGuidance?.scenario == .clear
                    ? .clear
                    : occupancyFilter.diagnostics.confirmedCells > 0
                        ? .hazardBlocked : .needsObservation) : .planned,
            remainingVerifiedLength: 0,
            evidenceAge: nil,
            renewalDistance: usesWaypoints
                ? options.waypoints.previewDistance : planner.renewalDistance,
            requiredWidth: options.validated().minimumWidth
        )
        if usesWaypoints { context.schemaVersion = 4 }
        context.planningPolicy = RoutePlanningPolicy.obstacleVeto.rawValue
        context.plannedLength = update.path?.length ?? 0
        update.continuity = context
        update.milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        return update
    }
    private func verifiedEmpty(
        _ result: AnalysisResult,
        options: PathOptions,
        watermark: UInt64,
        reason: String
    ) -> PathUpdate {
        var u = PathUpdate(reason: reason)
        u.continuity = .init(
            epoch: result.epoch,
            parameterVersion: result.parameterVersion,
            frameID: result.frameID,
            timestamp: result.timestamp,
            requestID: result.frameID,
            sourceMapVersion: evidenceMap.version,
            hazardWatermark: watermark,
            routeID: nil,
            geometryVersion: geometryVersion,
            status: .needsObservation,
            remainingVerifiedLength: 0,
            evidenceAge: nil,
            renewalDistance: continuityOptions.minimumRenewalDistance,
            requiredWidth: max(
                options.minimumWidth,
                result.parameters.bodyWidth + 2 * result.parameters.sideMargin
            )
        )
        u.goal =
            planner.held(at: result.timestamp, options: options.validated(), reason: reason).goal
        if experimentalOccupancyPlanning {
            u.continuity?.planningPolicy = RoutePlanningPolicy.obstacleVeto.rawValue
        }
        u.continuity?.plannedLength = 0
        return u
    }
}
