import Foundation
import XCTest

@testable import SpatialCore

final class DiagnosticPolicyTests: XCTestCase {
    private func location() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testDisabledJournalDoesNotCreateFilesOrMaterializeMeasurements() {
        let root = location()
        let journal = DiagnosticJournal(root: root, metadata: [:], enabled: false)
        for stream in DiagnosticStream.allCases {
            XCTAssertFalse(
                journal.submit(stream) {
                    XCTFail("Disabled diagnostics must reject before creating the payload")
                    return DiagnosticPacket(json: Data())
                }
            )
        }
        let flushed = expectation(description: "disabled flush finishes")
        journal.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testUnlimitedDiskPolicyStillAppliesMemoryAdmissionLimits() {
        var limits = DiagnosticLimits()
        limits.runBytes = nil
        limits.totalBytes = nil
        limits.maximumPendingBytes = 64
        limits.reservedEventBytes = 0
        let journal = DiagnosticJournal(root: location(), metadata: [:], limits: limits)
        XCTAssertFalse(
            journal.submit(.analysis, estimatedBytes: 65) {
                XCTFail("Unlimited disk storage must not admit an oversized memory reservation")
                return DiagnosticPacket(json: Data())
            }
        )
        let flushed = expectation(description: "unlimited flush finishes")
        journal.submit(.events, estimatedBytes: 1) {
            DiagnosticPacket(json: Data("{\"name\":\"test\"}".utf8))
        }
        journal.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 2)
        XCTAssertEqual(journal.status().written["events"], 1)
        XCTAssertFalse(journal.status().limitReached)
    }
}
