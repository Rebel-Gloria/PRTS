import Foundation

@MainActor
struct PhotoDescriptionServices {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// On device needs neither the upload permission nor a key.
    var onDevice: () -> Bool = { PhotoChatProvider.current() == .onDevice }
    var uploadAllowed: () -> Bool = {
        UserDefaults.standard.bool(forKey: "photoDescription.uploadAllowed")
    }
    var highResolution: () -> Bool = {
        UserDefaults.standard.bool(forKey: PhotoImagePurpose.highResolutionKey)
    }
    var credential: () throws -> String? = {
        try PhotoCredentialStore.read(account: PhotoChatProvider.current().keyAccount)
    }
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
}

extension PhotoSpeechRecognizer: PhotoRecognizing {}
extension PhotoAudioOutput: PhotoAnswerAudio {}
