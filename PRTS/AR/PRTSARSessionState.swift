import Foundation

enum PRTSARSessionState: Equatable {
    case unavailable(String)
    case idle
    case running
    case paused
    case relocalizing
}

