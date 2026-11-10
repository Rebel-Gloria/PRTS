import Testing

@testable import PRTS

struct GuidanceAlertTests {
    /// Feeds the 10 Hz poll and returns the times, in tenths of a second, of each alert.
    private func run(
        _ policy: inout GuidanceAlertPolicy,
        ticks: ClosedRange<Int>,
        available: Bool,
        blocked: Bool = false
    ) -> [Int: GuidanceAlert] {
        var fired: [Int: GuidanceAlert] = [:]
        for tick in ticks {
            fired[tick] = policy.update(
                available: available,
                blocked: blocked,
                now: Double(tick) / 10
            )
        }
        return fired
    }

    @Test func startupWaitsLongerThanALossAfterGuidanceWasSeen() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...100, available: false) == [40: .lost, 90: .lost])

        policy.reset()
        #expect(run(&policy, ticks: 0...10, available: true).isEmpty)
        #expect(run(&policy, ticks: 11...80, available: false) == [26: .lost, 76: .lost])
    }

    @Test func aBriefGapRaisesNothingAndRestartsTheWait() {
        var policy = GuidanceAlertPolicy()
        #expect(run(&policy, ticks: 0...0, available: true).isEmpty)
        #expect(run(&policy, ticks: 1...14, available: false).isEmpty)
        #expect(run(&policy, ticks: 15...15, available: true).isEmpty)
        #expect(run(&policy, ticks: 16...29, available: false).isEmpty)
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
        #expect(run(&policy, ticks: 11...30, available: false, blocked: true) == [26: .lost])
    }
}
