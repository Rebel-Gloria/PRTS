import Foundation
import SpatialCore

/// Current committed goal only. A preview edit cannot re-arm or change turn speech.
struct ObstacleRouteAnnouncementPolicy {
    private var scenario: ObstacleRouteScenario?
    private var goalID: UInt64?
    private var turns = TurnAnnouncementPolicy()
    private var distance: Float?
    private var spokenAt: Double = -.infinity
    mutating func reset() { self = .init() }

    mutating func cue(update: PathUpdate, heading: PathHeading?, now: Double,
                      deviationDegrees: Float) -> ObstacleRouteSpeech? {
        guard let state = update.waypointGuidance else { return nil }
        let entered = scenario != state.scenario
        let changedGoal = goalID != update.goal?.id
        if changedGoal || entered { turns.reset() }
        scenario = state.scenario; goalID = update.goal?.id
        if state.scenario == .clear {
            distance = nil; turns.reset()
            guard entered else { return nil }
            spokenAt = now
            return .clear
        }
        let turn = state.scenario == .nearObstacle && update.path != nil
            ? turns.update(heading: heading, now: now, threshold: deviationDegrees, alignment: 5) : nil
        let newTurn = turn != nil
        let changedDistance = state.obstacleDistance.map { value in
            distance.map { abs(value-$0) >= 0.5 } ?? true
        } ?? false
        guard entered || (changedGoal && state.scenario == .nearObstacle) || newTurn
                || (changedDistance && now-spokenAt >= 3) else { return nil }
        spokenAt = now; distance = state.obstacleDistance
        if state.scenario == .blocked {
            return update.reason == "no_visible_target" ? .adjustCamera(state.obstacleDistance) : .blocked(state.obstacleDistance)
        }
        return .obstacle(state.obstacleDistance, turn)
    }
}

nonisolated enum ObstacleRouteSpeech: Equatable {
    case clear
    case obstacle(Float?, Int?)
    case blocked(Float?)
    case adjustCamera(Float?)
    var chinese: String {
        switch self {
        case .clear: return "前方无障碍"
        case .adjustCamera(let distance): return Self.distance(distance, chinese: true) + "，请调整手机方向"
        case .blocked(let distance): return Self.distance(distance, chinese: true) + "，暂无绕行路径"
        case .obstacle(let distance, let side):
            let suffix = side.map { $0 < 0 ? "，向左转" : $0 > 0 ? "，向右转" : "，继续向前" } ?? ""
            return Self.distance(distance, chinese: true) + suffix
        }
    }
    var english: String {
        switch self {
        case .clear: return "No obstacle ahead"
        case .adjustCamera(let distance): return Self.distance(distance, chinese: false) + ". Adjust the camera direction"
        case .blocked(let distance): return Self.distance(distance, chinese: false) + ". No bypass found"
        case .obstacle(let distance, let side):
            let suffix = side.map { $0 < 0 ? ". Turn left" : $0 > 0 ? ". Turn right" : ". Continue forward" } ?? ""
            return Self.distance(distance, chinese: false) + suffix
        }
    }
    private static func distance(_ value: Float?, chinese: Bool) -> String {
        guard let value else { return chinese ? "前方有障碍" : "Obstacle ahead" }
        return String(format: chinese ? "前方障碍，约 %.1f 米" : "Obstacle ahead, about %.1f meters", max(0,value))
    }
}
