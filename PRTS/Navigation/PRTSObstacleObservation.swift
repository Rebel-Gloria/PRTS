import Foundation

struct PRTSObstacleObservation: Identifiable {
    let id = UUID()
    let label: String
    let distanceMeters: Float
    let azimuthRadians: Float
    let box: CGRect
    let score: Float
}
