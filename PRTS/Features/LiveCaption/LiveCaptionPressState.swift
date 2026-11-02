import Foundation

/// Press timestamps share the monotonic clock used by photo interactions.
nonisolated struct LiveCaptionPressState {
    enum Action: Equatable {
        case photo(PhotoPressState.Action)
        case start, stop
    }
    static let interval: TimeInterval = 0.35

    private var photo = PhotoPressState()
    private var beganAt: TimeInterval?
    private var lastDown: TimeInterval?
    private var taps = 0

    var deadline: TimeInterval? {
        if let beganAt, lastDown != nil { return beganAt + 0.5 }
        return lastDown.map { ($0 + Self.interval).nextUp }
    }

    mutating func down(at time: TimeInterval, running: Bool) -> [Action] {
        if running {
            cancel()
            return [.stop]
        }
        let actions = advance(to: time)
        beganAt = time
        lastDown = time
        photo.begin(at: time)
        return actions
    }

    mutating func advance(to time: TimeInterval) -> [Action] {
        if photo.advance(to: time) == .startRecording {
            taps = 0
            lastDown = nil
            return [.photo(.startRecording)]
        }
        if beganAt == nil, let lastDown, time > lastDown + Self.interval {
            cancel()
            return [.photo(.shortCapture)]
        }
        return []
    }

    mutating func up(at time: TimeInterval) -> [Action] {
        let actions = photo.release(at: time)
        beganAt = nil
        if actions == [.shortCapture] {
            taps += 1
            // Release distinguishes the third tap from a held question.
            if taps == 3 {
                cancel()
                return [.start]
            }
            return advance(to: time)
        }
        cancel()
        return actions.map { .photo($0) }
    }

    mutating func cancel() {
        photo.cancel()
        beganAt = nil
        lastDown = nil
        taps = 0
    }
}
