import Foundation
import simd

/// Product guidance is a sequence of local waypoints, not a destination navigation task.
public enum ObstacleRouteScenario: String, Codable, Sendable {
    case clear, distantObstacle, nearObstacle, blocked
}

public struct ObstacleWaypointOptions: Codable, Sendable, Equatable {
    public var nearDistance: Float = 2
    public var standOff: Float = 0.55
    public var previewDistance: Float = 1.2
    public var previewInterval: Double = 0.25
    public var stationaryRadius: Float = 0.12
    public init() {}
    public func validated() -> Self {
        var copy = self
        copy.nearDistance = nearDistance.isFinite ? min(4, max(1, nearDistance)) : 2
        copy.standOff = standOff.isFinite ? min(1.5, max(0.5, standOff)) : 0.55
        copy.previewDistance = previewDistance.isFinite ? min(3, max(0.5, previewDistance)) : 1.2
        copy.previewInterval = previewInterval.isFinite ? min(0.5, max(0.1, previewInterval)) : 0.25
        copy.stationaryRadius = stationaryRadius.isFinite ? min(0.3, max(0.05, stationaryRadius)) : 0.12
        return copy
    }
}

/// Diagnostic preview has no goal identity or feedback authority. It can change every update.
public struct ObstacleWaypointGuidance: Codable, Sendable {
    public var schemaVersion = 2
    public var scenario: ObstacleRouteScenario
    public var obstacleDistance: Float?
    public var nextTarget: V3?
    public var nextPreparedAt: Double?
    public var replanReason: String?
    public var targetInView: Bool?
    public var stationaryTurnSeconds: Double = 0
    public var referenceForward: V3
    public var goalSelectedReason: String? = nil
    public var transitionPending: Bool? = nil
}

/// RGB intrinsics use the unrotated full camera image. Aspect-fit screen rotation preserves
/// membership, so this test agrees with rendering in portrait and landscape without cropping.
public struct RouteCameraView: Codable, Sendable {
    public var intrinsics: CameraIntrinsics
    public init(intrinsics: CameraIntrinsics) { self.intrinsics = intrinsics }
    public func contains(_ world: V3, pose: RigidPose, margin: Float = 0) -> Bool {
        guard let pixel = intrinsics.project(pose.camera(world)) else { return false }
        return pixel.x.isFinite && pixel.y.isFinite && pixel.x >= -0.5-Float(intrinsics.width)*margin && pixel.y >= -0.5-Float(intrinsics.height)*margin
            && pixel.x < Float(intrinsics.width)*(1+margin)-0.5 && pixel.y < Float(intrinsics.height)*(1+margin)-0.5
    }
}

/// A stationary heading change is an explicit replan, not an inference from walking a bend.
struct StationaryRouteTurn: Sendable {
    private var anchor: V3?
    private var turn = ForwardTurnDwell()
    var elapsed: Double { turn.elapsed }
    mutating func reset() { self = .init() }
    mutating func update(foot: V3, forward: V3?, routeForward: V3, now: Double, options: PathOptions) -> Bool {
        if anchor == nil { anchor = foot }
        if simd_distance(foot, anchor!) > options.waypoints.stationaryRadius {
            anchor = foot
            turn.reset()
        }
        return turn.update(forward: forward, routeForward: routeForward, clear: true, now: now, options: options)
    }
}
