/// Shared feedback gate for automatic startup, polling, and first-launch guidance.
nonisolated enum HomeFeedbackPolicy {
    static let lowVisionKey = "app.lowVisionMode"

    static func suppressesGuidance(lowVisionMode: Bool, showingUserGuide: Bool) -> Bool {
        lowVisionMode || showingUserGuide
    }
}
