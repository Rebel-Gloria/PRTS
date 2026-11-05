import Foundation
import SpatialCore
import Testing

@testable import PRTS

@MainActor
struct RecorderPolicyTests {
    @Test func appDefaultsUseTheBuildCapturePolicy() async {
        let journal = DiagnosticRecorder().journal
        #if PRTS_DEV_CAPTURE
        #expect(journal.isEnabled)
        #expect(journal.limits.runBytes == nil && journal.limits.totalBytes == nil)
        #expect(ErrorLog.application.directory.lastPathComponent == "Errors")
        #else
        #expect(!journal.isEnabled)
        #expect(ErrorLog.application.directory.lastPathComponent == "ErrorLogs")
        #endif
        await withCheckedContinuation { done in journal.flush { done.resume() } }
        #expect(FileManager.default.fileExists(atPath: journal.directory.path) == journal.isEnabled)
    }

    @Test(arguments: [false, true])
    func sessionWriterFollowsTheDiagnosticRecordingPolicy(enabled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = DiagnosticJournal(
            root: root.appendingPathComponent("Diagnostics"),
            metadata: [:],
            enabled: enabled
        )
        let sessions = root.appendingPathComponent("Sessions")
        let recorder = SessionRecorder(
            diagnostics: DiagnosticRecorder(journal: journal),
            root: sessions
        )
        recorder.begin(epoch: 1, parameters: ProbeParameters(), device: [:])
        recorder.event("test", details: "synthetic", epoch: 1)
        recorder.finish(epoch: 1)
        await withCheckedContinuation { done in recorder.flush { done.resume() } }
        await withCheckedContinuation { done in journal.flush { done.resume() } }
        #expect(FileManager.default.fileExists(atPath: sessions.path) == enabled)
        if enabled {
            let runs = try FileManager.default.contentsOfDirectory(
                at: sessions,
                includingPropertiesForKeys: nil
            )
            #expect(runs.count == 1)
            #expect(
                FileManager.default.fileExists(
                    atPath: runs[0].appendingPathComponent("events.jsonl").path
                )
            )
        }
    }
}
