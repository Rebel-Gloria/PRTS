import Foundation

/// Gesture policy with an injected monotonic time; timers are only wakeups.
/// Exactly 0.5 seconds belongs to long press, including a delayed timer callback.
nonisolated struct PhotoPressState {
    enum Action: Equatable { case none, shortCapture, startRecording, stopRecording }
    private var beganAt: TimeInterval?
    private var recording = false
    var isPressed: Bool { beganAt != nil }

    mutating func begin(at time: TimeInterval) {
        guard beganAt == nil else { return }
        beganAt = time
        recording = false
    }

    mutating func advance(to time: TimeInterval) -> Action {
        guard let beganAt, !recording, time - beganAt >= 0.5 else { return .none }
        recording = true
        return .startRecording
    }

    mutating func release(at time: TimeInterval) -> [Action] {
        guard let beganAt else { return [] }
        defer { cancel() }
        if recording { return [.stopRecording] }
        if time - beganAt >= 0.5 { return [.startRecording, .stopRecording] }
        return [.shortCapture]
    }

    mutating func cancel() { beganAt = nil; recording = false }
}
