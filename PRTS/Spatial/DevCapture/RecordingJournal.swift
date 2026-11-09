#if PRTS_DEV_CAPTURE
import Foundation
import SpatialCore

/// Admission and detachment share a lock so flushing cannot miss an accepted diagnostic record.
nonisolated final class RecordingJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var journal: DiagnosticJournal?
    private var startedAt: Double = 0

    func attach(_ journal: DiagnosticJournal, startedAt: Double) {
        lock.withLock {
            self.journal = journal
            self.startedAt = startedAt
        }
    }

    func detach() -> DiagnosticJournal? {
        lock.withLock {
            defer { journal = nil }
            return journal
        }
    }

    func submit(
        _ stream: DiagnosticStream,
        estimatedBytes: Int,
        sourceTime: Double?,
        make: @escaping @Sendable () throws -> DiagnosticPacket
    ) {
        lock.withLock {
            guard let journal, sourceTime.map({ $0 >= startedAt }) ?? true else { return }
            journal.submit(stream, estimatedBytes: estimatedBytes, make: make)
        }
    }
}
#endif
