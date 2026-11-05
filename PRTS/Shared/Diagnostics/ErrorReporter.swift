import Foundation

/// Features receive an error-reporting function; they do not own files or retention policy.
nonisolated struct ErrorReporter: Sendable {
    let record: @Sendable (Error) -> Void

    init(source: ErrorSource, log: ErrorLog = .application) {
        record = { log.record($0, source: source) }
    }

    init(record: @escaping @Sendable (Error) -> Void) {
        self.record = record
    }
}
