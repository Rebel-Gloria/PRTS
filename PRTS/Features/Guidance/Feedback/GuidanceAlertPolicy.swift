import Foundation

/// States in which the user should stop relying on direction cues.
nonisolated enum GuidanceAlert: Equatable {
    /// Guidance is still missing after the user has moved beyond reusable measurements.
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

/// A session starts disarmed. Only usable guidance arms a loss episode, and only
/// recovery (not a change in tracking confidence) can re-arm it after it fires.
nonisolated struct GuidanceAlertPolicy {
    static let lossDelay: Double = 1.5
    static let blockedDelay: Double = 0.6
    static let blockedInterval: Double = 3

    private enum LossState { case waiting, armed, reported }
    private var lossState = LossState.waiting
    private var missingSince: Double?
    var reportedLoss: Bool { lossState == .reported }
    private var blocked = SustainedCue()

    /// Do not count time spent in another feature as loss or blockage. Neither a
    /// previous measurement nor an already reported loss expires just because UI paused.
    mutating func pause() {
        missingSince = nil
        blocked = .init()
    }

    mutating func update(
        available: Bool,
        blocked isBlocked: Bool,
        leftMappedArea: Bool,
        now: Double
    ) -> GuidanceAlert? {
        let stillBlocked = blocked.update(
            active: available && isBlocked,
            now: now,
            delay: Self.blockedDelay,
            interval: Self.blockedInterval
        )
        if available {
            lossState = .armed
            missingSince = nil
            return stillBlocked ? .blocked : nil
        }
        guard lossState == .armed else { return nil }
        let start = missingSince ?? now
        missingSince = start
        guard leftMappedArea, now - start + 0.000001 >= Self.lossDelay else { return nil }
        lossState = .reported
        return .lost
    }
}

/// Measurement and spoken-scene history belong to one planning session, not one visit
/// to the home screen. Check identity even on polls with no result or muted feedback.
struct WaypointFeedbackSession {
    private var epoch: UInt64?
    private var parameterVersion: UInt64?
    private var planningEnabled: Bool?
    var alerts = GuidanceAlertPolicy()
    var speech = ObstacleRouteAnnouncementPolicy()

    mutating func synchronize(epoch: UInt64, parameterVersion: UInt64, planningEnabled: Bool)
        -> Bool
    {
        guard
            self.epoch != epoch || self.parameterVersion != parameterVersion
                || self.planningEnabled != planningEnabled
        else { return false }
        let replaced = self.epoch != nil
        alerts = .init()
        speech.reset()
        self.epoch = epoch
        self.parameterVersion = parameterVersion
        self.planningEnabled = planningEnabled
        return replaced
    }
}
