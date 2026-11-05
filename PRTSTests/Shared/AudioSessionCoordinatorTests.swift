import Foundation
import Testing

@testable import PRTS

@MainActor
struct AudioSessionCoordinatorTests {
    private enum Failure: Error { case activation, deactivation }
    private final class Driver: AudioSessionDriving {
        var modes: [AppAudioMode] = []
        var deactivations = 0
        var failActivation = false
        var failDeactivation = false
        func activate(_ mode: AppAudioMode) throws {
            if failActivation { throw Failure.activation }
            modes.append(mode)
        }
        func deactivate() throws {
            deactivations += 1
            if failDeactivation { throw Failure.deactivation }
        }
    }

    @Test func finishingAnOldOutputCannotDeactivateANewRecording() throws {
        let driver = Driver()
        let session = AudioSessionCoordinator(driver: driver)
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
        let session = AudioSessionCoordinator(driver: driver)
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
        let session = AudioSessionCoordinator(driver: driver)
        let current = try session.activate(.tone)
        driver.failActivation = true
        #expect(throws: Failure.activation) { try session.activate(.recording) }
        #expect(driver.deactivations == 0)
        session.release(current)
        #expect(driver.deactivations == 1)
    }

    @Test func failedReleaseCannotBeRetriedAgainstANewerOutput() throws {
        let driver = Driver()
        let session = AudioSessionCoordinator(driver: driver, errors: .init(record: { _ in }))
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
}
