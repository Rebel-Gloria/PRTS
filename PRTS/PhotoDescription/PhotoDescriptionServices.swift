import Foundation
import LocalVLM

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
    /// On device needs neither the upload permission nor a key.
    var onDevice: () -> Bool = { PhotoChatProvider.current() == .onDevice }
    var uploadAllowed: () -> Bool = { UserDefaults.standard.bool(forKey: "photoDescription.uploadAllowed") }
    var credential: () throws -> String? = { try PhotoCredentialStore.read(account: PhotoChatProvider.current().keyAccount) }
    var speechAuthorized: () -> Bool = { PhotoSpeechRecognizer.authorized }
    var requestSpeechPermission: () async -> Bool = { await PhotoSpeechRecognizer.requestPermissions() }
    var describe: @Sendable (Data, String, String) async throws -> String = { jpeg, text, key in
        let provider = PhotoChatProvider.current()
        guard provider == .onDevice else {
            return try await PhotoChatClient().describe(jpeg: jpeg, text: text, key: key, service: provider.service())
        }
        let answer = try await PhotoLocalModel.shared.describe(jpeg: jpeg, prompt: text, system: PhotoChatProtocol.system)
        guard !answer.isEmpty else { throw PhotoChatError.emptyAnswer }
        return answer
    }
}

extension PhotoSpeechRecognizer: PhotoRecognizing {}
extension PhotoAudioOutput: PhotoAnswerAudio {}
