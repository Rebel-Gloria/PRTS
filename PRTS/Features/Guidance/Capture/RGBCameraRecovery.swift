/// Recovery is driven only by a media-service reset. Ordinary focus changes keep the session.
nonisolated struct RGBCameraRecovery {
    private(set) var requested = false
    private(set) var sceneActive = false
    private(set) var interrupted = false
    private var resetPending = false

    mutating func requestStart() {
        requested = true
        resetPending = false
    }

    mutating func requestStop() {
        requested = false
        interrupted = false
        resetPending = false
    }

    mutating func setSceneActive(_ active: Bool) { sceneActive = active }

    mutating func setInterrupted(_ value: Bool) {
        guard requested else { return }
        interrupted = value
    }

    mutating func mediaServicesReset() { resetPending = true }

    /// Consuming the request before attempting recovery prevents retries on every UI poll.
    mutating func takeRecoveryRequest() -> Bool {
        guard requested, sceneActive, !interrupted, resetPending else { return false }
        resetPending = false
        return true
    }
}
