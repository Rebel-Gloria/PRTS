import Foundation
import SpatialCore

/// Rate-limit semantic instructions, not frame/goal IDs. A tiny replan to the same side
/// neither interrupts nor re-arms speech. Suppressed turns are evaluated again from the
/// LIVE current heading; no queue can replay a preview/obsolete target instruction.
struct ObstacleRouteAnnouncementPolicy {
    private var observedScenario: ObstacleRouteScenario?
    private var lastClearObservation: Double?
    private var scenarioSince: Double = 0
    private var spokenScenario: ObstacleRouteScenario?
    private var turns = TurnAnnouncementPolicy()
    private var spokenNear: Bool?
    private var spokenAt: Double = -.infinity
    private var spokenTurn: Int?
    private var lastFullFieldObservation: Double?
    var lastCueWasFullField: Bool { lastFullFieldObservation != nil }
    static let firstClearDelay: Double = 0.5
    static let minimumInterval: Double = 2.5
    mutating func reset() { self = .init() }

    /// One immediate warning per encounter. Repeated polls and brief measurement holes
    /// don't repeat it; a subsequently spoken route or a genuine gap can re-arm it.
    mutating func fullFieldCue(measuredAt time: Double) -> ObstacleRouteSpeech? {
        if let lastFullFieldObservation, time - lastFullFieldObservation < Self.minimumInterval {
            self.lastFullFieldObservation = max(time, lastFullFieldObservation)
            return nil
        }
        reset()
        lastFullFieldObservation = time
        return .close
    }

    /// A gap invalidates the pending confirmation, not an already spoken instruction.
    mutating func pauseObservations() {
        observedScenario = nil
        lastClearObservation = nil
    }

    private func takesPriority(_ scenario: ObstacleRouteScenario) -> Bool {
        guard let spokenScenario, scenario != spokenScenario else { return false }
        return spokenScenario == .clear || scenario == .blocked
            || (spokenScenario == .distantObstacle && scenario == .nearObstacle)
    }

    /// A confirmed escalation supersedes even a clear utterance with no spoken turn.
    mutating func interruptIfObsolete(
        update: PathUpdate,
        heading: PathHeading?,
        threshold: Float,
        newObservation: Bool = true
    )
        -> Bool
    {
        if newObservation, let scenario = update.waypointGuidance?.scenario, takesPriority(scenario)
        {
            return true
        }
        guard let side = spokenTurn else { return false }
        let opposite = heading.map { $0.angleDegrees * Float(side) < -threshold } ?? false
        guard update.path == nil || update.waypointGuidance?.scenario != .nearObstacle || opposite
        else { return false }
        spokenTurn = nil
        return true
    }

    mutating func cue(
        update: PathUpdate,
        heading: PathHeading?,
        now: Double,
        deviationDegrees: Float,
        alignmentDegrees: Float = 5,
        maxResultAge: Double = ProbeParameters().maxResultAge,
        canSpeak: Bool = true
    ) -> ObstacleRouteSpeech? {
        guard let state = update.waypointGuidance else {
            pauseObservations()
            return nil
        }
        // A retained clear still prevents a loss alert, but cannot start a new
        // announcement. Count measurement time, not polls of the same observation.
        let observationTime: Double
        if state.scenario == .clear {
            guard let timestamp = update.continuity?.timestamp, timestamp <= now,
                now - timestamp <= maxResultAge
            else {
                pauseObservations()
                return nil
            }
            if let lastClearObservation,
                timestamp < lastClearObservation || timestamp - lastClearObservation > maxResultAge
            {
                pauseObservations()
            }
            observationTime = timestamp
            lastClearObservation = timestamp
        } else {
            observationTime = now
            lastClearObservation = nil
        }
        if observedScenario == nil {
            // Break any unfinished alignment timer across a pause, without re-arming
            // a direction that the user already heard.
            _ = turns.update(
                heading: nil,
                now: now,
                threshold: deviationDegrees,
                alignment: alignmentDegrees
            )
        }
        if observedScenario != state.scenario {
            observedScenario = state.scenario
            scenarioSince = observationTime
        }
        let first = spokenScenario == nil
        let entered = spokenScenario != state.scenario
        let priority = takesPriority(state.scenario)
        // Pending occupancy can look clear on the first frame. Only clear needs this
        // startup wait: the planner has already confirmed a published obstacle.
        let settledFor = observationTime - scenarioSince + 0.000001
        if first && state.scenario == .clear && settledFor < Self.firstClearDelay { return nil }
        guard first || priority || !entered || settledFor >= 0.6 else { return nil }
        var proposedTurns = turns
        let turn =
            state.scenario == .nearObstacle && update.path != nil
            ? proposedTurns.update(
                heading: heading,
                now: now,
                threshold: deviationDegrees,
                alignment: alignmentDegrees
            ) : nil
        // Measured distance is noisy, so speech only says "obstacle" or "obstacle close";
        // re-announce when that level changes, at most every 4 s as build 25 did.
        let near = state.obstacleDistance.map(ObstacleRouteSpeech.isNear)
        let distanceDue =
            state.scenario != .clear && near != nil && near != spokenNear && now - spokenAt >= 4
        // Keep alignment/re-arm observations while muted, but don't consume an unsaid turn.
        if turn == nil { turns = proposedTurns }
        guard canSpeak, first || priority || now - spokenAt + 0.000001 >= Self.minimumInterval,
            first || entered || turn != nil || distanceDue
        else { return nil }
        turns = proposedTurns
        spokenAt = now
        spokenNear = near
        spokenScenario = state.scenario
        spokenTurn = turn
        lastFullFieldObservation = nil
        switch state.scenario {
        case .clear:
            turns.reset()
            return .clear
        case .blocked:
            return update.reason == "no_visible_target"
                ? .adjustCamera(state.obstacleDistance) : .blocked(state.obstacleDistance)
        case .nearObstacle, .distantObstacle: return .obstacle(state.obstacleDistance, turn)
        }
    }
}

nonisolated enum ObstacleRouteSpeech: Equatable {
    case clear
    case close
    case obstacle(Float?, Int?)
    case blocked(Float?)
    case adjustCamera(Float?)
    /// Below this the obstacle is "close"; no metre value is ever spoken.
    static let nearMeters: Float = 1
    static func isNear(_ distance: Float) -> Bool { distance < nearMeters }

    var chinese: String {
        switch self {
        case .clear: return "前方畅通"
        case .close: return "障碍很近"
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
        case .close: return "Obstacle close"
        case .adjustCamera(let distance):
            return Self.level(distance, chinese: false) + ", turn the phone"
        case .blocked(let distance): return Self.level(distance, chinese: false) + ", no way around"
        case .obstacle(let distance, let side):
            let suffix =
                side.map { $0 < 0 ? ", go left" : $0 > 0 ? ", go right" : ", go straight" } ?? ""
            return Self.level(distance, chinese: false) + suffix
        }
    }
    static func level(_ distance: Float?, chinese: Bool) -> String {
        if distance.map(isNear) == true { return chinese ? Self.close.chinese : Self.close.english }
        return chinese ? "有障碍" : "Obstacle"
    }
}
