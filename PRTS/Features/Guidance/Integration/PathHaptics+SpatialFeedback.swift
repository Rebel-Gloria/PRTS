/// The application supplies hardware feedback to the spatial presentation boundary.
extension PathHaptics: SpatialFeedback {
    func reset() { stop(reset: true) }
}
