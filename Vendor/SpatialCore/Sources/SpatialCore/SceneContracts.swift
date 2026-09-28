import Foundation
import simd

/// Dimensions are recorded explicitly so downstream consumers never infer RGB/depth alignment.
public struct PixelDimensions: Codable, Sendable, Equatable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}

/// A short-lived reference to one ARKit frame. All timestamps use ARKit/process monotonic uptime seconds.
public struct SceneFrameReference: Codable, Sendable, Equatable, Identifiable {
    public var sessionEpoch: UInt64
    public var frameID: UInt64
    public var parameterVersion: UInt64
    public var arTimestamp: Double
    public var producedAt: Double
    public var validUntil: Double
    public var rgbDimensions: PixelDimensions
    public var depthDimensions: PixelDimensions?
    public var depthIntrinsics: CameraIntrinsics?
    public var cameraWorldPose: RigidPose
    public var id: String { "\(sessionEpoch)-\(frameID)" }

    public init(sessionEpoch: UInt64, frameID: UInt64, parameterVersion: UInt64, arTimestamp: Double, producedAt: Double,
                validUntil: Double, rgbDimensions: PixelDimensions, depthDimensions: PixelDimensions?,
                depthIntrinsics: CameraIntrinsics?, cameraWorldPose: RigidPose) {
        self.sessionEpoch = sessionEpoch; self.frameID = frameID; self.parameterVersion = parameterVersion; self.arTimestamp = arTimestamp
        self.producedAt = producedAt; self.validUntil = validUntil; self.rgbDimensions = rgbDimensions
        self.depthDimensions = depthDimensions; self.depthIntrinsics = depthIntrinsics
        self.cameraWorldPose = cameraWorldPose
    }
    public func isFresh(at now: Double) -> Bool { now >= producedAt && now <= validUntil }
}

public enum SceneTrackingStatus: String, Codable, Sendable {
    case normal, initializing, excessiveMotion, insufficientFeatures, relocalizing, unavailable, interrupted, stopped
}

public enum PerceptionAvailability: String, Codable, Sendable {
    case ready, worldTrackingUnsupported, depthUnsupported, meshClassificationUnsupported
    case trackingLimited, directionUnstable, depthMissing, confidenceMissing, groundUnconfirmed
    case thermalPaused, backgrounded, interrupted, stale, stopped, failed
}

public enum SemanticUnavailableReason: String, Codable, Sendable { case modelNotBundled }
public enum SemanticStatus: Codable, Sendable, Equatable {
    case ready
    case unavailable(SemanticUnavailableReason)
}

public struct ObjectDetection: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var label: String
    public var confidence: Float
    /// Normalized image rectangle, origin at top-left.
    public var x: Float; public var y: Float; public var width: Float; public var height: Float
    public var frameID: UInt64
    public var latencyMilliseconds: Double
    public init(id: String, label: String, confidence: Float, x: Float, y: Float, width: Float, height: Float,
                frameID: UInt64, latencyMilliseconds: Double) {
        self.id = id; self.label = label; self.confidence = confidence
        self.x = x; self.y = y; self.width = width; self.height = height
        self.frameID = frameID; self.latencyMilliseconds = latencyMilliseconds
    }
}

public struct SectorObservation: Codable, Sendable, Equatable, Identifiable {
    public var sector: Sector
    public var groundDistance: Float?
    public var supportedCells: Int
    public var sampleCount: Int
    public var id: Sector { sector }
    public init(sector: Sector, groundDistance: Float?, supportedCells: Int = 0, sampleCount: Int = 0) {
        self.sector = sector; self.groundDistance = groundDistance
        self.supportedCells = supportedCells; self.sampleCount = sampleCount
    }
}

public struct GridSummary: Codable, Sendable, Equatable {
    public var columns: Int; public var rows: Int; public var cellSize: Float; public var halfWidth: Float
    public var states: [CellState]
    public init(columns: Int, rows: Int, cellSize: Float, halfWidth: Float, states: [CellState]) {
        self.columns = columns; self.rows = rows; self.cellSize = cellSize; self.halfWidth = halfWidth; self.states = states
    }
    public init(_ grid: LocalGrid) {
        self.init(columns: grid.columns, rows: grid.rows, cellSize: grid.cellSize,
                  halfWidth: grid.halfWidth, states: grid.cells.map(\.state))
    }
}

public struct ObservedCandidateChannel: Codable, Sendable, Equatable, Identifiable {
    public var sector: Sector
    /// Camera-local ground coordinates: X right, Z forward, metres.
    public var centerline: [SIMD2<Float>]
    public var startDistance: Float
    public var length: Float
    public var minimumObservedWidth: Float
    public var id: String { "\(sector.rawValue)-\(startDistance)-\(length)" }
    public init(sector: Sector, centerline: [SIMD2<Float>], startDistance: Float, length: Float, minimumObservedWidth: Float) {
        self.sector = sector; self.centerline = centerline; self.startDistance = startDistance
        self.length = length; self.minimumObservedWidth = minimumObservedWidth
    }
}

/// The single accepted output consumed by the UI, audio/haptics, and future optional providers.
/// World coordinates are ARKit gravity-aligned. Candidate coordinates are camera-local ground X-right/Z-forward metres.
public struct SceneResult: Codable, Sendable, Identifiable {
    public var frame: SceneFrameReference
    public var tracking: SceneTrackingStatus
    public var availability: PerceptionAvailability
    public var statusMessage: String
    public var depthCoverage: Float
    public var observations: [SectorObservation]
    public var grid: GridSummary?
    public var candidateChannels: [ObservedCandidateChannel]
    public var semanticStatus: SemanticStatus
    public var detections: [ObjectDetection]
    public var analysisMilliseconds: Double
    public var id: String { frame.id }

    public init(frame: SceneFrameReference, tracking: SceneTrackingStatus, availability: PerceptionAvailability,
                statusMessage: String, depthCoverage: Float = 0, observations: [SectorObservation] = [],
                grid: GridSummary? = nil, candidateChannels: [ObservedCandidateChannel] = [],
                semanticStatus: SemanticStatus = .unavailable(.modelNotBundled), detections: [ObjectDetection] = [],
                analysisMilliseconds: Double = 0) {
        self.frame = frame; self.tracking = tracking; self.availability = availability
        self.statusMessage = statusMessage; self.depthCoverage = depthCoverage; self.observations = observations
        self.grid = grid; self.candidateChannels = candidateChannels; self.semanticStatus = semanticStatus
        self.detections = detections; self.analysisMilliseconds = analysisMilliseconds
    }
    public func isFresh(at now: Double) -> Bool { frame.isFresh(at: now) }
    public var producesGuidance: Bool { availability == .ready && !candidateChannels.isEmpty }
}

public protocol SceneResultConsumer: AnyObject, Sendable {
    func consume(sceneResult: SceneResult)
}


/// Accepts only fresh, in-order results from the active epoch and parameter version.
public struct SceneResultGate: Sendable {
    private var epoch: UInt64 = 0
    private var parameterVersion: UInt64 = 0
    private var lastFrameID: UInt64 = 0
    public init() {}
    public mutating func reset(epoch: UInt64, parameterVersion: UInt64) {
        self.epoch = epoch; self.parameterVersion = parameterVersion; lastFrameID = 0
    }
    public mutating func accept(_ result: SceneResult, now: Double) -> Bool {
        guard result.frame.sessionEpoch == epoch, result.frame.parameterVersion == parameterVersion,
              result.frame.frameID > lastFrameID, result.isFresh(at: now) else { return false }
        lastFrameID = result.frame.frameID
        return true
    }
}
