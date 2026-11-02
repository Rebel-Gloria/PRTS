import Foundation

/// Press timestamps share the monotonic clock used by photo interactions.
nonisolated struct LiveCaptionPressState {
    enum Action: Equatable { case photo, none, confirm, start, stop }
    enum Phase: Equatable {
        case normal
        case confirming(until: TimeInterval)
        case running
    }

    private(set) var phase: Phase = .normal
    private var previousPress: TimeInterval?

    mutating func down(at time: TimeInterval) -> Action {
        if case .confirming(let deadline) = phase, time > deadline {
            phase = .normal
            previousPress = nil
        }
        if let previousPress, time <= previousPress + 0.3 {
            self.previousPress = nil
            switch phase {
            case .normal:
                phase = .confirming(until: time + 5)
                return .confirm
            case .confirming:
                phase = .running
                return .start
            case .running:
                phase = .normal
                return .stop
            }
        }
        previousPress = time
        return phase == .running ? .none : .photo
    }

    mutating func cancelPress() {
        previousPress = nil
    }
}
