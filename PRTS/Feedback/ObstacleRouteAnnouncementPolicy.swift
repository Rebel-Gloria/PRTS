import Foundation
import SpatialCore

/// Rate-limit semantic instructions, not frame/goal IDs. A tiny replan to the same side
/// neither interrupts nor re-arms speech. Suppressed turns are evaluated again from the
/// LIVE current heading; no queue can replay a preview/obsolete target instruction.
struct ObstacleRouteAnnouncementPolicy {
    private var observedScenario: ObstacleRouteScenario?
    private var scenarioSince: Double = 0
    private var spokenScenario: ObstacleRouteScenario?
    private var turns = TurnAnnouncementPolicy()
    private var spokenNear: Bool?
    private var spokenAt: Double = -.infinity
    private var spokenTurn: Int?
    static let minimumInterval: Double = 2.5
    mutating func reset() { self = .init() }

    /// Cancel only a semantically obsolete turn, not every geometry revision. Cancellation
    /// does not clear the cooldown, so rapid state changes cannot repeatedly restart audio.
    mutating func interruptIfObsolete(update: PathUpdate, heading: PathHeading?, threshold: Float) -> Bool {
        guard let side = spokenTurn else { return false }
        let opposite = heading.map { $0.angleDegrees * Float(side) < -threshold } ?? false
        guard update.path == nil || update.waypointGuidance?.scenario != .nearObstacle || opposite else { return false }
        spokenTurn = nil
        return true
    }

    mutating func cue(update: PathUpdate, heading: PathHeading?, now: Double,
                      deviationDegrees: Float, canSpeak: Bool = true) -> ObstacleRouteSpeech? {
        guard let state = update.waypointGuidance else { return nil }
        if observedScenario != state.scenario { observedScenario = state.scenario; scenarioSince = now }
        let first = spokenScenario == nil
        let entered = spokenScenario != state.scenario
        // Initial cue is immediate. Subsequent transient clear/blocked/stage changes settle
        // for 0.6s; all subsequent speech has a minimum spacing, including goal handoffs.
        guard first || !entered || now-scenarioSince+0.000001 >= 0.6 else { return nil }
        var proposedTurns = turns
        let turn = state.scenario == .nearObstacle && update.path != nil
            ? proposedTurns.update(heading:heading,now:now,threshold:deviationDegrees,alignment:5) : nil
        // Measured distance is noisy, so speech only says "obstacle" or "obstacle close";
        // re-announce when that level changes, at most every 4 s as build 25 did.
        let near = state.obstacleDistance.map(ObstacleRouteSpeech.isNear)
        let distanceDue = state.scenario != .clear && near != nil && near != spokenNear && now-spokenAt >= 4
        // Keep alignment/re-arm observations while muted, but don't consume an unsaid turn.
        if turn == nil { turns = proposedTurns }
        guard canSpeak, first || now-spokenAt+0.000001 >= Self.minimumInterval,
              first || entered || turn != nil || distanceDue else { return nil }
        turns = proposedTurns
        spokenAt = now; spokenNear = near; spokenScenario = state.scenario
        spokenTurn = turn
        switch state.scenario {
        case .clear: turns.reset(); return .clear
        case .blocked:
            return update.reason == "no_visible_target" ? .adjustCamera(state.obstacleDistance) : .blocked(state.obstacleDistance)
        case .nearObstacle, .distantObstacle: return .obstacle(state.obstacleDistance,turn)
        }
    }
}

nonisolated enum ObstacleRouteSpeech: Equatable {
    case clear
    case obstacle(Float?, Int?)
    case blocked(Float?)
    case adjustCamera(Float?)
    /// Below this the obstacle is "close"; no metre value is ever spoken.
    static let nearMeters: Float = 1
    static func isNear(_ distance: Float) -> Bool { distance < nearMeters }

    var chinese: String {
        switch self {
        case .clear: return "前方畅通"
        case .adjustCamera(let distance): return Self.level(distance, chinese: true) + "，转动手机"
        case .blocked(let distance): return Self.level(distance, chinese: true) + "，无法绕行"
        case .obstacle(let distance, let side):
            let suffix = side.map { $0 < 0 ? "，向左" : $0 > 0 ? "，向右" : "，直走" } ?? ""
            return Self.level(distance, chinese: true) + suffix
        }
    }
    var english: String {
        switch self {
        case .clear: return "Clear ahead"
        case .adjustCamera(let distance): return Self.level(distance, chinese: false) + ", turn the phone"
        case .blocked(let distance): return Self.level(distance, chinese: false) + ", no way around"
        case .obstacle(let distance, let side):
            let suffix = side.map { $0 < 0 ? ", go left" : $0 > 0 ? ", go right" : ", go straight" } ?? ""
            return Self.level(distance, chinese: false) + suffix
        }
    }
    static func level(_ distance: Float?, chinese: Bool) -> String {
        let near = distance.map(isNear) ?? false
        return chinese ? (near ? "障碍很近" : "有障碍") : (near ? "Obstacle close" : "Obstacle")
    }
}
