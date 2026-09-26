import Foundation

enum PRTSDepthQuality: Equatable { case unavailable, limited, good }
enum PRTSPathDirection: String, Codable { case left, straight, right }

struct PRTSBinaryMask {
    let width: Int
    let height: Int
    var values: [UInt8]
    init(width: Int, height: Int, values: [UInt8]? = nil) {
        precondition(width > 0 && height > 0)
        self.width = width; self.height = height
        self.values = values ?? Array(repeating: 0, count: width * height)
        precondition(self.values.count == width * height)
    }
    subscript(x: Int, y: Int) -> UInt8 { get { values[y * width + x] } set { values[y * width + x] = newValue } }
}

struct PRTSObjectDetection: Identifiable {
    let id = UUID()
    let classID: Int
    let label: String
    let score: Float
    let box: CGRect
    let mask: PRTSBinaryMask?
    let blocking: Bool
}

struct PRTSSemanticGrid {
    let width: Int
    let height: Int
    let classIDs: [UInt8]
    let walkProbability: [Float]
    let confidence: [Float]
    let walkable: PRTSBinaryMask
}

struct PRTSPerceptionObservation {
    let frameSequence: UInt64
    let timestamp: TimeInterval
    let semanticGrid: PRTSSemanticGrid
    let detections: [PRTSObjectDetection]
    let depthQuality: PRTSDepthQuality
    let processingSeconds: Double
}

struct PRTSObstacleObservation: Identifiable {
    let id = UUID()
    let label: String
    let distanceMeters: Float
    let azimuthRadians: Float
    let box: CGRect
    let score: Float
}

struct PRTSGuidancePath: Identifiable {
    let id = UUID()
    let points: [CGPoint]
    let clearance: Float
    let direction: PRTSPathDirection
}

struct PRTSPathBranch: Identifiable {
    let id = UUID()
    let direction: PRTSPathDirection
    let endpoint: CGPoint
}

struct PRTSNavigationObservation {
    let walkableMask: PRTSBinaryMask
    let paths: [PRTSGuidancePath]
    let branches: [PRTSPathBranch]
    let obstacles: [PRTSObstacleObservation]
    let nearestObstacle: PRTSObstacleObservation?
    let confidence: Float
    let processingSeconds: Double
}
