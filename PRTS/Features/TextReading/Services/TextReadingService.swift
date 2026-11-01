import Foundation

/// The user chooses a model following Intelligence settings, or Apple's offline OCR.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vlm, vision

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// Old local and remote selections both become provider-following model recognition.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:))
            ?? .vlm
    }

    var localizationKey: String { "settings.ocr.service.\(rawValue)" }

    enum Reader: Equatable { case remote, onDevice, vision }

    /// A fixed fallback order, with no network probe or change to the saved provider.
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
                try Task.checkCancellation()
                return
            } catch {
                // URLSession may report cancellation as URLError rather than CancellationError.
                try Task.checkCancellation()
                if error is CancellationError || (error as? URLError)?.code == .cancelled {
                    throw CancellationError()
                }
                if index == readers.count - 1 { throw error }
            }
        }
    }
}
