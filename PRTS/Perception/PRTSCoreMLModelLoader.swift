import Foundation
import CoreML

@MainActor
final class PRTSCoreMLModelLoader: ObservableObject {
    enum ComputeMode: String, CaseIterable, Identifiable {
        case all
        case cpuAndGPU
        case cpuOnly
        var id: String { rawValue }
        var computeUnits: MLComputeUnits {
            switch self {
            case .all: return .all
            case .cpuAndGPU: return .cpuAndGPU
            case .cpuOnly: return .cpuOnly
            }
        }
    }

    @Published private(set) var semanticModelLoaded = false
    @Published private(set) var obstacleModelLoaded = false
    @Published private(set) var lastError: String?

    private(set) var semanticModel: MLModel?
    private(set) var obstacleModel: MLModel?

    func load(semanticResource: String = "SegFormerB0", obstacleResource: String = "YOLO11nSeg", mode: ComputeMode = .all) {
        lastError = nil
        semanticModel = loadModel(resource: semanticResource, mode: mode)
        obstacleModel = loadModel(resource: obstacleResource, mode: mode)
        semanticModelLoaded = semanticModel != nil
        obstacleModelLoaded = obstacleModel != nil
        if !semanticModelLoaded || !obstacleModelLoaded {
            lastError = "Core ML model resources are not bundled"
        }
    }

    private func loadModel(resource: String, mode: ComputeMode) -> MLModel? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "mlmodelc") else { return nil }
        do {
            let configuration = MLModelConfiguration()
            configuration.computeUnits = mode.computeUnits
            return try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            lastError = "Failed to load \(resource): \(error.localizedDescription)"
            return nil
        }
    }
}
