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
        case .turn(let side): return side < 0 ? "向左" : "向右"
        case .detour(let side): return side < 0 ? "从左边绕" : "从右边绕"
        case .rejoin(let side): return side < 0 ? "向左回原路" : "向右回原路"
        case .straight: return "直走"
        }
    }
    var english: String {
        switch self {
        case .turn(let side): return side < 0 ? "Go left" : "Go right"
        case .detour(let side): return side < 0 ? "Pass left" : "Pass right"
        case .rejoin(let side): return side < 0 ? "Left to rejoin" : "Right to rejoin"
        case .straight: return "Go straight"
        }
    }
}
