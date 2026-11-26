import CoreImage
import Foundation

@MainActor
struct TextReadingServices {
    /// Missing setup stays offline without a prompt; photo upload still requires permission.
    static func cloudSetup(
        defaults: UserDefaults = .standard,
        readCredential: (String) throws -> String? = { try PhotoCredentialStore.read(account: $0) }
    ) -> (key: String, service: PhotoChatService)? {
        guard PhotoUploadPermission.isAllowed(in: defaults),
            let provider = IntelligenceFeature.textReading.provider(defaults),
            let service = provider.service(defaults)
        else { return nil }
        guard let key = try? readCredential(service.keyAccount), !key.isEmpty
        else { return nil }
        return (key, service)
    }

    var errors = ErrorReporter(source: .textReading)
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    var encode: (CIImage) async throws -> Data = { image in
        let longestSide = PhotoImagePurpose.textReading.longestSide(
            highResolution: UserDefaults.standard.bool(forKey: PhotoImagePurpose.highResolutionKey)
        )
        return try await Task.detached {
            try PhotoImageEncoder.jpeg(image: image, longestSide: longestSide)
        }.value
    }
    var surface: (Data) async throws -> TextReadingAnswer.Surface = {
        try await TextReadingBackend.surface(of: $0)
    }
    var copy: (@escaping @Sendable (String) -> Void) async throws -> String = {
        try await TextReadingBackend.copy(onText: $0)
    }
    var remote:
        (Data, String, PhotoChatService) async throws -> (TextReadingAnswer.Surface, String) = {
            try await TextReadingBackend.remote(jpeg: $0, key: $1, service: $2)
        }
    var vision: (CIImage) async throws -> String = { image in
        try await Task.detached { try TextRecognizer.read(image) }.value
    }
}
