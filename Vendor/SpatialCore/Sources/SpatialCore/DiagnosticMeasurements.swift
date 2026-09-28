import Foundation

public struct DepthStatistics: Codable, Sendable {
    public var pixels = 0,finite = 0,nonFinite = 0,nonPositive = 0,outOfRange = 0,acceptedHighConfidence = 0
    public var low = 0,medium = 0,high = 0,unrecognizedConfidence = 0
    public var confidenceAvailable = false
    public var acceptedPredictionSupport: Int? = nil
    public var minimum: Float?,maximum: Float?,mean: Float?
    public init(_ o: DepthObservation,parameters p: ProbeParameters) {
        pixels = o.depth.count; confidenceAvailable = o.confidence != nil
        var total: Double = 0,count = 0
        for (i,d) in o.depth.enumerated() {
            if let confidence = o.confidence,i < confidence.count {
                switch confidence[i] { case 0: low += 1; case 1: medium += 1; case 2: high += 1; default: unrecognizedConfidence += 1 }
            }
            guard d.isFinite else { nonFinite += 1; continue }
            finite += 1
            if d <= 0 { nonPositive += 1 }
            if d < p.minDepth || d > p.maxDepth { outOfRange += 1 }
            if o.valid(i,parameters:p) {
                if o.isPrediction { acceptedPredictionSupport = (acceptedPredictionSupport ?? 0)+1 } else { acceptedHighConfidence += 1 }; total += Double(d); count += 1
                minimum = min(minimum ?? d,d); maximum = max(maximum ?? d,d)
            }
        }
        mean = count > 0 ? Float(total/Double(count)) : nil
    }
}
public struct AnalysisDiagnostics: Codable, Sendable {
    public var depthReadStatus = "not_read"
    public var confidenceReadStatus = "not_read"
    public var depth: DepthStatistics?
    public var sampledPoints = 0
    public var priorCount = 0
    public var groundConfirmationCount = 0
    public var groundConfirmationRequired = 3
    public var groundConfirmed = false
    public var planeOffsetDelta: Float?
    public var planeLocalHeightDelta: Float?
    public var planeNormalDeltaDegrees: Float?
    public var forwardGroundProjection: Float?
    // Optional for compatibility with build 3 recordings.
    public var groundReference: GroundReference?
    public var groundReferenceMode: String?
    public var groundReferenceAge: Double?
    public var groundReferenceInvalidation: String?
    public var geometryBasisMode: String?
    public var modelState = "not_evaluated"
    public var modelBlockReasons: [String] = []
    public init() {}
}
public struct DirectionDiagnostics: Codable, Sendable {
    public var reason = "not_evaluated"
    public var angularSpeedDegrees: Float?
    public var deltaTime: Double?
    public var horizontalProjection: Float = 0
    public var stableFor: Double = 0
    public init() {}
}
public enum DepthFrameCodec {
    /// A compressed-journal attachment stores this uncompressed container:
    /// UInt32 LE JSON-header length, header, Float32 LE depth rows, optional UInt8 confidence rows.
    /// Original NaN/Inf/invalid pixels are preserved exactly; RGB is never part of the format.
    public static func encode(_ o: DepthObservation,parameters: ProbeParameters,parameterVersion: UInt64,
                              priors: [FloorPrior],directionStable: Bool,source: String = "device") throws -> Data {
        struct Header: Encodable {
            let schemaVersion = 1
            let kind = "depth_frame"
            let width: Int,height: Int,depthBytes: Int,confidenceBytes: Int,predictionSupportBytes: Int
            let depthEvidence: String
            let epoch: UInt64,frameID: UInt64,timestamp: Double,parameterVersion: UInt64
            let pose: RigidPose,intrinsics: CameraIntrinsics
            let parameters: ProbeParameters,priors: [FloorPrior],directionStable: Bool,source: String
        }
        let h = Header(width:o.width,height:o.height,depthBytes:o.depth.count*4,confidenceBytes:o.confidence?.count ?? 0,predictionSupportBytes:o.predictionSupport?.count ?? 0,depthEvidence:o.isPrediction ? "model_prediction_arkit_aligned_not_sensor_confidence" : "arkit_scene_depth",
                       epoch:o.epoch,frameID:o.frameID,timestamp:o.timestamp,parameterVersion:parameterVersion,
                       pose:o.pose,intrinsics:o.intrinsics,parameters:parameters,priors:priors,directionStable:directionStable,source:source)
        let json = try DiagnosticJSON.encode(h)
        var length = UInt32(json.count).littleEndian
        var data = withUnsafeBytes(of:&length) { Data($0) }; data.append(json)
        for depth in o.depth { var bits = depth.bitPattern.littleEndian; withUnsafeBytes(of:&bits) { data.append(contentsOf:$0) } }
        if let confidence = o.confidence { data.append(contentsOf:confidence) }
        if let support = o.predictionSupport { data.append(contentsOf:support) }
        return data
    }
}
