import Foundation
import simd

public struct AnalysisResult: Codable, Sendable {
    public var epoch: UInt64
    public var frameID: UInt64
    public var timestamp: Double
    public var parameters: ProbeParameters
    public var parameterVersion: UInt64
    public var sourcePose: RigidPose?
    public var plane: GroundPlane?
    public var grid: LocalGrid?
    public var surfaceModel: SurfaceModel?
    public var footprintMask: [Bool]
    public var distances: [ObstacleDistance]
    public var segments: [CandidateSegment]
    public var validDepthCoverage: Float
    public var status: String
    public var stageMilliseconds: [String:Double]
    public var source: String
    /// Nil in older recordings; never authorizes heading-dependent guidance.
    public var diagnostics: AnalysisDiagnostics?
    public var sourceDirectionStable: Bool?
    public var floorPriors: [FloorPrior]
    public init(epoch: UInt64, frameID: UInt64, timestamp: Double, parameters: ProbeParameters, parameterVersion: UInt64 = 0, status: String, source: String = "device") {
        self.epoch = epoch; self.frameID = frameID; self.timestamp = timestamp; self.parameters = parameters
        self.parameterVersion = parameterVersion; self.status = status; self.source = source
        footprintMask = []; distances = []; segments = []; validDepthCoverage = 0; stageMilliseconds = [:]; floorPriors = []
    }
}

