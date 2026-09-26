import Foundation

struct PRTSNavigationObservation {
    let walkableMask: PRTSBinaryMask
    let paths: [PRTSGuidancePath]
    let branches: [PRTSPathBranch]
    let obstacles: [PRTSObstacleObservation]
    let nearestObstacle: PRTSObstacleObservation?
    let confidence: Float
    let processingSeconds: Double
}
