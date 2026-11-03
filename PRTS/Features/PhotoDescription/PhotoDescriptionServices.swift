import Foundation

/// Replaceable time, configuration, permissions and description calls.
/// Live captions reuse part of them.
@MainActor
struct PhotoDescriptionServices {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// On device needs neither the upload permission nor a key.
    var onDevice: (IntelligenceFeature) -> Bool
    var uploadAllowed: () -> Bool
    var highResolution: () -> Bool = {
        UserDefaults.standard.bool(forKey: PhotoImagePurpose.highResolutionKey)
    }
    var credential: (IntelligenceFeature) throws -> String?
    var speechAuthorized: () -> Bool = { PhotoSpeechRecognizer.authorized }
    var requestSpeechPermission: () async -> Bool = {
        await PhotoSpeechRecognizer.requestPermissions()
    }
    /// A nil question is a short tap: describe the scene. A spoken question gets its own prompt
    /// and at most three sentences back.
    var describe: @Sendable (Data, String?, String) async throws -> String = {
        jpeg,
        question,
        key in
        try await PhotoDescriptionBackend.describe(jpeg: jpeg, question: question, key: key)
    }

    init(
        defaults: UserDefaults = .standard,
        readCredential: @escaping (String) throws -> String? = {
            try PhotoCredentialStore.read(account: $0)
        }
    ) {
        onDevice = { $0.provider(defaults) == .onDevice }
        credential = { try readCredential($0.provider(defaults)!.keyAccount) }
        uploadAllowed = { defaults.bool(forKey: "photoDescription.uploadAllowed") }
    }
}

extension PhotoSpeechRecognizer: PhotoRecognizing {}
