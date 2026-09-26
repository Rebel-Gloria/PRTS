import Foundation

extension PRTSARSessionState {
    var label: String {
        switch self {
        case .unavailable: return "unavailable"
        case .idle: return "idle"
        case .running: return "running"
        case .paused: return "paused"
        case .relocalizing: return "relocalizing"
        }
    }
}
