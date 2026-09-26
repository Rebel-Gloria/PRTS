import Foundation

struct PRTSPerceptionObservation {
    let frameSequence: UInt64
    let timestamp: TimeInterval
    let semanticGrid: PRTSSemanticGrid
    let detections: [PRTSObjectDetection]
    let depthQuality: PRTSDepthQuality
    let processingSeconds: Double
}
