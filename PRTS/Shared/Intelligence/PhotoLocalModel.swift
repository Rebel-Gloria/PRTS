import Foundation
import LocalVLM

/// The bundled MiniCPM-V 4.7 1B (docs/vision.md). The "Copy offline model" build
/// phase puts both weight files in the app's LocalVLM folder.
nonisolated enum PhotoLocalModel {
    static let shared = LocalVLM(
        model: Bundle.main.url(
            forResource: "MiniCPM-V-4_7-1B-Q5_K_M",
            withExtension: "gguf",
            subdirectory: "LocalVLM"
        )!,
        mmproj: Bundle.main.url(
            forResource: "mmproj-model-f16",
            withExtension: "gguf",
            subdirectory: "LocalVLM"
        )!
    )

    static func describe(
        jpeg: Data,
        prompt: String,
        system: String,
        maxTokens: Int = 160,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        #if PRTS_DEV
        let id = UUID().uuidString
        let generation =
            DevInteractionRecording.recordingGeneration ?? RecordingStore.shared.admissionGeneration
        RecordingStore.shared.event(
            "model_request_started",
            details: [
                "requestID": id, "backend": "onDevice", "model": "MiniCPM-V-4_7-1B-Q5_K_M",
                "prompt": prompt, "system": system, "maxTokens": String(maxTokens),
                "interactionID": DevInteractionRecording.interactionID ?? "unavailable",
            ],
            generation: generation
        )
        RecordingStore.shared.attachment(
            data: jpeg,
            kind: "model_input",
            fileExtension: "jpg",
            metadata: ["requestID": id],
            generation: generation
        )
        let receive: (@Sendable (String) -> Void)? = { piece in
            RecordingStore.shared.event(
                "model_response_delta",
                details: ["requestID": id, "text": piece],
                generation: generation
            )
            onText?(piece)
        }
        #else
        let receive = onText
        #endif
        do {
            let answer = try await shared.describe(
                jpeg: jpeg,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens,
                onText: receive
            )
            #if PRTS_DEV
            RecordingStore.shared.event(
                "model_request_completed",
                details: ["requestID": id, "answer": answer],
                generation: generation
            )
            #endif
            return answer
        } catch {
            #if PRTS_DEV
            DevInteractionRecording.failure(
                error,
                feature: "onDevice_model",
                id: id,
                generation: generation
            )
            #endif
            throw error
        }
    }

    static func ask(
        _ prompt: String,
        maxTokens: Int = 160,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        #if PRTS_DEV
        let id = UUID().uuidString
        let generation =
            DevInteractionRecording.recordingGeneration ?? RecordingStore.shared.admissionGeneration
        RecordingStore.shared.event(
            "model_request_started",
            details: [
                "requestID": id, "backend": "onDevice", "continuation": "true",
                "prompt": prompt, "maxTokens": String(maxTokens),
                "interactionID": DevInteractionRecording.interactionID ?? "unavailable",
            ],
            generation: generation
        )
        let receive: (@Sendable (String) -> Void)? = { piece in
            RecordingStore.shared.event(
                "model_response_delta",
                details: ["requestID": id, "text": piece],
                generation: generation
            )
            onText?(piece)
        }
        #else
        let receive = onText
        #endif
        do {
            let answer = try await shared.ask(prompt, maxTokens: maxTokens, onText: receive)
            #if PRTS_DEV
            RecordingStore.shared.event(
                "model_request_completed",
                details: ["requestID": id, "answer": answer],
                generation: generation
            )
            #endif
            return answer
        } catch {
            #if PRTS_DEV
            DevInteractionRecording.failure(
                error,
                feature: "onDevice_model",
                id: id,
                generation: generation
            )
            #endif
            throw error
        }
    }
}

extension LocalVLM.Failure: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .loadFailed: AppLocalization.interfaceString("photo.error.localModel.loadFailed")
        case .badImage: AppLocalization.interfaceString("photo.error.localModel.badImage")
        case .evalFailed, .outputLimit:
            AppLocalization.interfaceString("photo.error.localModel.failed")
        }
    }
}
