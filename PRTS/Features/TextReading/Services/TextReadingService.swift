import Foundation

/// Who reads the text. Settings → under the three-finger switch.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vision, onDevice, remote

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// The bundled model by default: it knows what the text is on, and needs no network.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:))
            ?? .onDevice
    }

    var localizationKey: String { "settings.ocr.service.\(rawValue)" }
}
