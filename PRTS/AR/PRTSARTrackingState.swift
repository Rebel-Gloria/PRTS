import Foundation
import ARKit

enum PRTSARTrackingState: Equatable {
    case unavailable
    case initializing
    case limited(String)
    case normal

    init(_ state: ARCamera.TrackingState) {
        switch state {
        case .notAvailable: self = .unavailable
        case .normal: self = .normal
        case .limited(let reason): self = .limited(String(describing: reason))
        @unknown default: self = .limited("unknown")
        }
    }
}
