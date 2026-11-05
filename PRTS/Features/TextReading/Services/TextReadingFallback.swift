import Foundation

extension TextReadingService {
    enum Reader: Equatable { case remote, onDevice, vision }

    /// Tries each reader in turn: the remote service when it is set up, then the bundled model,
    /// then Apple's Vision. A cancelled request stops the chain.
    @MainActor
    func read(
        remoteAvailable: Bool,
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
                // URLSession reports cancellation as URLError rather than CancellationError.
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                if index == readers.count - 1 { throw error }
            }
        }
    }
}
