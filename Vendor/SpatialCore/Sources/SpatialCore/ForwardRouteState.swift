import Foundation
import simd

/// Route intent is separate from evidence. Camera yaw does not rotate this world-space line.
public struct ForwardRouteReference: Codable, Sendable {
    public var origin: V3
    public var forward: V3
    public var plane: GroundPlane
    public var right: V3 { simd_normalize(simd_cross(forward, plane.normal)) }
    public func coordinates(_ p: V3) -> SIMD2<Float> {
        let d = p - origin
        return SIMD2(simd_dot(d, right), simd_dot(d, forward))
    }
    public func point(_ progress: Float) -> V3 { origin + forward * progress }
}

public enum ForwardRouteMode: String, Codable, Sendable, Hashable {
    case straight, detour, returning, sideRoute, blocked
}

/// Persisted in path.jsonl and Dev Capture, including decisions which produce no drawable line.
public struct ForwardStrategyDiagnostics: Codable, Sendable {
    public var mode: ForwardRouteMode = .straight
    public var reference: ForwardRouteReference?
    public var maneuverID: UInt64?
    public var side: Int = 0  // -1 left, +1 right; fixed for the whole manoeuvre.
    public var triggerDistance: Float?
    public var obstacleWidth: Float?
    public var obstacleExtentObserved: Bool?
    public var rejoinPoint: V3?
    public var turnDwell: Double = 0
    public var turnAngle: Float?
    public var turnCandidateLength: Float?
    public var turnReason: String?
    public var routePointCount: Int?
    public var obstacleAge: Double?
    public var obstacleConfirmed: Bool?
    public var obstacleVeto: String?
    public var invalidatesPreviousPath = false
    public init() {}
}

struct ForwardObstacle: Sendable {
    var width: Float
    var distance: Float
    var extentObserved: Bool
    var near: Float
    var far: Float
    var minLateral: Float
    var maxLateral: Float
}

/// Explicit user override; time must be continuously observed, not bridged across missing frames.
/// Compare against the upcoming route tangent, so following a detour is not mistaken for a new intent.
struct ForwardTurnDwell: Sendable {
    var since: Double?
    var last: Double?
    var heading: V3?
    var elapsed: Double = 0
    var angle: Float?
    mutating func reset() { self = .init() }
    mutating func update(forward: V3?, routeForward: V3, clear: Bool, now: Double, options: PathOptions) -> Bool {
        guard now.isFinite, clear, routeForward.x.isFinite, routeForward.y.isFinite, routeForward.z.isFinite,
            let forward, forward.x.isFinite, forward.y.isFinite, forward.z.isFinite
        else {
            reset()
            return false
        }
        let measuredAngle = acos(min(1, max(-1, simd_dot(forward, routeForward)))) * 180 / .pi
        angle = measuredAngle
        guard measuredAngle >= options.userTurnDegrees else {
            reset()
            return false
        }
        let discontinuous = last.map { now <= $0 || now - $0 > 0.75 } ?? true
        if discontinuous
            || heading.map({ simd_dot($0, forward) < cos(10 * Float.pi / 180) }) == true
        {
            since = now
            heading = forward
        }
        if since == nil {
            since = now
            heading = forward
        }
        last = now
        elapsed = now - (since ?? now)
        return elapsed >= options.userTurnSeconds
    }
}
