import Foundation

/// One action's settings stay together across image capture and speech recognition.
nonisolated struct PhotoDescriptionConfiguration: Sendable {
    let provider: PhotoChatProvider
    let service: PhotoChatService?
    let system: String
    /// Used when a cloud request fails, as the bundled model has its own prompts.
    let localSystem: String
    let thinking: Bool
    let uploadAllowed: Bool
    let highResolution: Bool
}

extension PhotoDescriptionConfiguration {
    init(feature: IntelligenceFeature, defaults: UserDefaults) throws {
        guard let provider = feature.provider(defaults) else { throw PhotoChatError.invalidService }
        self.provider = provider
        service = provider.service(defaults)
        let question = feature == .question
        localSystem = PhotoPrompts.localSystem(
            isQuestion: question,
            enhanced: defaults.bool(forKey: PhotoChatProvider.localEnhancedKey)
        )
        system =
            provider == .onDevice
            ? localSystem : (question ? PhotoPrompts.questionSystem : PhotoPrompts.system)
        thinking = question && provider.questionThinking(defaults)
        uploadAllowed = defaults.bool(forKey: "photoDescription.uploadAllowed")
        highResolution = defaults.bool(forKey: PhotoImagePurpose.highResolutionKey)
    }
}

nonisolated struct PhotoDescriptionRequest: Sendable {
    let configuration: PhotoDescriptionConfiguration
    let key: String
}

/// Replaceable time, configuration, permissions and description calls.
@MainActor
struct PhotoDescriptionServices {
    var errors = ErrorReporter(source: .photoDescription)
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var configuration: (IntelligenceFeature) throws -> PhotoDescriptionConfiguration
    var credential: (PhotoChatProvider) throws -> String?
    var speechAuthorized: () -> Bool = { PhotoSpeechRecognizer.authorized }
    var requestSpeechPermission: () async -> Bool = {
        await PhotoSpeechRecognizer.requestPermissions()
    }
    /// A nil question is a short tap: describe the scene. A spoken question gets its own prompt
    /// and at most three sentences back.
    var describe: @Sendable (Data, String?, PhotoDescriptionRequest) async throws -> String = {
        jpeg,
        question,
        request in
        try await PhotoDescriptionBackend.describe(jpeg: jpeg, question: question, request: request)
    }

    init(
        defaults: UserDefaults = .standard,
        readCredential: @escaping (String) throws -> String? = {
            try PhotoCredentialStore.read(account: $0)
        }
    ) {
        configuration = { try PhotoDescriptionConfiguration(feature: $0, defaults: defaults) }
        credential = { try readCredential($0.keyAccount) }
    }
}
