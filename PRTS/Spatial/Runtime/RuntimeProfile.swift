import SpatialCore

/// Both builds use the same planning policy, independently of developer recording settings.
enum PRTSRuntimeProfile {
    nonisolated static let routePlanningPolicy: RoutePlanningPolicy = .obstacleVeto
}
