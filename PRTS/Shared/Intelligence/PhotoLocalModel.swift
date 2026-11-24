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

    static func unload() async { await shared.unload() }

    static func describe(
        jpeg: Data,
        prompt: String,
        system: String,
        maxTokens: Int = 160,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await DevInteractionRecording.recordLocalModelRequest(
            jpeg: jpeg,
            details: [
                "backend": "onDevice", "model": "MiniCPM-V-4_7-1B-Q5_K_M",
                "prompt": prompt, "system": system, "maxTokens": String(maxTokens),
            ],
            onText: onText
        ) { receive in
            try await shared.describe(
                jpeg: jpeg,
                prompt: prompt,
                system: system,
                maxTokens: maxTokens,
                onText: receive
            )
        }
    }

    static func ask(
        _ prompt: String,
        maxTokens: Int = 160,
        onText: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        try await DevInteractionRecording.recordLocalModelRequest(
            details: [
                "backend": "onDevice", "continuation": "true",
                "prompt": prompt, "maxTokens": String(maxTokens),
            ],
            onText: onText
        ) { receive in
            try await shared.ask(prompt, maxTokens: maxTokens, onText: receive)
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
