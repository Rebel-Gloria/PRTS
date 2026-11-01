import Foundation
import LocalVLM

/// Selects the live model without coupling the interaction lifecycle to a provider.
nonisolated enum PhotoDescriptionBackend {
    static func describe(jpeg: Data, question: String?, key: String) async throws -> String {
        let provider = PhotoChatProvider.current()
        let text = question ?? PhotoPrompts.prompt
        let answer: String
        if provider == .onDevice {
            answer = try await PhotoLocalModel.shared.describe(
                jpeg: jpeg,
                prompt: text,
                system: PhotoPrompts.localSystem(question: question)
            )
            guard !answer.isEmpty else { throw PhotoChatError.emptyAnswer }
        } else {
            answer = try await PhotoChatClient().describe(
                jpeg: jpeg,
                text: text,
                key: key,
                service: provider.service(),
                system: question == nil ? PhotoPrompts.system : PhotoPrompts.questionSystem,
                thinking: question != nil
                    && UserDefaults.standard.bool(forKey: PhotoPrompts.questionThinkingKey)
            )
        }
        return question == nil ? answer : PhotoPrompts.threeSentences(answer)
    }
}
