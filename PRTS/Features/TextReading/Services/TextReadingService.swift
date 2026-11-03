import Foundation

/// Text reading can follow the default provider, select a provider, or use Apple Vision.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vlm, onDevice, qwen, deepseek, custom, vision

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// The former "remote" value no longer decodes, so it reads as .vlm.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:))
            ?? .vlm
    }

    func provider(_ defaults: UserDefaults = .standard) -> PhotoChatProvider? {
        switch self {
        case .vlm: PhotoChatProvider.current(defaults)
        case .vision: nil
        case .onDevice, .qwen, .deepseek, .custom: PhotoChatProvider(rawValue: rawValue)!
        }
    }

    var localizationKey: String {
        switch self {
        case .vlm: "intelligence.provider.default"
        case .vision: "settings.ocr.service.vision"
        case .onDevice, .qwen, .deepseek, .custom: "photo.settings.provider.\(rawValue)"
        }
    }

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
