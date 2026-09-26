import Foundation
import CoreVideo

struct PRTSModelManifest: Codable, Equatable {
    let name: String
    let version: String
    let inputWidth: Int
    let inputHeight: Int
    let labels: [String]
    let sha256: String
}

@MainActor
final class PRTSPerceptionEngine: ObservableObject {
    enum State: Equatable { case unavailable(String), ready, processing, degraded(String) }
    @Published private(set) var state: State = .unavailable("Core ML model resources are not bundled")
    @Published private(set) var lastObservation: PRTSPerceptionObservation?

    private(set) var semanticEveryNFrames = 4
    private(set) var obstacleEveryNFrames = 2
    private var provider: (any PRTSPerceptionProvider)?
    private var lastSemantic: PRTSSemanticGrid?
    private var lastDetections: [PRTSObjectDetection] = []

    func configure(provider: any PRTSPerceptionProvider) {
        self.provider = provider
        state = .ready
    }

    func process(_ frame: PRTSARFrame) {
        guard let provider else { return }
        state = .processing
        let start = ProcessInfo.processInfo.systemUptime
        let semantic: PRTSSemanticGrid
        let detections: [PRTSObjectDetection]
        do {
            if frame.sequence % UInt64(semanticEveryNFrames) == 0 || lastSemantic == nil {
                lastSemantic = try provider.semanticGrid(from: frame.pixelBuffer)
            }
            if frame.sequence % UInt64(obstacleEveryNFrames) == 0 || lastDetections.isEmpty {
                lastDetections = try provider.detections(from: frame.pixelBuffer)
            }
            guard let lastSemantic else { throw PRTSPerceptionError.noSemanticResult }
            semantic = lastSemantic
            detections = lastDetections
            let quality: PRTSDepthQuality = frame.depthMap == nil ? .unavailable : .good
            lastObservation = PRTSPerceptionObservation(frameSequence: frame.sequence, timestamp: frame.timestamp, semanticGrid: semantic, detections: detections, depthQuality: quality, processingSeconds: ProcessInfo.processInfo.systemUptime - start)
            state = .ready
        } catch {
            state = .degraded(error.localizedDescription)
        }
    }
}

protocol PRTSPerceptionProvider {
    func semanticGrid(from pixelBuffer: CVPixelBuffer) throws -> PRTSSemanticGrid
    func detections(from pixelBuffer: CVPixelBuffer) throws -> [PRTSObjectDetection]
}

enum PRTSPerceptionError: LocalizedError {
    case noSemanticResult
    var errorDescription: String? { "Perception provider did not produce a semantic result" }
}

struct PRTSUnavailablePerceptionProvider: PRTSPerceptionProvider {
    func semanticGrid(from pixelBuffer: CVPixelBuffer) throws -> PRTSSemanticGrid { throw PRTSPerceptionError.noSemanticResult }
    func detections(from pixelBuffer: CVPixelBuffer) throws -> [PRTSObjectDetection] { [] }
}
