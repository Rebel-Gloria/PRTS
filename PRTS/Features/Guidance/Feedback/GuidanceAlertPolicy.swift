import Foundation

/// States in which the user should stop relying on direction cues.
nonisolated enum GuidanceAlert: Equatable {
    /// No current guidance result: tracking is limited, frames are stale or analysis is paused.
    case lost
    /// Obstacles are confirmed ahead and no way around them is in view.
    case blocked
}

/// Reports a state once it has lasted `delay`, then every `interval` while it lasts.
nonisolated struct SustainedCue {
    private var since: Double?
    private var firedAt: Double?

    mutating func update(active: Bool, now: Double, delay: Double, interval: Double) -> Bool {
        guard active else {
            since = nil
            firedAt = nil
            return false
        }
        let start = since ?? now
        since = start
        guard now - start + 0.000001 >= delay else { return false }
        if let firedAt, now - firedAt + 0.000001 < interval { return false }
        firedAt = now
        return true
    }
}

/// Silence used to mean "clear", "cannot see" and "stopped" alike. Direction speech and
/// vibration both stop without a path, so these two states get a cue of their own.
/// A dropped frame or a brief blocked flicker must not raise one: both states have to last.
nonisolated struct GuidanceAlertPolicy {
    static let lossDelay: Double = 1.5
    /// Tracking and the occupancy model need longer to produce their first result.
    static let startupLossDelay: Double = 4
    static let lossInterval: Double = 5
    /// The settling time route speech uses for a scene change.
    static let blockedDelay: Double = 0.6
    static let blockedInterval: Double = 3

    private var seen = false
    private var lost = SustainedCue()
    private var blocked = SustainedCue()

    mutating func reset() { self = .init() }

    mutating func update(available: Bool, blocked isBlocked: Bool, now: Double) -> GuidanceAlert? {
        if available { seen = true }
        let isLost = lost.update(
            active: !available,
            now: now,
            delay: seen ? Self.lossDelay : Self.startupLossDelay,
            interval: Self.lossInterval
        )
        let stillBlocked = blocked.update(
            active: available && isBlocked,
            now: now,
            delay: Self.blockedDelay,
            interval: Self.blockedInterval
        )
        return isLost ? .lost : (stillBlocked ? .blocked : nil)
    }
}
