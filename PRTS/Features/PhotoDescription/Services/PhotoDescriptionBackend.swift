import Foundation
import LocalVLM

/// Selects the live model without coupling the interaction lifecycle to a provider.
nonisolated enum PhotoDescriptionBackend {
    static func describe(jpeg: Data, question: String?, request: PhotoDescriptionRequest)
        async throws
        -> String
    {
        let answer = try await generate(
            jpeg: jpeg,
            text: question ?? SceneDescriptionPrompt.request,
            request: request
        )
        return question == nil ? answer : PhotoPrompts.threeSentences(answer)
    }

    /// The selected model, then the bundled model, then the error of the bundled model.
    static func answer(
        request: PhotoDescriptionRequest,
        errors: ErrorReporter = ErrorReporter(source: .photoDescription),
        remote: @escaping @Sendable () async throws -> String,
        local: (String) async throws -> String
    ) async throws -> String {
        let configuration = request.configuration
        guard configuration.provider != .onDevice else {
            return try await local(configuration.localSystem)
        }
        do {
            let limit =
                configuration.thinking
                ? RequestDeadline.answerWithThinking
                : configuration.service?.answerDeadline ?? PhotoChatService.qwen.answerDeadline
            return try await RequestDeadline.run(limit, remote)
        } catch let error where !error.isCancellation {
            errors.record(error)
            return try await local(configuration.localSystem)
        }
    }

    private static func generate(
        jpeg: Data,
        text: String,
        request: PhotoDescriptionRequest
    ) async throws -> String {
        let configuration = request.configuration
        return try await answer(
            request: request,
            remote: {
                try await PhotoChatClient().describe(
                    jpeg: jpeg,
                    text: text,
                    key: request.key,
                    service: configuration.service,
                    system: configuration.system,
                    thinking: configuration.thinking
                )
            },
            local: { system in
                do {
                    let answer = try await PhotoLocalModel.shared.describe(
                        jpeg: jpeg,
                        prompt: text,
                        system: system,
                        maxTokens: 160
                    )
                    guard !answer.isEmpty else { throw PhotoChatError.emptyAnswer }
                    return answer
                } catch LocalVLM.Failure.outputLimit {
                    throw PhotoChatError.incompleteStream
                }
            }
        )
    }
}
