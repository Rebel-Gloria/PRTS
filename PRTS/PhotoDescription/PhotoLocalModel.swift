import Foundation
import LocalVLM

/// The bundled MiniCPM-V 4.7 1B (docs/features/local-vlm.md). The "Copy offline model" build
/// phase puts both weight files in the app's LocalVLM folder.
enum PhotoLocalModel {
    static let shared = LocalVLM(
        model: Bundle.main.url(forResource: "MiniCPM-V-4_7-1B-Q5_K_M", withExtension: "gguf", subdirectory: "LocalVLM")!,
        mmproj: Bundle.main.url(forResource: "mmproj-model-f16", withExtension: "gguf", subdirectory: "LocalVLM")!)
}

extension LocalVLM.Failure: @retroactive LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .loadFailed: "本机模型没能加载"
        case .badImage: "本机模型读不了这张照片"
        case .evalFailed: "本机模型出错，请重试"
        }
    }
}
