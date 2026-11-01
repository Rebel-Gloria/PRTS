import Foundation
import simd

/// Experimental geometric line, NOT a free-space/safe-route certificate. Never promotes LocalGrid cells.
public struct PathOptions: Codable, Sendable, Equatable {
    public var waypoints = ObstacleWaypointOptions()
    public var enabled = true
    public var haptics = true
    public var deviationDegrees: Float = 12
    public var retentionSeconds: Double = 2
    public var lookAhead: Float = 0.8
    public var forwardBufferLength: Float = 8
    // TOTAL planning envelope; do not add bodyWidth/margin twice.
    public var minimumWidth: Float = 0.5
    public var targetHalfAngleDegrees: Float = 45
    public var arrivalRadius: Float = 0.35
    public var alignmentDegrees: Float = 5
    public var obstacleTriggerDistance: Float = 1
    // Full width at the far edge; apex at the foot projection.
    public var obstacleTriggerWidth: Float = 0.5
    public var smallObstacleWidth: Float = 0.5
    public var userTurnDegrees: Float = 45
    public var userTurnSeconds: Double = 3
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case waypoints, forwardBufferLength, enabled, haptics, deviationDegrees, retentionSeconds,
            lookAhead, minimumWidth, targetHalfAngleDegrees, arrivalRadius, alignmentDegrees,
            obstacleTriggerDistance, obstacleTriggerWidth, smallObstacleWidth, userTurnDegrees,
            userTurnSeconds
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waypoints =
            try c.decodeIfPresent(ObstacleWaypointOptions.self, forKey: .waypoints) ?? .init()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? true
        deviationDegrees = try c.decodeIfPresent(Float.self, forKey: .deviationDegrees) ?? 12
        retentionSeconds = try c.decodeIfPresent(Double.self, forKey: .retentionSeconds) ?? 2
        lookAhead = try c.decodeIfPresent(Float.self, forKey: .lookAhead) ?? 0.8
        forwardBufferLength = try c.decodeIfPresent(Float.self, forKey: .forwardBufferLength) ?? 8
        minimumWidth = try c.decodeIfPresent(Float.self, forKey: .minimumWidth) ?? 0.5
        targetHalfAngleDegrees =
            try c.decodeIfPresent(Float.self, forKey: .targetHalfAngleDegrees) ?? 45
        arrivalRadius = try c.decodeIfPresent(Float.self, forKey: .arrivalRadius) ?? 0.35
        alignmentDegrees = try c.decodeIfPresent(Float.self, forKey: .alignmentDegrees) ?? 5
        obstacleTriggerDistance =
            try c.decodeIfPresent(Float.self, forKey: .obstacleTriggerDistance) ?? 1
        obstacleTriggerWidth =
            try c.decodeIfPresent(Float.self, forKey: .obstacleTriggerWidth) ?? 0.5
        smallObstacleWidth = try c.decodeIfPresent(Float.self, forKey: .smallObstacleWidth) ?? 0.5
        userTurnDegrees = try c.decodeIfPresent(Float.self, forKey: .userTurnDegrees) ?? 45
        userTurnSeconds = try c.decodeIfPresent(Double.self, forKey: .userTurnSeconds) ?? 3
    }
    public func validated() -> Self {
        var v = self
        v.waypoints = waypoints.validated()
        v.deviationDegrees = deviationDegrees.isFinite ? min(30, max(6, deviationDegrees)) : 12
        v.retentionSeconds = retentionSeconds.isFinite ? min(5, max(0.5, retentionSeconds)) : 2
        v.lookAhead = lookAhead.isFinite ? min(1.5, max(0.4, lookAhead)) : 0.8
        v.forwardBufferLength =
            forwardBufferLength.isFinite ? min(20, max(2, forwardBufferLength)) : 8
        v.minimumWidth = minimumWidth.isFinite ? min(1.2, max(0.5, minimumWidth)) : 0.5
        v.targetHalfAngleDegrees =
            targetHalfAngleDegrees.isFinite ? min(75, max(15, targetHalfAngleDegrees)) : 45
        v.arrivalRadius = arrivalRadius.isFinite ? min(0.75, max(0.2, arrivalRadius)) : 0.35
        v.alignmentDegrees =
            alignmentDegrees.isFinite
            ? min(v.deviationDegrees - 2, max(2, alignmentDegrees)) : min(5, v.deviationDegrees - 2)
        v.obstacleTriggerDistance =
            obstacleTriggerDistance.isFinite ? min(2, max(0.5, obstacleTriggerDistance)) : 1
        v.obstacleTriggerWidth =
            obstacleTriggerWidth.isFinite ? min(1, max(0.3, obstacleTriggerWidth)) : 0.5
        v.smallObstacleWidth =
            smallObstacleWidth.isFinite ? min(1, max(0.2, smallObstacleWidth)) : 0.5
        v.userTurnDegrees = userTurnDegrees.isFinite ? min(90, max(30, userTurnDegrees)) : 45
        v.userTurnSeconds = userTurnSeconds.isFinite ? min(6, max(3, userTurnSeconds)) : 3
        return v
    }
}
