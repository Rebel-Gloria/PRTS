import SpatialCore

/// Pure presentation policy: consumes accepted route state, never replans or reads sensors.
/// A held manoeuvre speaks once per stage even if angle hysteresis re-arms several times.
struct RouteAnnouncementPolicy {
    private var maneuverID: UInt64?
    private var announcedStages: Set<ForwardRouteMode> = []
    private var previousMode: ForwardRouteMode?

    mutating func reset() { self = .init() }

    mutating func cue(strategy: ForwardStrategyDiagnostics?, side: Int?, hasHeading: Bool) -> RouteSpeechCue? {
        guard hasHeading else { return nil }
        guard let strategy else { return side.map { .turn($0) } }
        let wasAvoiding = previousMode == .detour || previousMode == .returning
        previousMode = strategy.mode
        if maneuverID != strategy.maneuverID {
            maneuverID = strategy.maneuverID
            announcedStages.removeAll()
        }
        if strategy.mode == .straight, wasAvoiding { return .straight }
        guard let side else { return nil }
        switch strategy.mode {
        case .detour, .sideRoute, .returning:
            guard announcedStages.insert(strategy.mode).inserted else { return nil }
            return strategy.mode == .returning
                ? .rejoin(side) : (strategy.mode == .detour ? .detour(side) : .turn(side))
        case .straight:
            return .turn(side)
        case .blocked:
            return nil
        }
    }
}

nonisolated enum RouteSpeechCue: Equatable {
    case turn(Int)
    case detour(Int)
    case rejoin(Int)
    case straight

    var chinese: String {
        switch self {
        case .turn(let side): return side < 0 ? "向左转" : "向右转"
        case .detour(let side): return side < 0 ? "从左侧绕行" : "从右侧绕行"
        case .rejoin(let side): return side < 0 ? "向左，回到原路线" : "向右，回到原路线"
        case .straight: return "继续直行"
        }
    }
    var english: String {
        switch self {
        case .turn(let side): return side < 0 ? "Turn left" : "Turn right"
        case .detour(let side): return side < 0 ? "Pass on the left" : "Pass on the right"
        case .rejoin(let side): return side < 0 ? "Bear left to rejoin" : "Bear right to rejoin"
        case .straight: return "Continue straight"
        }
    }
}
