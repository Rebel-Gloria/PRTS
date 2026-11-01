import Foundation
import simd

/// Planning semantics are explicit and independent of recording/compilation flags.
public enum RoutePlanningPolicy: String, Codable, Sendable {
    case verified = "verified_continuous_v1"
    case obstacleVeto = "obstacle_veto_v1"
}

public enum RouteStatus: String, Codable, Sendable {
    case current, historical, needsObservation, hazardBlocked, trackingInvalid, planned, clear
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
            max(0, min(3, speed)) * Float(pipelineBudget + reserveTime) + distanceMargin
        )
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
