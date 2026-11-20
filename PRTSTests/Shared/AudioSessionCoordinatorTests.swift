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

    @Test func overlappingRecordingRequestsShareTheActivationFailure() async {
        let driver = Driver()
        let session = coordinator(driver)
        let (entered, signal) = AsyncStream<Void>.makeStream()
        let unblock = DispatchSemaphore(value: 0)
        var calls = 0
        driver.beforeActivation = {
            calls += 1
            if calls == 1 {
                signal.yield(())
                unblock.wait()
            }
        }
        driver.failActivation = true
        let first = Task { try await session.activateAsync(.recording) }
        var events = entered.makeAsyncIterator()
        _ = await events.next()
        // The second call enters on the main actor before the driver is unblocked.
        DispatchQueue.main.async { unblock.signal() }
        await #expect(throws: Failure.activation) { try await session.activateAsync(.recording) }
        await #expect(throws: Failure.activation) { try await first.value }
        #expect(calls == 1)
        #expect(driver.deactivations == 1)
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
