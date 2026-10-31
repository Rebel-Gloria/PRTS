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
    /// A nil question is a short tap: describe the scene. A spoken question gets its own prompt
    /// and at most three sentences back.
    var describe: @Sendable (Data, String?, String) async throws -> String = { jpeg, question, key in
        let provider = PhotoChatProvider.current()
        let text = question ?? PhotoChatProtocol.prompt
        let answer: String
        if provider == .onDevice {
            answer = try await PhotoLocalModel.shared.describe(
                jpeg: jpeg, prompt: text, system: question == nil ? PhotoChatProtocol.system : PhotoChatProtocol.localQuestionSystem)
            guard !answer.isEmpty else { throw PhotoChatError.emptyAnswer }
        } else {
            answer = try await PhotoChatClient().describe(
                jpeg: jpeg, text: text, key: key, service: provider.service(),
                system: question == nil ? PhotoChatProtocol.system : PhotoChatProtocol.questionSystem,
                thinking: question != nil && UserDefaults.standard.bool(forKey: PhotoChatProtocol.questionThinkingKey))
        }
        return question == nil ? answer : PhotoChatProtocol.threeSentences(answer)
    }
}

extension PhotoSpeechRecognizer: PhotoRecognizing {}
extension PhotoAudioOutput: PhotoAnswerAudio {}
