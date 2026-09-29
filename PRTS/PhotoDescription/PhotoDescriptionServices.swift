import Foundation

/// Narrow hardware boundaries: tests substitute deterministic input/output while
/// production always uses the native implementations. There is no in-app mock mode.
@MainActor
protocol PhotoRecognizing: AnyObject {
    func start() throws
    func endCapture()
    func finish() async throws -> String
    func cancel()
}

@MainActor
protocol PhotoAnswerAudio: AnyObject {
    var onFinished: (() -> Void)? { get set }
    func cue(_ cue: PhotoAudioOutput.Cue) throws
    func speak(_ text: String) throws
    func stop()
}

@MainActor
struct PhotoDescriptionServices {
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var uploadAllowed: () -> Bool = { UserDefaults.standard.bool(forKey: "photoDescription.uploadAllowed") }
    var credential: () throws -> String? = { try PhotoCredentialStore.read() }
    var speechAuthorized: () -> Bool = { PhotoSpeechRecognizer.authorized }
    var requestSpeechPermission: () async -> Bool = { await PhotoSpeechRecognizer.requestPermissions() }
    var describe: @Sendable (Data, String, String) async throws -> String = { jpeg, text, key in
        try await PhotoChatClient().describe(jpeg: jpeg, text: text, key: key)
    }
}

extension PhotoSpeechRecognizer: PhotoRecognizing {}
extension PhotoAudioOutput: PhotoAnswerAudio {}
