import Foundation
import simd

public struct PredictedPath: Codable, Sendable {
    public var id: UInt64
    public var epoch: UInt64
    public var parameterVersion: UInt64
    public var sourceFrameID: UInt64
    public var validatedFrameID: UInt64
    public var observedAt: Double
    public var plane: GroundPlane
    public var points: [V3]
    public var source: String
    public var requiredWidth: Float
    public var planningPolicy: RoutePlanningPolicy? = nil
    public var verifiedEvidence: Bool? = nil
    public var evidenceIntervals: [RouteSegmentEvidence]? = nil
    public var worldLocked: Bool? = nil
    public var forwardStrategy: Bool? = nil  // New routes retain world intent across camera turns.
    public var footAtPlan: V3? = nil
    public var targetRange: Float? = nil
    public var length: Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }
}
/// Goal identity/world position are independent of route evidence freshness.
/// Retaining this intent does NOT authorize rendering an expired route or haptic guidance.
public struct FixedPathGoal: Codable, Sendable {
    public var id: UInt64
    public var epoch: UInt64
    public var point: V3
    public var plane: GroundPlane
    public var selectedAt: Double
    public var maxDistance: Float
}
public struct PathUpdate: Codable, Sendable {
    public var waypointGuidance: ObstacleWaypointGuidance? = nil
    public var continuity: RouteContext? = nil
    public var projection: RouteProjection? = nil
    /// Same-frame confirmed geometry used for planning, retained in Dev samples for replay.
    public var confirmedObstacles: [OccupancyFootprint]? = nil
    public var occupancyFilter: OccupancyFilterDiagnostics? = nil
    public var path: PredictedPath?
    public var reason: String
    public var blueCells: Int
    public var eligibleCells: Int
    public var milliseconds: Double
    public var strategy: ForwardStrategyDiagnostics? = nil
    public var goal: FixedPathGoal? = nil
    public var goalChangeReason: String? = nil
    public var reachableCells: Int? = nil
    public var targetBearingDegrees: Float? = nil
    public var targetGroundDistance: Float? = nil
    public var approachDistance: Float? = nil
    public init(
        path: PredictedPath? = nil,
        reason: String = "waiting_blue_ground",
        blueCells: Int = 0,
        eligibleCells: Int = 0,
        milliseconds: Double = 0
    ) {
        self.path = path
        self.reason = reason
        self.blueCells = blueCells
        self.eligibleCells = eligibleCells
        self.milliseconds = milliseconds
    }
}
