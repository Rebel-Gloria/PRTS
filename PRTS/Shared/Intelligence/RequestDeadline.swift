import Foundation

/// How long a person waits for a cloud answer before the app tries the next reader. URLRequest's
/// own timeout only limits the gap between packets, so a slow answer never reaches it.
nonisolated enum RequestDeadline {
    /// Reasoning adds to the answer time, so it gets longer than a plain answer.
    static let answerWithThinking: Duration = .seconds(20)
    static let textReading: Duration = .seconds(20)

    static func run<Result: Sendable>(
        _ limit: Duration,
        _ work: @escaping @Sendable () async throws -> Result
    ) async throws -> Result {
        try await withThrowingTaskGroup(of: Result.self) { group in
            defer { group.cancelAll() }
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw URLError(.timedOut)
            }
            return try await group.next()!
        }
    }
}

extension Error {
    /// URLSession reports cancellation as URLError rather than CancellationError.
    nonisolated var isCancellation: Bool {
        self is CancellationError || (self as? URLError)?.code == .cancelled
    }
}
