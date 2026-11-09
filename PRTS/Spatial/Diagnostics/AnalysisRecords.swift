/// Per-frame analysis records written to DIAG `analysis.jsonl`.

import Foundation
import SpatialCore

// Value-only transport records must stay usable by the bounded background writer.
nonisolated struct MetricContext: Codable, Sendable {
    var captureFPS: Double
    var analysisFPS: Double
    var droppedFrames: Int
    var meshDrops: Int
    var captureMS: Double
    var meshMS: Double
    var render: RenderMetricRecord
    var tracking: String
    var thermal: String
    var sourceAgeMS: Double
    var outputEligible: Bool
    var displayedFrameID: UInt64
    var geometryOutputEligible: Bool? = nil
    var sensorSkew: String = "not_exposed_by_API"
}
nonisolated struct RenderMetricRecord: Codable, Sendable {
    var fps: Double
    var cpuMS: Double
    var gpuMS: Double
    var presentAgeMS: Double?
    var sourceDeltaMS: Double?
    init(_ m: RenderMetrics) {
        fps = m.fps
        cpuMS = m.cpuMS
        gpuMS = m.gpuMS
        presentAgeMS = m.presentAgeMS
        sourceDeltaMS = m.analysisDisplayDeltaMS
    }
}
nonisolated struct CompactGrid: Codable, Sendable {
    let columns: Int, rows: Int
    let cellSize: Float
    let halfWidth: Float
    let basis: GroundBasis
    let states: Data  // 0 unknown, 1 obstacle, 2 candidate; one row-major byte/cell, Base64 in JSON
    let reasons: [String]
    let reasonIndices: Data
    let footprint: Data
    let unknownFraction: Float
    init(_ g: LocalGrid, mask: [Bool]) {
        columns = g.columns
        rows = g.rows
        cellSize = g.cellSize
        halfWidth = g.halfWidth
        basis = g.basis
        states = Data(g.cells.map { $0.state == .unknown ? 0 : ($0.state == .obstacle ? 1 : 2) })
        reasons = Array(Set(g.cells.map { $0.reason.rawValue })).sorted()
        let lookup = Dictionary(
            uniqueKeysWithValues: reasons.enumerated().map { ($0.element, UInt8($0.offset)) }
        )
        reasonIndices = Data(g.cells.map { lookup[$0.reason.rawValue] ?? 0 })
        footprint = Data(mask.map { $0 ? 1 : 0 })
        unknownFraction = g.unknownFraction
    }
}
nonisolated struct FrameLog: Encodable, Sendable {
    let schemaVersion = 1
    let source: String, epoch: UInt64, frameID: UInt64, timestamp: Double, parameterVersion: UInt64
    let sourceDirectionStable: Bool
    let pose: RigidPose, intrinsics: CameraIntrinsics
    let parameters: ProbeParameters
    let plane: GroundPlane?
    let meshSources: [String]
    let grid: CompactGrid?
    let surfaceModel: SurfaceModelSummary?
    let distances: [ObstacleDistance], segments: [CandidateSegment]
    let status: String, validDepthCoverage: Float, unknownFraction: Float,
        stageMilliseconds: [String: Double]
    let metrics: MetricContext
    init(_ r: AnalysisResult, frame: FrameSnapshot, metrics: MetricContext) {
        source = r.source
        epoch = r.epoch
        frameID = r.frameID
        timestamp = r.timestamp
        parameterVersion = r.parameterVersion
        sourceDirectionStable = frame.directionStable
        pose = frame.pose
        intrinsics = frame.intrinsics
        parameters = r.parameters
        plane = r.plane
        meshSources = Array(
            Set(r.floorPriors.map { "\($0.anchorID)/\($0.revision)@\($0.callbackTime)" })
        ).sorted()
        surfaceModel = r.surfaceModel?.summary
        grid = r.grid.map { CompactGrid($0, mask: r.footprintMask) }
        distances = r.distances
        segments = r.segments
        status = r.status
        validDepthCoverage = r.validDepthCoverage
        unknownFraction = r.grid?.unknownFraction ?? 1
        stageMilliseconds = r.stageMilliseconds
        self.metrics = metrics
    }
}
