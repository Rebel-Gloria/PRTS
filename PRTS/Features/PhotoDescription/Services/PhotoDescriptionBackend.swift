import Foundation
import LocalVLM

/// Selects the live model without coupling the interaction lifecycle to a provider.
nonisolated enum PhotoDescriptionBackend {
    static func describe(jpeg: Data, question: String?, key: String) async throws -> String {
        let provider = PhotoChatProvider.current()
        let answer = try await generate(
            jpeg: jpeg,
            text: question ?? PhotoPrompts.prompt,
            key: key,
            provider: provider,
            system: provider == .onDevice
                ? PhotoPrompts.localSystem(question: question)
                : (question == nil ? PhotoPrompts.system : PhotoPrompts.questionSystem),
            thinking: question != nil
                && UserDefaults.standard.bool(forKey: PhotoPrompts.questionThinkingKey)
        )
        return question == nil ? answer : PhotoPrompts.threeSentences(answer)
    }

    private static func generate(
        jpeg: Data,
        text: String,
        key: String,
        provider: PhotoChatProvider,
        system: String,
        thinking: Bool
    ) async throws -> String {
        if provider == .onDevice {
            let answer = try await PhotoLocalModel.shared.describe(
                jpeg: jpeg,
                prompt: text,
                system: system,
                maxTokens: 160
            )
            guard !answer.isEmpty else { throw PhotoChatError.emptyAnswer }
            return answer
        }
        return try await PhotoChatClient().describe(
            jpeg: jpeg,
            text: text,
            key: key,
            service: provider.service(),
            system: system,
            thinking: thinking
        )
    }
}
