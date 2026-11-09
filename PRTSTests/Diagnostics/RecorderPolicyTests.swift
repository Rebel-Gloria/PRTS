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
}
