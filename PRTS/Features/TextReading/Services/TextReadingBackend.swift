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

    /// The cloud provider chosen for text reading. With an OCR model (Qwen) its chat model
    /// says what the text is on while the OCR model copies it, both at once; otherwise one request
    /// asks for both.
    static func remote(jpeg: Data, key: String, service: PhotoChatService) async throws -> (
        TextReadingAnswer.Surface, String
    ) {
        guard let ocrModel = service.ocrModel else {
            return TextReadingAnswer.split(
                try await PhotoChatClient().describe(
                    jpeg: jpeg,
                    text: TextReadingPrompt.remotePrompt,
                    key: key,
                    service: service,
                    system: TextReadingPrompt.remoteSystem
                )
            )
        }
        let ocr = PhotoChatService(endpoint: service.endpoint, model: ocrModel, thinking: .standard)
        // The chat model (qwen3.8-flash) judges the surface. qwen-plus is cheaper but cannot see
        // images; qwen3-vl-plus is a little faster but costs more.
        async let surface = PhotoChatClient().describe(
            jpeg: jpeg,
            text: TextReadingPrompt.surfaceQuestion,
            key: key,
            service: service,
            system: nil
        )
        async let text = PhotoChatClient().describe(
            jpeg: jpeg,
            text: TextReadingPrompt.remotePrompt,
            key: key,
            service: ocr,
            system: TextReadingPrompt.ocrSystem
        )
        return (TextReadingAnswer.Surface(answer: try await surface), try await text)
    }
}
