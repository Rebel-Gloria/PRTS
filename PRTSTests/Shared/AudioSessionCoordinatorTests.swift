import Foundation
import Testing

@testable import PRTS

@MainActor
struct AudioSessionCoordinatorTests {
    private enum Failure: Error { case activation, deactivation }
    nonisolated private final class Driver: AudioSessionDriving, @unchecked Sendable {
        var modes: [AppAudioMode] = []
        var deactivations = 0
        var beforeActivation: (() -> Void)?
        var failActivation = false
        var failDeactivation = false
        func activate(_ mode: AppAudioMode) throws {
            beforeActivation?()
            if failActivation { throw Failure.activation }
            modes.append(mode)
        }
        func deactivate() throws {
            deactivations += 1
            if failDeactivation { throw Failure.deactivation }
        }
    }

    private func coordinator(_ driver: Driver) -> AudioSessionCoordinator {
        AudioSessionCoordinator(
            driver: driver,
            errors: .ignored,
            scheduleDeactivation: { $0.perform() }
        )
    }

    @Test func finishingAnOldOutputCannotDeactivateANewRecording() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let guide = try session.activate(.speech)
        let recording = try session.activate(.recording)
        session.release(guide)
        #expect(driver.deactivations == 0)
        session.release(recording)
        #expect(driver.deactivations == 1)
        #expect(driver.modes == [.speech, .recording])
    }

    @Test func releasingAnOlderActivationIsHarmlessEvenForTheSameMode() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let first = try session.activate(.speech)
        let replacement = try session.activate(.speech)
        session.release(nil)
        session.release(first)
        #expect(driver.deactivations == 0)
        session.release(replacement)
        session.release(replacement)
        #expect(driver.deactivations == 1)
    }

    @Test func failedActivationDoesNotTakeOwnershipFromTheCurrentOutput() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let current = try session.activate(.tone)
        driver.failActivation = true
        #expect(throws: Failure.activation) { try session.activate(.recording) }
        #expect(driver.deactivations == 0)
        session.release(current)
        #expect(driver.deactivations == 1)
    }

    @Test func failedReleaseCannotBeRetriedAgainstANewerOutput() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let first = try session.activate(.speech)
        driver.failDeactivation = true
        session.release(first)
        driver.failDeactivation = false
        let next = try session.activate(.tone)
        session.release(first)
        #expect(driver.deactivations == 1)
        session.release(next)
        #expect(driver.deactivations == 2)
    }

    @Test func theNextOutputCancelsAWaitingDeactivation() throws {
        let driver = Driver()
        var waiting: DispatchWorkItem?
        let session = AudioSessionCoordinator(
            driver: driver,
            errors: .ignored,
            scheduleDeactivation: { waiting = $0 }
        )
        let first = try session.activate(.speech)
        session.release(first)
        let next = try session.activate(.speech)
        waiting?.perform()
        #expect(driver.deactivations == 0)
        session.release(next)
        waiting?.perform()
        #expect(driver.deactivations == 1)
    }

    @Test func aFailedActivationStillDeactivatesAnUnownedSession() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let first = try session.activate(.speech)
        session.release(first)
        driver.failActivation = true
        #expect(throws: Failure.activation) { try session.activate(.recording) }
        #expect(driver.deactivations == 2)
    }

    // Run the real queue and cache; hold only delivery of the result to each waiting task.
    @MainActor
    private struct Handoff {
        let driver = Driver()
        let session: AudioSessionCoordinator
        private var deliveries: AsyncStream<@Sendable () -> Void>.Iterator

        init() {
            let (stream, output) = AsyncStream<@Sendable () -> Void>.makeStream()
            deliveries = stream.makeAsyncIterator()
            session = AudioSessionCoordinator(
                driver: driver,
                errors: .ignored,
                deliverActivation: { output.yield($0) },
                scheduleDeactivation: { $0.perform() }
            )
        }

        mutating func start(_ mode: AppAudioMode) async -> () async throws ->
            AudioSessionCoordinator.Lease
        {
            let task = Task { [session] in try await session.activateAsync(mode) }
            var iterator = deliveries
            let deliver = await iterator.next()!
            deliveries = iterator
            return {
                deliver()
                return try await task.value
            }
        }
    }

    @Test func overlappingRecordingRequestsShareTheActivationFailure() async {
        var h = Handoff()
        h.driver.failActivation = true
        var calls = 0
        h.driver.beforeActivation = { calls += 1 }
        let first = await h.start(.recording)
        let second = await h.start(.recording)
        await #expect(throws: Failure.activation) { try await second() }
        await #expect(throws: Failure.activation) { try await first() }
        #expect(calls == 1)
        #expect(h.driver.deactivations == 1)
    }

    @Test(arguments: [false, true])
    func failedSwitchAfterOnlyOneSharedRequestReturns(releaseWhilePending: Bool) async throws {
        var h = Handoff()
        let first = await h.start(.recording)
        let second = await h.start(.recording)
        let owner = try await first()
        h.driver.failActivation = true
        let change = await h.start(.tone)
        await #expect(throws: CancellationError.self) { try await second() }
        if releaseWhilePending { h.session.release(owner) }
        #expect(h.driver.deactivations == 0)
        await #expect(throws: Failure.activation) { try await change() }
        #expect(h.driver.deactivations == (releaseWhilePending ? 1 : 0))
        h.session.release(owner)
        #expect(h.driver.deactivations == 1)
        #expect(h.driver.modes == [.recording])
    }

    @Test(arguments: [false, true])
    func asyncCompletionCannotTakeBackASynchronousLease(releaseOwnerFirst: Bool) async throws {
        var h = Handoff()
        let old = await h.start(.recording)
        let owner = try h.session.activate(.recording)
        if releaseOwnerFirst {
            h.session.release(owner)
            await #expect(throws: CancellationError.self) { try await old() }
        } else {
            h.session.release(try await old())
            #expect(h.driver.deactivations == 0)
            h.session.release(owner)
        }
        #expect(h.driver.deactivations == 1)
        #expect(h.driver.modes == [.recording])
    }

    @Test func anOlderCompletionCannotReviveAReleasedOwnerDuringHandoff() async throws {
        var h = Handoff()
        let old = await h.start(.recording)
        let new = await h.start(.recording)
        let pending = await h.start(.recording)
        h.session.release(try await new())
        #expect(h.driver.deactivations == 0)
        let stale = try await old()
        h.driver.failActivation = true
        #expect(throws: Failure.activation) { try h.session.activate(.tone) }
        await #expect(throws: CancellationError.self) { try await pending() }
        #expect(h.driver.deactivations == 1)
        h.session.release(stale)
        #expect(h.driver.deactivations == 1)
    }

    @Test func aSupersededFailureCannotDeactivateTheNewOutput() async throws {
        var h = Handoff()
        h.driver.failActivation = true
        let failed = await h.start(.recording)
        h.driver.failActivation = false
        let owner = try h.session.activate(.speech)
        await #expect(throws: Failure.activation) { try await failed() }
        #expect(h.driver.deactivations == 0)
        h.session.release(owner)
        #expect(h.driver.deactivations == 1)
    }

    @Test func foregroundRecoveryWithoutEndNotificationChecksTheActualRoute() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let current = try session.activate(.speech)
        driver.failActivation = true
        #expect(!session.resumeAfterInterruption())
        driver.failActivation = false
        #expect(session.resumeAfterInterruption())
        #expect(driver.modes == [.speech, .speech])
        #expect(driver.deactivations == 0)
        session.release(current)
        #expect(driver.deactivations == 1)
    }

    @Test func sameModeForTheCurrentOutputDoesNotReachTheSystemAgain() throws {
        let driver = Driver()
        let session = coordinator(driver)
        let cue = try session.activate(.recording)
        let recognizer = try session.activate(.recording)
        session.release(cue)
        #expect(driver.modes == [.recording])
        #expect(driver.deactivations == 0)
        session.release(recognizer)
        #expect(driver.deactivations == 1)
    }
}
