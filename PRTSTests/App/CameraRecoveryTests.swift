import SwiftUI
import Testing

@testable import PRTS

@Suite(.serialized)
@MainActor
struct CameraRecoveryTests {
    @Test func textReadingResumesStartedGuidanceInForeground() async throws {
        let camera = CameraManager()
        defer { camera.stopCamera() }
        camera.startCamera()
        try await waitForRunning(camera)
        camera.pauseForTextReading()
        #expect(camera.state == .idle)
        camera.finishTextReading(isActive: true)
        try await waitForRunning(camera)
    }

    @Test func interruptedTextReadingDefersRecoveryUntilForeground() async throws {
        let camera = CameraManager()
        defer { camera.stopCamera() }
        camera.startCamera()
        try await waitForRunning(camera)
        camera.pauseForTextReading()
        camera.finishTextReading(isActive: false)
        camera.lifecycle(.inactive)
        #expect(camera.state == .idle)
        camera.lifecycle(.active)
        try await waitForRunning(camera)
    }

    @Test func foregroundDoesNotTakeCameraFromTextReading() async throws {
        let camera = CameraManager()
        defer { camera.stopCamera() }
        camera.startCamera()
        try await waitForRunning(camera)
        camera.pauseForTextReading()
        camera.lifecycle(.active)
        try await Task.sleep(for: .milliseconds(200))
        camera.poll(suspendFeedback: true)
        #expect(camera.state == .idle)
        camera.finishTextReading(isActive: true)
        try await waitForRunning(camera)
    }

    @Test func explicitStopPreventsTextReadingRecovery() async throws {
        let camera = CameraManager()
        defer { camera.stopCamera() }
        camera.startCamera()
        try await waitForRunning(camera)
        camera.pauseForTextReading()
        camera.stopCamera()
        camera.finishTextReading(isActive: true)
        camera.lifecycle(.active)
        try await Task.sleep(for: .milliseconds(200))
        camera.poll(suspendFeedback: true)
        #expect(camera.state == .idle)
    }

    @Test func readingFromIdleDoesNotStartGuidance() async throws {
        let camera = CameraManager()
        defer { camera.stopCamera() }
        camera.pauseForTextReading()
        camera.finishTextReading(isActive: false)
        camera.lifecycle(.active)
        try await Task.sleep(for: .milliseconds(200))
        camera.poll(suspendFeedback: true)
        #expect(camera.state == .idle)
    }

    private func waitForRunning(_ camera: CameraManager) async throws {
        for _ in 0..<100 {
            camera.poll(suspendFeedback: true)
            if camera.state == .running { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(camera.state == .running)
    }
}
