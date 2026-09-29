import Foundation
import SpatialCore

/// Phase 1 intentionally has one runtime profile: fully offline geometry perception.
enum PRTSRuntimeProfile: String, Sendable {
    case offlineGeometry
    // Product policy, not a Dev-recording switch. Both builds use identical planning.
    nonisolated static let routePlanningPolicy: RoutePlanningPolicy = .obstacleVeto
}
