import Foundation
import LocalVLM
import os

nonisolated enum TextReadingBackend {
    /// First question: looks at the photo (the slow part, about 1.3 s) and says what the text is on.
    /// The budget only fits one word. A longer answer is judged by what arrived, because this
    /// step only labels the text and must not fail the reader that copies it.
    static func surface(of jpeg: Data, maxTokens: Int = 8) async throws -> TextReadingAnswer.Surface
    {
        let received = OSAllocatedUnfairLock(initialState: "")
        do {
            return TextReadingAnswer.Surface(
                answer: try await PhotoLocalModel.shared.describe(
                    jpeg: jpeg,
                    prompt: TextReadingPrompt.surfaceQuestion,
                    system: TextReadingPrompt.system,
                    maxTokens: maxTokens,
                    onText: { piece in received.withLock { $0 += piece } }
                )
            )
        } catch LocalVLM.Failure.outputLimit {
            return TextReadingAnswer.Surface(answer: received.withLock { $0 })
        }
    }

    /// Second question about the photo `surface(of:)` just looked at; the copy streams into `onText`.
    static func copy(onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try await PhotoLocalModel.shared.ask(
            TextReadingPrompt.copyQuestion,
            maxTokens: TextReadingPrompt.maxTokens,
            onText: onText
        )
    }

    /// The cloud provider chosen for text reading: one request says what the text is on and copies it.
    static func remote(jpeg: Data, key: String, service: PhotoChatService) async throws -> (
        TextReadingAnswer.Surface, String
    ) {
        TextReadingAnswer.split(
            try await PhotoChatClient().describe(
                jpeg: jpeg,
                text: TextReadingPrompt.remotePrompt,
                key: key,
                service: service,
                system: TextReadingPrompt.remoteSystem
            )
        )
    }
}
