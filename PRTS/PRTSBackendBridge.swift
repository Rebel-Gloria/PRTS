import ARKit
import CoreVideo
import Foundation
import SpatialCore

protocol SceneRGBFrameProviding: AnyObject {
    /// Returns only the currently retained frame and only when epoch/frameID match exactly.
    func rgbFrame(matching reference: SceneFrameReference) -> DetectionFrame?
}

struct DetectionFrame: @unchecked Sendable {
    let reference: SceneFrameReference
    let pixelBuffer: CVPixelBuffer
}

enum ObstacleDetectorCapability: Sendable, Equatable {
    case available(modelName: String)
    case unavailable(SemanticUnavailableReason)
}

struct ObstacleDetectionResult: Sendable {
    let frame: SceneFrameReference
    let detections: [ObjectDetection]
    let latencyMilliseconds: Double
    let validUntil: Double
}

protocol ObstacleDetector: Sendable {
    var capability: ObstacleDetectorCapability { get }
    func detect(frame: DetectionFrame) async -> ObstacleDetectionResult
}

struct UnavailableObstacleDetector: ObstacleDetector {
    let capability: ObstacleDetectorCapability = .unavailable(.modelNotBundled)
    func detect(frame: DetectionFrame) async -> ObstacleDetectionResult {
        .init(frame: frame.reference, detections: [], latencyMilliseconds: 0, validUntil: frame.reference.validUntil)
    }
}

/// Compatibility output for optional future consumers: measured LiDAR results only.
/// Prediction geometry remains explicitly typed in SharedSnapshot.monocular; never relabel it measured.
enum SceneSnapshotAdapter {
    static func measuredResult(_ snapshot: SharedSnapshot,now: Double) -> SceneResult? {
        guard !snapshot.usesMonocular,let result = snapshot.activeGuidanceResult(now:now),
              let frame = snapshot.analyzedFrame,frame.id == result.frameID,frame.epoch == result.epoch,
              frame.parameterVersion == result.parameterVersion else { return nil }
        let depth = frame.frame.sceneDepth?.depthMap
        let dimensions = depth.map { PixelDimensions(width:CVPixelBufferGetWidth($0),height:CVPixelBufferGetHeight($0)) }
        let reference = SceneFrameReference(sessionEpoch:result.epoch,frameID:result.frameID,parameterVersion:result.parameterVersion,
            arTimestamp:result.timestamp,producedAt:now,validUntil:result.timestamp+snapshot.parameters.maxResultAge,
            rgbDimensions:.init(width:frame.intrinsics.width,height:frame.intrinsics.height),depthDimensions:dimensions,
            depthIntrinsics:dimensions.map { frame.intrinsics.scaled(width:$0.width,height:$0.height) },cameraWorldPose:frame.pose)
        return SceneResult(frame:reference,tracking:.normal,availability:.ready,statusMessage:result.status,
            depthCoverage:result.validDepthCoverage,observations:Sector.allCases.map { sector in
                .init(sector:sector,groundDistance:result.distances.first(where:{$0.sector == sector})?.groundDistance)
            },grid:result.grid.map(GridSummary.init),candidateChannels:[],
            analysisMilliseconds:result.stageMilliseconds["analysisTotal"] ?? 0)
    }
}
