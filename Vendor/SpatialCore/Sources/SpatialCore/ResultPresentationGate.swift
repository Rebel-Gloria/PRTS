import Foundation

/// Shared by publication, rendering, UI and recording. Direction stability gates guidance only.
/// The app combines running/frozen/thermal availability into `enabled` and supplies the latest frame.
public struct ResultPresentationGate: Sendable {
    public var enabled = false
    public var trackingNormal = false
    public var directionStable = false
    public var epoch: UInt64 = 0
    public var parameterVersion: UInt64 = 0
    public var frameID: UInt64 = 0
    public var frameTimestamp: Double = 0
    public var maxAge: Double = 0.25
    // Barriers prevent a worker started before invalidation from restoring withdrawn output.
    public var minimumGeometryFrameID: UInt64 = 0
    public var minimumGuidanceFrameID: UInt64 = 0
    public init() {}

    public func geometryBlockReason(_ result: AnalysisResult, now: Double) -> String? {
        outputBlockReason(result,now:now,analysisMaxAge:maxAge)
    }
    public func historyBlockReason(_ result: AnalysisResult,now: Double) -> String? {
        outputBlockReason(result,now:now,analysisMaxAge:SurfaceHistory.maximumAge)
    }
    private func outputBlockReason(_ result: AnalysisResult,now: Double,analysisMaxAge: Double) -> String? {
        guard enabled else { return "lifecycle_or_thermal_disabled" }
        guard trackingNormal else { return "tracking_not_normal" }
        guard result.epoch == epoch else { return "epoch_mismatch" }
        guard result.parameterVersion == parameterVersion else { return "parameter_mismatch" }
        guard result.frameID >= minimumGeometryFrameID else { return "before_geometry_barrier" }
        guard result.frameID <= frameID else { return "future_frame_id" }
        guard now.isFinite,frameTimestamp.isFinite,result.timestamp.isFinite,maxAge.isFinite,maxAge > 0 else { return "invalid_clock" }
        guard now >= frameTimestamp else { return "future_display_frame" }
        guard now-frameTimestamp <= maxAge else { return "display_frame_expired" }
        guard result.timestamp <= frameTimestamp,now >= result.timestamp else { return "future_analysis_frame" }
        guard now-result.timestamp <= analysisMaxAge else { return "analysis_expired" }
        if result.diagnostics?.groundReferenceMode == "retained_world_reference",let reference = result.diagnostics?.groundReference,
           now-reference.observedAt > GroundReferenceTracker.maximumAge { return "ground_reference_expired" }
        if result.diagnostics?.groundReferenceMode == "retained_native_reference",
           (result.diagnostics?.groundReferenceAge ?? .infinity)+now-result.timestamp > 2 { return "native_ground_reference_expired" }
        return nil
    }
    public func guidanceBlockReason(_ result: AnalysisResult, now: Double) -> String? {
        if let reason = geometryBlockReason(result,now:now) { return reason }
        if ["retained_world_reference","retained_native_reference"].contains(result.diagnostics?.groundReferenceMode ?? "") { return "retained_ground_is_not_current_clearance" }
        guard directionStable else { return "current_direction_unstable" }
        guard result.sourceDirectionStable == true else { return "source_direction_unstable_or_unknown" }
        guard result.frameID >= minimumGuidanceFrameID else { return "before_guidance_barrier" }
        return nil
    }
    public func allowsGeometry(_ result: AnalysisResult, now: Double) -> Bool { geometryBlockReason(result,now:now) == nil }
    public func allowsGuidance(_ result: AnalysisResult, now: Double) -> Bool { guidanceBlockReason(result,now:now) == nil }
}
