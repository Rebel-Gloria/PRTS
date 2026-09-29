import Foundation
import simd

/// Planning semantics are explicit and independent of recording/compilation flags.
public enum RoutePlanningPolicy: String, Codable, Sendable {
  case verified = "verified_continuous_v1"
  case obstacleVeto = "obstacle_veto_v1"
}

public enum RouteStatus: String, Codable, Sendable {
  case current, historical, needsObservation, hazardBlocked, trackingInvalid, planned
}
public struct RouteContinuityOptions: Codable, Sendable {
  public var minimumRenewalDistance: Float = 1.5
  public var pipelineBudget: Double = 0.25  // Initial budget, NOT a measured P95.
  public var reserveTime: Double = 0.8
  public var distanceMargin: Float = 0.3
  public init() {}
  public func renewalDistance(speed: Float) -> Float {
    max(
      minimumRenewalDistance,
      max(0, min(3, speed)) * Float(pipelineBudget + reserveTime) + distanceMargin)
  }
}
public struct RouteContext: Codable, Sendable {
  public var schemaVersion = 3
  public var planningPolicy = "verified_continuous_v1"
  public var epoch: UInt64
  public var parameterVersion: UInt64
  public var frameID: UInt64
  public var timestamp: Double
  public var requestID: UInt64
  public var sourceMapVersion: UInt64
  public var hazardWatermark: UInt64
  public var routeID: UInt64?
  public var geometryVersion: UInt64
  public var status: RouteStatus
  public var plannedLength: Float? = nil
  public var remainingVerifiedLength: Float
  public var evidenceAge: Double?
  public var renewalDistance: Float
  public var pipelineBudgetSource = "initial_configuration"
  public var requiredWidth: Float
}
public struct RoutePublicationDecision: Sendable {
  public var update: PathUpdate
  public var accepted: Bool
  public var reason: String
}
public enum RoutePublicationPolicy {
  /// Normal late/old candidates never clear an existing valid prefix. Hazards are applied
  /// independently before planning; their watermark rejects pre-hazard candidates.
  public static func decide(
    current: PathUpdate, candidate: PathUpdate,
    gate: ResultPresentationGate, hazardWatermark: UInt64,
    now: Double, expectedPolicy: RoutePlanningPolicy? = nil
  ) -> RoutePublicationDecision {
    guard gate.enabled, gate.trackingNormal else {
      return .init(
        update: .init(reason: "tracking_invalid"), accepted: false, reason: "tracking_invalid")
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
      return .init(update: updatedContext(kept, now: now), accepted: false, reason: why)
    }
    guard let c = candidate.continuity else { return reject("missing_route_context") }
    guard expectedPolicy == nil || c.planningPolicy == expectedPolicy?.rawValue else {
      return reject("planning_policy_mismatch")
    }
    guard c.epoch == gate.epoch else { return reject("epoch_mismatch") }
    guard c.parameterVersion == gate.parameterVersion else { return reject("parameter_mismatch") }
    guard c.frameID >= gate.minimumGeometryFrameID else { return reject("before_barrier") }
    guard c.frameID >= (current.continuity?.frameID ?? 0) else { return reject("out_of_order") }
    guard c.hazardWatermark >= hazardWatermark else { return reject("hazard_watermark") }
    guard now.isFinite, now >= c.timestamp,
      c.planningPolicy == RoutePlanningPolicy.obstacleVeto.rawValue
        || now - c.timestamp <= gate.maxAge,
      c.frameID <= gate.frameID
    else { return reject("candidate_expired_or_future") }
    // A normal replacement is a transaction, not an instruction to clear the route.
    // Confirmed occupancy has already raised the watermark before search. Explicit
    // lifecycle/coordinate resets remain separate from an unfinished candidate.
    if c.planningPolicy == RoutePlanningPolicy.obstacleVeto.rawValue,
      candidate.path == nil, current.path != nil,
      candidate.reason != "disabled", candidate.reason != "ground_or_metric_conflict"
    {
      return reject("candidate_not_ready")
    }
    var accepted = candidate
    if let path = candidate.path {
      accepted.path = RouteEvidencePresentation.validPrefix(path, now: now)
    }
    return .init(
      update: updatedContext(accepted, now: now), accepted: true,
      reason: accepted.path == nil ? candidate.reason : "atomic_route_commit")
  }
}
private func updatedContext(_ update: PathUpdate, now: Double) -> PathUpdate {
  var copy = update
  copy.continuity?.routeID = copy.path?.id
  copy.continuity?.plannedLength = copy.path?.length ?? 0
  copy.continuity?.remainingVerifiedLength =
    copy.path?.verifiedEvidence == true ? (copy.path?.length ?? 0) : 0
  let noPathStatus: RouteStatus =
    copy.continuity?.status == .hazardBlocked ? .hazardBlocked : .needsObservation
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

public enum RouteEvidencePresentation {
  /// Evidence expiration cuts only the affected suffix. Publication never renews proof time.
  public static func validPrefix(_ path: PredictedPath, now: Double) -> PredictedPath? {
    if path.planningPolicy == .obstacleVeto { return path }
    guard path.verifiedEvidence == true else { return path }
    guard let evidence = path.evidenceIntervals, now.isFinite else { return nil }
    var end: Float = 0
    for sample in evidence {
      guard sample.observedAt <= now, now <= sample.validUntil else { break }
      end = sample.endS
    }
    guard end > 0.03 else { return nil }
    var copy = path
    copy.points = RouteArc.prefix(path.points, length: end)
    copy.evidenceIntervals = evidence.filter { $0.endS <= end }
    return copy.points.count >= 2 ? copy : nil
  }
}
public enum RouteArc {
  public static func length(_ points: [V3]) -> Float {
    zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
  }
  public static func prefix(_ points: [V3], length: Float) -> [V3] {
    guard let first = points.first else { return [] }
    var output = [first]
    var left = length
    for (a, b) in zip(points, points.dropFirst()) {
      let d = simd_distance(a, b)
      if left >= d {
        output.append(b)
        left -= d
      } else {
        if left > 0.001 { output.append(a + (b - a) * (left / max(d, 0.000001))) }
        break
      }
    }
    return output
  }
}

/// Fast rejection reuses confidence/cluster checks. It is independent of the slow side latch.
public enum RouteSafety {
  public static func invalidationReason(
    _ path: PredictedPath, result: AnalysisResult, observation: DepthObservation?,
    includeCurrentObstacles: Bool = true
  ) -> String? {
    if let reason = result.diagnostics?.groundReferenceInvalidation { return reason }
    if let plane = result.plane, let pose = result.sourcePose,
      ["current_confirmed", "native_confirmed"].contains(
        result.diagnostics?.groundReferenceMode ?? ""),
      abs(plane.height(path.plane.project(pose.position))) > 0.12
        || simd_dot(plane.normal, path.plane.normal) < 0.97
    {
      return "ground_reference_conflict"
    }
    return includeCurrentObstacles && conflicts(path, result: result, observation: observation)
      ? "current_hazard" : nil
  }

  public static func conflicts(
    _ path: PredictedPath, result: AnalysisResult, observation: DepthObservation?
  ) -> Bool {
    PathObstacleCheck.intersects(
      path, result: result, observation: observation, includeApproach: false)
  }
}

/// Arc-window matching on the currently committed prefix. It cannot jump to a geometrically
/// close return leg far along the polyline. Keep 20cm behind the match for bounded reverse motion.
public enum RouteProgressWindow {
  public static func remaining(
    _ points: [V3], plane: GroundPlane, pose: RigidPose,
    maximumAdvance: Float
  ) -> [V3] {
    guard points.count >= 2 else { return points }
    let p = plane.project(pose.position)
    var arc: Float = 0
    var best = Float.infinity
    var matched: Float = 0
    for (a, b) in zip(points, points.dropFirst()) {
      let length = simd_distance(a, b)
      guard length > 0.00001 else { continue }
      if arc > maximumAdvance { break }
      let limit = min(1, max(0, (maximumAdvance - arc) / length))
      let t = min(limit, max(0, simd_dot(p - a, b - a) / (length * length)))
      let d = simd_distance(p, a + (b - a) * t)
      if d < best {
        best = d
        matched = arc + t * length
      }
      arc += length
    }
    var discard = max(0, matched - 0.2)
    for (index, pair) in zip(points, points.dropFirst()).enumerated() {
      let length = simd_distance(pair.0, pair.1)
      if discard < length {
        return [pair.0 + (pair.1 - pair.0) * (discard / max(0.00001, length))]
          + Array(points.dropFirst(index + 1))
      }
      discard -= length
    }
    return []
  }
}
