import ARKit
import Foundation
import SpatialCore
import simd

/// Cross-queue state snapshot whose fields may come from different processing stages.
/// Validate results through activeGeometryResult(now:), activeGuidanceResult(now:),
/// activeSurfacePresentation(now:), activeRouteProjection(now:), activePath(now:),
/// activeWaypointUpdate(now:) or pathHeading(now:) as appropriate; monocular results use
/// activeMonocular and retainedNativeGround(now:).
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
    var routeHazardWatermark: UInt64 = 0
    var routePublicationReason = "not_running"
    var routePublishTime: Double?
    var diagnosticResult: AnalysisResult?
    var analyzedFrame: FrameSnapshot?
    var meshes: [String: MeshSnapshot] = [:]
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
    var activeMonocular: MonocularFrame? {
        let prediction = frozen != nil ? frozenMonocular : monocular
        guard usesMonocular, running, let prediction, prediction.frame.epoch == epoch,
            prediction.frame.parameterVersion == parameterVersion
        else { return nil }
        if frozen == nil
            && ProcessInfo.processInfo.systemUptime - prediction.frame.frame.timestamp
                > parameters.maxResultAge
        {
            return nil
        }
        return prediction
    }
    /// Only a bounded historical OUTLINE can survive a brief missing native plane snapshot.
    func retainedNativeGround(now: Double) -> NativePlaneObservation? {
        guard running, geometryEnabled, frozen == nil, let prediction = activeMonocular,
            prediction.frame.id >= minimumGeometryFrameID,
            prediction.groundReference.mode == "retained_reference",
            let plane = prediction.groundReference.plane,
            prediction.groundReference.age + max(0, now - prediction.frame.frame.timestamp) <= 2
        else { return nil }
        return plane
    }
    var displayedFrame: FrameSnapshot? {
        if let frozen { return frozen }
        if usesMonocular && (options.layer != .rgb || options.overlayDepth) {
            return activeMonocular?.frame ?? frame
        }
        return frame
    }
    var presentationGate: ResultPresentationGate {
        var gate = ResultPresentationGate()
        guard let frame else { return gate }
        gate.enabled =
            running && geometryEnabled && frozen == nil && thermalRaw < 3 && frame.epoch == epoch
            && frame.parameterVersion == parameterVersion
        gate.trackingNormal = frame.trackingNormal
        gate.directionStable = frame.directionStable
        gate.epoch = epoch
        gate.parameterVersion = parameterVersion
        gate.frameID = frame.id
        gate.frameTimestamp = frame.frame.timestamp
        gate.maxAge = parameters.maxResultAge
        gate.minimumGeometryFrameID = minimumGeometryFrameID
        gate.minimumGuidanceFrameID = minimumGuidanceFrameID
        return gate
    }
    func activeGeometryResult(now: Double) -> AnalysisResult? {
        guard let result, presentationGate.allowsGeometry(result, now: now) else { return nil }
        return result
    }
    func activeSurfacePresentation(now: Double) -> SurfacePresentation? {
        surfaceHistory.presentation(
            current: activeGeometryResult(now: now),
            gate: presentationGate,
            pose: frame?.pose,
            now: now
        )
    }
    func activeRouteProjection(now: Double) -> RouteProjection? {
        guard pathOptions.enabled, let projection = pathUpdate.projection,
            projection.visible(gate: presentationGate, now: now)
        else { return nil }
        return projection
    }
    func activePath(now: Double) -> PathPresentation? {
        guard pathOptions.enabled, let path = pathUpdate.path, let frame else { return nil }
        return PathPresentation.make(
            path: path,
            gate: presentationGate,
            pose: frame.pose,
            options: pathOptions,
            now: now
        )
    }
    /// Open-space guidance has no path by design; it must not depend on the ground-render result.
    func activeWaypointUpdate(now: Double) -> PathUpdate? {
        let gate = presentationGate
        guard pathOptions.enabled, pathUpdate.waypointGuidance != nil,
            let context = pathUpdate.continuity,
            gate.enabled, gate.trackingNormal, context.epoch == gate.epoch,
            context.parameterVersion == gate.parameterVersion,
            context.frameID >= gate.minimumGeometryFrameID,
            context.frameID <= gate.frameID, context.hazardWatermark >= routeHazardWatermark,
            now >= gate.frameTimestamp, now - gate.frameTimestamp <= gate.maxAge
        else { return nil }
        return pathUpdate
    }
    func pathHeading(now: Double) -> PathHeading? {
        // Angle feedback follows the LIVE tracked pose during a normal turn. The fixed goal
        // is not reselected here; fresh tracking/epoch/TTL and near-vertical checks still apply.
        guard let path = activePath(now: now), let pose = frame?.pose else { return nil }
        guard presentationGate.directionStable else { return nil }
        let heading = PathTracking.heading(
            path: path.path,
            pose: pose,
            lookAhead: pathOptions.lookAhead
        )
        if path.path.verifiedEvidence == true,
            (heading?.startDistance ?? .infinity) > 0.25 || (heading?.remainingLength ?? 0) < 0.25
        {
            return nil
        }
        return heading
    }
    func activeGuidanceResult(now: Double) -> AnalysisResult? {
        guard let result, presentationGate.allowsGuidance(result, now: now) else { return nil }
        return result
    }
}
