import Foundation

/// Hysteresis for product presentation, not obstacle admission. New near obstacles still
/// activate immediately after the model confirms them; every retained route is collision
/// checked on every update while a clear/far transition is settling.
struct WaypointScenarioLatch: Sendable {
    private(set) var state: ObstacleRouteScenario = .clear
    private var lastObstacle: ForwardObstacle?
    private var pending: ObstacleRouteScenario?
    private var since: Double = 0
    var isPending: Bool { pending != nil }
    private var last: Double?
    mutating func update(_ obstacle: ForwardObstacle?, now: Double, nearDistance: Float)
        -> (ObstacleRouteScenario, ForwardObstacle?) {
        let requested: ObstacleRouteScenario = obstacle.map {
            $0.distance <= nearDistance || (state == .nearObstacle && $0.distance <= nearDistance+0.15)
                ? .nearObstacle : .distantObstacle
        } ?? .clear
        let discontinuous = last.map { now <= $0 || now-$0 > 0.75 } ?? false
        last = now
        if let obstacle { lastObstacle = obstacle }
        if requested == state { pending = nil }
        else if state == .clear || requested == .nearObstacle {
            state = requested; pending = nil
        } else {
            if pending != requested || discontinuous { pending = requested; since = now }
            if now-since+0.000001 >= (requested == .clear ? 0.6 : 0.75) {
                state = requested; pending = nil
            }
        }
        if state == .clear { lastObstacle = nil }
        return (state, obstacle ?? lastObstacle)
    }
}

/// Tiny excursions across the image edge should not repeatedly mint new goals. Large
/// exits/behind-camera targets remain immediate; stationary heading override is separate.
struct WaypointVisibilityLatch: Sendable {
    private var since: Double?
    mutating func exited(target: V3?, view: RouteCameraView?, pose: RigidPose, now: Double) -> Bool {
        guard let target, let view else { since = nil; return false }
        if view.contains(target,pose:pose,margin:0.04) { since = nil; return false }
        if !view.contains(target,pose:pose,margin:0.25) { since = nil; return true }
        if since == nil { since = now }
        return now-since!+0.000001 >= 0.35
    }
}
