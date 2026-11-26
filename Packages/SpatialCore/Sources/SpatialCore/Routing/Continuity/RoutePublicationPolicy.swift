import Foundation
import simd

public enum RoutePublicationPolicy {
    /// Normal late/old candidates never clear an existing valid prefix. Hazards are applied
    /// independently before planning; their watermark rejects pre-hazard candidates.
    public static func decide(
        current: PathUpdate,
        candidate: PathUpdate,
        gate: ResultPresentationGate,
        hazardWatermark: UInt64,
        now: Double,
        expectedPolicy: RoutePlanningPolicy? = nil
    ) -> RoutePublicationDecision {
        guard gate.enabled, gate.trackingNormal else {
            return .init(
                update: .init(reason: "tracking_invalid"),
                accepted: false,
                reason: "tracking_invalid"
            )
        }
        func reject(_ why: String) -> RoutePublicationDecision {
            var kept = current
            if let path = kept.path {
                kept.path =
                    path.epoch == gate.epoch && path.parameterVersion == gate.parameterVersion
                        && path.sourceFrameID >= gate.minimumGeometryFrameID
                        && (expectedPolicy == nil
                            || kept.continuity?.planningPolicy == expectedPolicy?.rawValue)
                        && (kept.continuity?.hazardWatermark ?? 0) >= hazardWatermark
                    ? RouteEvidencePresentation.validPrefix(path, now: now) : nil
            }
            if current.path != nil && kept.path == nil {
                kept.goal = nil
                kept.waypointGuidance = nil
            }
            return .init(update: updatedContext(kept, now: now), accepted: false, reason: why)
        }
        guard let c = candidate.continuity else { return reject("missing_route_context") }
        guard expectedPolicy == nil || c.planningPolicy == expectedPolicy?.rawValue else {
            return reject("planning_policy_mismatch")
        }
        guard c.epoch == gate.epoch else { return reject("epoch_mismatch") }
        guard c.parameterVersion == gate.parameterVersion else {
            return reject("parameter_mismatch")
        }
        guard c.frameID >= gate.minimumGeometryFrameID else { return reject("before_barrier") }
        guard c.frameID >= (current.continuity?.frameID ?? 0) else { return reject("out_of_order") }
        guard c.hazardWatermark >= hazardWatermark else { return reject("hazard_watermark") }
        guard now.isFinite, now >= c.timestamp,
            c.planningPolicy == RoutePlanningPolicy.obstacleVeto.rawValue
                || now - c.timestamp <= gate.maxAge,
            c.frameID <= gate.frameID
        else { return reject("candidate_expired_or_future") }
        // A serial publisher may receive the veto here without the worker's fast callback.
        // An unfinished replacement without a new hazard still leaves the current route alone.
        let vetoesCurrent =
            c.status == .hazardBlocked
            && c.hazardWatermark > (current.continuity?.hazardWatermark ?? 0)
        if c.planningPolicy == RoutePlanningPolicy.obstacleVeto.rawValue,
            candidate.path == nil, current.path != nil, !vetoesCurrent,
            candidate.waypointGuidance?.scenario != .clear,
            candidate.waypointGuidance?.scenario != .blocked,
            candidate.goalChangeReason != "current_target_reached",
            candidate.reason != "disabled", candidate.reason != "ground_or_metric_conflict"
        {
            return reject("candidate_not_ready")
        }
        var accepted = candidate
        if let path = candidate.path {
            accepted.path = RouteEvidencePresentation.validPrefix(path, now: now)
        }
        return .init(
            update: updatedContext(accepted, now: now),
            accepted: true,
            reason: accepted.path == nil ? candidate.reason : "atomic_route_commit"
        )
    }
}
private func updatedContext(_ update: PathUpdate, now: Double) -> PathUpdate {
    var copy = update
    copy.continuity?.routeID = copy.path?.id
    copy.continuity?.plannedLength = copy.path?.length ?? 0
    copy.continuity?.remainingVerifiedLength =
        copy.path?.verifiedEvidence == true ? (copy.path?.length ?? 0) : 0
    let noPathStatus: RouteStatus =
        copy.waypointGuidance?.scenario == .clear
        ? .clear : copy.continuity?.status == .hazardBlocked ? .hazardBlocked : .needsObservation
    copy.continuity?.status =
        copy.path == nil
        ? noPathStatus
        : (copy.path?.planningPolicy == .obstacleVeto
            ? .planned
            : ((copy.path?.evidenceIntervals?.contains { now - $0.observedAt > 0.2 } ?? false)
                ? .historical : .current))
    copy.continuity?.evidenceAge = copy.path?.evidenceIntervals?.map { now - $0.observedAt }.max()
    return copy
}
