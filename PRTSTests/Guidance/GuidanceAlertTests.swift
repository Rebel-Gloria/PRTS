import Testing

@testable import PRTS

struct GuidanceAlertTests {
    /// Feeds the 10 Hz poll and returns the times, in tenths of a second, of each alert.
    private func run(
        _ policy: inout GuidanceAlertPolicy,
        ticks: ClosedRange<Int>,
        available: Bool,
        blocked: Bool = false,
        left: Bool = false
    ) -> [Int: GuidanceAlert] {
        var fired: [Int: GuidanceAlert] = [:]
        for tick in ticks {
            fired[tick] = policy.update(
                available: available,
                blocked: blocked,
                leftMappedArea: left,
                now: Double(tick) / 10
            )
        }
        return fired
    }

    @Test @MainActor func newEpochWithoutMeasurementsStaysSilent() {
        var session = WaypointFeedbackSession()
        _ = session.synchronize(epoch: 1, parameterVersion: 0, planningEnabled: true)
        #expect(run(&session.alerts, ticks: 0...10, available: false, left: true).isEmpty)
        #expect(run(&session.alerts, ticks: 11...11, available: true).isEmpty)
        session.alerts.pause()
        _ = session.synchronize(epoch: 2, parameterVersion: 0, planningEnabled: true)
        #expect(run(&session.alerts, ticks: 12...100, available: false, left: true).isEmpty)
    }

    @Test @MainActor func resumePreservesArmingButDoesNotCountMutedTimeOrReplayLoss() {
        var session = WaypointFeedbackSession()
        _ = session.synchronize(epoch: 1, parameterVersion: 0, planningEnabled: true)
        #expect(run(&session.alerts, ticks: 0...0, available: true).isEmpty)
        #expect(run(&session.alerts, ticks: 1...14, available: false, left: true).isEmpty)
        for _ in 15...100 {
            _ = session.synchronize(epoch: 1, parameterVersion: 0, planningEnabled: true)
            session.alerts.pause()
        }
        #expect(run(&session.alerts, ticks: 101...115, available: false, left: true).isEmpty)
        #expect(
            run(&session.alerts, ticks: 116...116, available: false, left: true) == [116: .lost]
        )
        session.alerts.pause()
        #expect(run(&session.alerts, ticks: 150...220, available: false, left: true).isEmpty)
        #expect(run(&session.alerts, ticks: 221...221, available: true).isEmpty)
        #expect(run(&session.alerts, ticks: 222...250, available: false).isEmpty)
    }

    @Test func sustainedLossRequiresTrustedDepartureAndOnlyRecoveryRearmsIt() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...0, available: true).isEmpty)
        #expect(run(&policy, ticks: 1...100, available: false).isEmpty)
        #expect(run(&policy, ticks: 101...180, available: false, left: true) == [101: .lost])
        #expect(run(&policy, ticks: 181...190, available: false).isEmpty)
        #expect(run(&policy, ticks: 191...260, available: false, left: true).isEmpty)
        #expect(policy.reportedLoss)
        #expect(run(&policy, ticks: 261...261, available: true).isEmpty)
        #expect(!policy.reportedLoss)
        #expect(run(&policy, ticks: 262...350, available: false, left: true) == [277: .lost])
    }

    @Test func usableFeedbackAtDeadlineWinsEvenWithDepartureEvidence() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...0, available: true).isEmpty)
        #expect(run(&policy, ticks: 1...15, available: false, left: true).isEmpty)
        #expect(
            run(&policy, ticks: 16...22, available: true, blocked: true, left: true) == [
                22: .blocked
            ]
        )
        #expect(run(&policy, ticks: 23...37, available: false, left: true).isEmpty)
    }

    @Test func blockedRepeatsWhileItLastsAndIgnoresAFlicker() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...5, available: true, blocked: true).isEmpty)
        #expect(run(&policy, ticks: 6...6, available: true).isEmpty)
        #expect(
            run(&policy, ticks: 7...50, available: true, blocked: true)
                == [13: .blocked, 43: .blocked]
        )
    }

    @Test func losingGuidanceWhileBlockedReportsTheLoss() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...10, available: true, blocked: true) == [6: .blocked])
        // A stale "blocked" is not evidence; only the loss is reported from here on.
        #expect(
            run(&policy, ticks: 11...30, available: false, blocked: true, left: true) == [26: .lost]
        )
    }
}
