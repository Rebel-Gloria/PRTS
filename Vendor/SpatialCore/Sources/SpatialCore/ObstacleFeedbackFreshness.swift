import Foundation

/// Source time of a completed obstacle classification, never the latest camera/UI tick.
public struct ObstacleCheckStamp: Codable, Sendable {
    public var epoch: UInt64
    public var parameterVersion: UInt64
    public var frameID: UInt64
    public var timestamp: Double

    static func successful(_ result: AnalysisResult) -> Self? {
        guard result.plane != nil, let grid = result.grid, result.sourcePose != nil,
              (result.diagnostics?.sampledPoints ?? 0) > 0,
              grid.epoch == result.epoch, grid.frameID == result.frameID,
              grid.timestamp == result.timestamp else { return nil }
        return .init(epoch:result.epoch,parameterVersion:result.parameterVersion,
                     frameID:result.frameID,timestamp:result.timestamp)
    }
}

/// Unknown withdraws clearance and direction authority without inventing an obstacle.
public enum ObstacleFeedbackState: String, Sendable { case current, unknown }
public enum ObstacleFeedbackFreshness {
    public static let maximumAge: Double = 0.25
    public static func state(_ update: PathUpdate, gate: ResultPresentationGate,
                             hazardWatermark: UInt64, now: Double) -> ObstacleFeedbackState {
        allows(update,gate:gate,hazardWatermark:hazardWatermark,now:now) ? .current : .unknown
    }
    public static func allows(_ update: PathUpdate, gate: ResultPresentationGate,
                              hazardWatermark: UInt64, now: Double) -> Bool {
        guard gate.enabled, gate.trackingNormal, let context = update.continuity,
              let check = update.successfulObstacleCheck,
              context.epoch == gate.epoch, context.parameterVersion == gate.parameterVersion,
              context.frameID >= gate.minimumGeometryFrameID, context.frameID <= gate.frameID,
              context.hazardWatermark >= hazardWatermark,
              check.epoch == gate.epoch, check.parameterVersion == gate.parameterVersion,
              check.frameID >= max(gate.minimumGeometryFrameID,gate.minimumGuidanceFrameID),
              check.frameID <= context.frameID,
              now >= gate.frameTimestamp, now-gate.frameTimestamp <= gate.maxAge,
              check.timestamp <= gate.frameTimestamp, now >= check.timestamp,
              now-check.timestamp <= maximumAge else { return false }
        return true
    }
}
