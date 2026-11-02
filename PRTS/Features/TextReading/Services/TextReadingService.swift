import Foundation

/// The user chooses a model following Intelligence settings, or Apple's offline OCR.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vlm, vision

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// The former "onDevice" and "remote" values no longer decode, so they read as .vlm.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:))
            ?? .vlm
    }

    var localizationKey: String { "settings.ocr.service.\(rawValue)" }

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
            case .vlm: remoteAvailable ? [.remote, .onDevice, .vision] : [.onDevice, .vision]
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
