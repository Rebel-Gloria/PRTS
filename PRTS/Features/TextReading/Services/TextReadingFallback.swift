import Foundation

extension TextReadingService {
    enum Reader: Equatable { case remote, onDevice, vision }

    /// Tries each reader in turn: the remote service when it is set up, then the bundled model,
    /// then Apple's Vision. A cancelled request stops the chain.
    @MainActor
    func read(
        remoteAvailable: Bool,
        onFailure: (Error) -> Void = { _ in },
        perform: (Reader) async throws -> Void
    ) async throws {
        let readers: [Reader] =
            switch self {
            case .vlm, .qwen, .deepseek, .custom:
                remoteAvailable ? [.remote, .onDevice, .vision] : [.onDevice, .vision]
            case .onDevice: [.onDevice, .vision]
            case .vision: [.vision]
            }
        for (index, reader) in readers.enumerated() {
            try Task.checkCancellation()
            do {
                try await perform(reader)
                return
            } catch {
                if error.isCancellation { throw CancellationError() }
                if index == readers.count - 1 { throw error }
                onFailure(error)
            }
        }
    }
}