/// Owned exclusively by the serial analysis worker. No cross-frame occupancy/free-space accumulation.
public final class SpatialAnalyzer {
    private var previousPlane: GroundPlane?
    private var previousTime: Double = 0
    private var epoch: UInt64 = 0
    private var version: UInt64 = 0
    private var groundTracker = GroundReferenceTracker()
    private var previousForward: V3?
    public init() {}
    public func reset() { previousPlane = nil; previousTime = 0; groundTracker.reset(); previousForward = nil }
    public func missingDepth(pose: RigidPose,time: Double,frameID: UInt64,epoch: UInt64,parameterVersion: UInt64) {
        if self.epoch != epoch || version != parameterVersion { reset(); self.epoch = epoch; version = parameterVersion }
        _ = groundTracker.update(fitted:nil,pose:pose,time:time,frameID:frameID,epoch:epoch,parameterVersion:parameterVersion)
        previousPlane = nil; previousTime = 0
    }
    public func analyze(_ observation: DepthObservation, priors: [FloorPrior], parameters raw: ProbeParameters,
                        parameterVersion: UInt64, directionStable: Bool, source: String = "device") -> AnalysisResult {
        let p = raw.validated()
        if epoch != observation.epoch || version != parameterVersion { reset(); epoch = observation.epoch; version = parameterVersion }
        var result = AnalysisResult(epoch:observation.epoch,frameID:observation.frameID,timestamp:observation.timestamp,parameters:p,
                                    parameterVersion:parameterVersion,status:"未知：等待有效深度",source:source)
        result.sourceDirectionStable = directionStable
        result.sourcePose = observation.pose
        result.floorPriors = priors
        var diagnostics = AnalysisDiagnostics()
        diagnostics.priorCount = priors.count
        let diagnosticsStart = ProcessInfo.processInfo.systemUptime
        diagnostics.depth = DepthStatistics(observation,parameters:p)
        diagnostics.depthReadStatus = "available"
        diagnostics.confidenceReadStatus = observation.confidence == nil ? "missing" : "available"
        result.diagnostics = diagnostics
        result.stageMilliseconds["diagnostics"] = (ProcessInfo.processInfo.systemUptime-diagnosticsStart)*1000
        let start = ProcessInfo.processInfo.systemUptime
        guard observation.structurallyValid, observation.confidence != nil else {
            _ = groundTracker.update(fitted:nil,pose:observation.pose,time:observation.timestamp,frameID:observation.frameID,
                                     epoch:observation.epoch,parameterVersion:parameterVersion)
            previousPlane = nil; previousTime = 0
            result.status = "未知：深度或置信度缺失"; result.diagnostics?.modelBlockReasons = ["invalid_depth_or_missing_confidence"]
            result.diagnostics?.modelState = "blocked"; return result
        }
        let points = observation.points(parameters:p)
        result.validDepthCoverage = observation.coverage(parameters:p)
        result.diagnostics?.sampledPoints = points.count
        let afterDepth = ProcessInfo.processInfo.systemUptime
        result.stageMilliseconds["depth"] = (afterDepth-start)*1000
        let fitStart = ProcessInfo.processInfo.systemUptime
        let fitted = GroundEstimator.fit(points:points,priors:priors,camera:observation.pose.position,parameters:p)
        result.stageMilliseconds["groundFit"] = (ProcessInfo.processInfo.systemUptime-fitStart)*1000
        if let fitted,let old = previousPlane {
            result.diagnostics?.planeOffsetDelta = abs(old.offset-fitted.offset)
            result.diagnostics?.planeLocalHeightDelta = abs(old.height(observation.pose.position)-fitted.height(observation.pose.position))
            result.diagnostics?.planeNormalDeltaDegrees = acos(min(1,max(-1,simd_dot(old.normal,fitted.normal)))) * 180 / .pi
        }
        previousPlane = fitted; previousTime = observation.timestamp
        let selection = groundTracker.update(fitted:fitted,pose:observation.pose,time:observation.timestamp,
            frameID:observation.frameID,epoch:observation.epoch,parameterVersion:parameterVersion)
        result.diagnostics?.groundConfirmationCount = selection.confirmations
        result.diagnostics?.groundConfirmed = selection.currentConfirmed
        result.diagnostics?.groundReference = selection.reference
        result.diagnostics?.groundReferenceMode = selection.currentConfirmed ? "current_confirmed" : selection.reference != nil ? "retained_world_reference" : "unconfirmed"
        result.diagnostics?.groundReferenceAge = selection.reference.map { observation.timestamp-$0.observedAt }
        result.diagnostics?.groundReferenceInvalidation = selection.invalidation
        if !selection.currentConfirmed {
            if fitted == nil { result.diagnostics?.modelBlockReasons.append("ground_fit_failed") }
            if let fitted {
                if !fitted.floorPriorConfirmed { result.diagnostics?.modelBlockReasons.append("floor_prior_unconfirmed") }
                result.diagnostics?.modelBlockReasons.append("ground_confirmation_pending")
            }
        }
        guard !points.isEmpty else {
            result.diagnostics?.modelState = "blocked"; result.status = "未知：无高置信度深度；没有新的表面证据"
            return result
        }
        // A retained reference labels CURRENT depth only. It never fabricates an infinite blue plane.
        guard let plane = selection.reference?.plane ?? fitted else {
            result.diagnostics?.modelState = "blocked"; result.status = "未知：未建立可靠地面，近期参考也不可用"
            result.stageMilliseconds["groundGrid"] = (ProcessInfo.processInfo.systemUptime-afterDepth)*1000; return result
        }
        result.plane = plane
        let forward = -observation.pose.back
        let projection = simd_length(forward-plane.normal*simd_dot(forward,plane.normal))
        result.diagnostics?.forwardGroundProjection = projection
        let directionalBasis = GroundBasis(plane:plane,pose:observation.pose)
        guard let basis = GroundBasis.geometry(plane:plane,pose:observation.pose,previousForward:previousForward) else {
            result.diagnostics?.modelState = "blocked"; result.diagnostics?.modelBlockReasons.append("invalid_geometry_basis")
            result.status = "未知：地面坐标不可用"; return result
        }
        result.diagnostics?.geometryBasisMode = projection >= 0.1 ? "camera_ground_projection" : "world_tangent_geometry_only"
        if projection >= 0.1 { previousForward = basis.forward }
        let confirmedGround = selection.currentConfirmed && directionalBasis != nil
        if directionalBasis == nil { result.diagnostics?.modelBlockReasons.append("guidance_reference_vertical") }
        let gridStart = ProcessInfo.processInfo.systemUptime
        var grid = GridBuilder.build(points:points,observation:observation,plane:plane,basis:basis,parameters:p,evaluateClearance:confirmedGround)
        result.stageMilliseconds["gridClearance"] = (ProcessInfo.processInfo.systemUptime-gridStart)*1000
        if !confirmedGround {
            for i in grid.cells.indices where grid.cells[i].state == .candidate {
                grid.cells[i].state = .unknown; grid.cells[i].reason = .groundUnconfirmed
            }
        }
        result.grid = grid
        let afterGrid = ProcessInfo.processInfo.systemUptime
        result.stageMilliseconds["groundGrid"] = (afterGrid-afterDepth)*1000
        result.distances = confirmedGround && directionStable ? ChannelPlanner.distances(grid:grid) : []
        if directionStable && confirmedGround {
            result.footprintMask = GridBuilder.footprintMask(grid:grid,radius:p.requiredWidth/2)
            result.segments = ChannelPlanner.segments(grid:grid,mask:result.footprintMask)
            result.status = result.segments.isEmpty ? "无候选通道：观测或净空证据不足" : "仅显示观测区候选段；近身未知不连接"
        } else {
            result.footprintMask = Array(repeating:false,count:grid.cells.count)
            result.status = !selection.currentConfirmed && selection.reference != nil
                ? "近期地面参考＋当前深度建模；通道未知，等待地面重新确认"
                : (!directionStable || directionalBasis == nil ? "方向变化：几何继续更新，通道及方向距离暂停" : "未知：地面待确认（需 floor 先验与连续深度支持）")
        }
        result.stageMilliseconds["channel"] = (ProcessInfo.processInfo.systemUptime-afterGrid)*1000
        let modelStart = ProcessInfo.processInfo.systemUptime
        // Current-depth geometry is world-anchored, not a heading-dependent navigation instruction.
        // Keep modeling during tracked motion; confidence and confirmed-ground checks remain in the builder.
        result.surfaceModel = SurfaceModelBuilder.build(observation:observation,plane:plane,grid:grid,
            groundConfirmed:selection.reference != nil,parameters:p)
        result.diagnostics?.modelState = result.surfaceModel == nil ? "blocked" : (result.surfaceModel?.triangles.isEmpty == true ? "built_empty" : "built")
        result.stageMilliseconds["surfaceModel"] = (ProcessInfo.processInfo.systemUptime-modelStart)*1000
        result.stageMilliseconds["analysisTotal"] = (ProcessInfo.processInfo.systemUptime-start)*1000
        return result
    }
}

/// At most one in-flight value plus one replaceable pending value. Lock protects all mutable state.
public final class LatestMailbox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: Value?
    private var running = false
    private var replacedCount = 0
    public init() {}
    /// Returns true only when the caller must schedule the worker.
    public func submit(_ value: Value) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if pending != nil { replacedCount += 1 }
        pending = value
        if running { return false }
        running = true; return true
    }
    public func next() -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard let value = pending else { running = false; return nil }
        pending = nil; return value
    }
    public func discardPending(resetDropCount: Bool = false) { lock.lock(); pending = nil; if resetDropCount { replacedCount = 0 }; lock.unlock() }
    public var dropped: Int { lock.lock(); defer { lock.unlock() }; return replacedCount }
}
