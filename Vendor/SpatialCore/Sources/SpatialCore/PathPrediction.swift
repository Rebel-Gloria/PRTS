import Foundation
import simd

/// Experimental geometric line, NOT a free-space/safe-route certificate. Never promotes LocalGrid cells.
public struct PathOptions: Codable, Sendable, Equatable {
    public var enabled = true
    public var haptics = true
    public var deviationDegrees: Float = 12
    public var retentionSeconds: Double = 2
    public var lookAhead: Float = 0.8
    public var minimumWidth: Float = 0.5 // TOTAL planning envelope; do not add bodyWidth/margin twice.
    public var targetHalfAngleDegrees: Float = 45
    public var arrivalRadius: Float = 0.35
    public var alignmentDegrees: Float = 5
    public var obstacleTriggerDistance: Float = 1
    public var obstacleTriggerWidth: Float = 0.5 // Full width at the far edge; apex at the foot projection.
    public var smallObstacleWidth: Float = 0.5
    public var userTurnDegrees: Float = 45
    public var userTurnSeconds: Double = 3
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled,haptics,deviationDegrees,retentionSeconds,lookAhead,minimumWidth,targetHalfAngleDegrees,arrivalRadius,alignmentDegrees,obstacleTriggerDistance,obstacleTriggerWidth,smallObstacleWidth,userTurnDegrees,userTurnSeconds }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? true
        haptics = try c.decodeIfPresent(Bool.self,forKey:.haptics) ?? true
        deviationDegrees = try c.decodeIfPresent(Float.self,forKey:.deviationDegrees) ?? 12
        retentionSeconds = try c.decodeIfPresent(Double.self,forKey:.retentionSeconds) ?? 2
        lookAhead = try c.decodeIfPresent(Float.self,forKey:.lookAhead) ?? 0.8
        minimumWidth = try c.decodeIfPresent(Float.self,forKey:.minimumWidth) ?? 0.5
        targetHalfAngleDegrees = try c.decodeIfPresent(Float.self,forKey:.targetHalfAngleDegrees) ?? 45
        arrivalRadius = try c.decodeIfPresent(Float.self,forKey:.arrivalRadius) ?? 0.35
        alignmentDegrees = try c.decodeIfPresent(Float.self,forKey:.alignmentDegrees) ?? 5
        obstacleTriggerDistance = try c.decodeIfPresent(Float.self,forKey:.obstacleTriggerDistance) ?? 1
        obstacleTriggerWidth = try c.decodeIfPresent(Float.self,forKey:.obstacleTriggerWidth) ?? 0.5
        smallObstacleWidth = try c.decodeIfPresent(Float.self,forKey:.smallObstacleWidth) ?? 0.5
        userTurnDegrees = try c.decodeIfPresent(Float.self,forKey:.userTurnDegrees) ?? 45
        userTurnSeconds = try c.decodeIfPresent(Double.self,forKey:.userTurnSeconds) ?? 3
    }
    public func validated() -> Self {
        var v = self
        v.deviationDegrees = deviationDegrees.isFinite ? min(30,max(6,deviationDegrees)) : 12
        v.retentionSeconds = retentionSeconds.isFinite ? min(5,max(0.5,retentionSeconds)) : 2
        v.lookAhead = lookAhead.isFinite ? min(1.5,max(0.4,lookAhead)) : 0.8
        v.minimumWidth = minimumWidth.isFinite ? min(1.2,max(0.5,minimumWidth)) : 0.5
        v.targetHalfAngleDegrees = targetHalfAngleDegrees.isFinite ? min(75,max(15,targetHalfAngleDegrees)) : 45
        v.arrivalRadius = arrivalRadius.isFinite ? min(0.75,max(0.2,arrivalRadius)) : 0.35
        v.alignmentDegrees = alignmentDegrees.isFinite ? min(v.deviationDegrees-2,max(2,alignmentDegrees)) : min(5,v.deviationDegrees-2)
        v.obstacleTriggerDistance = obstacleTriggerDistance.isFinite ? min(2,max(0.5,obstacleTriggerDistance)) : 1
        v.obstacleTriggerWidth = obstacleTriggerWidth.isFinite ? min(1,max(0.3,obstacleTriggerWidth)) : 0.5
        v.smallObstacleWidth = smallObstacleWidth.isFinite ? min(1,max(0.2,smallObstacleWidth)) : 0.5
        v.userTurnDegrees = userTurnDegrees.isFinite ? min(90,max(30,userTurnDegrees)) : 45
        v.userTurnSeconds = userTurnSeconds.isFinite ? min(6,max(3,userTurnSeconds)) : 3
        return v
    }
}
public struct PredictedPath: Codable, Sendable {
    public var id: UInt64
    public var epoch: UInt64
    public var parameterVersion: UInt64
    public var sourceFrameID: UInt64
    public var validatedFrameID: UInt64
    public var observedAt: Double
    public var plane: GroundPlane
    public var points: [V3]
    public var source: String
    public var requiredWidth: Float
    public var forwardStrategy: Bool? = nil // New routes retain world intent across camera turns.
    public var footAtPlan: V3? = nil
    public var targetRange: Float? = nil
    public var length: Float { zip(points,points.dropFirst()).reduce(0) { $0+simd_distance($1.0,$1.1) } }
}
/// Goal identity/world position are independent of route evidence freshness.
/// Retaining this intent does NOT authorize rendering an expired route or haptic guidance.
public struct FixedPathGoal: Codable, Sendable {
    public var id: UInt64
    public var epoch: UInt64
    public var point: V3
    public var plane: GroundPlane
    public var selectedAt: Double
    public var maxDistance: Float
}
public struct PathUpdate: Codable, Sendable {
    public var projection: RouteProjection? = nil
    public var occupancyFilter: OccupancyFilterDiagnostics? = nil
    public var path: PredictedPath?
    public var reason: String
    public var blueCells: Int
    public var eligibleCells: Int
    public var milliseconds: Double
    public var strategy: ForwardStrategyDiagnostics? = nil
    public var goal: FixedPathGoal? = nil
    public var goalChangeReason: String? = nil
    public var reachableCells: Int? = nil
    public var targetBearingDegrees: Float? = nil
    public var targetGroundDistance: Float? = nil
    public var approachDistance: Float? = nil
    public init(path: PredictedPath? = nil,reason: String = "waiting_blue_ground",blueCells: Int = 0,eligibleCells: Int = 0,milliseconds: Double = 0) {
        self.path = path; self.reason = reason; self.blueCells = blueCells; self.eligibleCells = eligibleCells; self.milliseconds = milliseconds
    }
}
public struct PathPresentation: Sendable {
    public var path: PredictedPath
    public var age: Double
    public var historical: Bool
    public var approach: [V3] = [] // Visual-only feet projection to observed path entry. Unknown is explicit.
    public static func make(path: PredictedPath,gate: ResultPresentationGate,pose: RigidPose,options: PathOptions,now: Double) -> Self? {
        guard options.enabled,gate.enabled,gate.trackingNormal,
              path.epoch == gate.epoch,path.parameterVersion == gate.parameterVersion,
              path.sourceFrameID >= gate.minimumGeometryFrameID,path.validatedFrameID <= gate.frameID,
              now.isFinite,now >= gate.frameTimestamp,now-gate.frameTimestamp <= gate.maxAge,
              now >= path.observedAt,now-path.observedAt <= options.validated().retentionSeconds,
              abs(path.requiredWidth-options.validated().minimumWidth) < 0.001,path.points.count >= 2 else { return nil }
        if let goal = path.points.last {
            let distance = simd_distance(path.plane.project(pose.position),goal)
            guard distance > options.validated().arrivalRadius,distance <= (path.targetRange ?? 4)+0.2 else { return nil }
            if path.forwardStrategy != true,let basis = GroundBasis(plane:path.plane,pose:pose) {
                let p = basis.local(goal)
                guard abs(atan2(p.x,p.z)*180 / .pi) <= options.validated().targetHalfAngleDegrees+5 else { return nil }
            }
        }
        // Drawing a world line must NOT depend on a reliable phone heading. Near-vertical
        // pitch pauses haptics, but visible parts still reproject correctly while tracked.
        let points = PathTracking.remaining(path.points,plane:path.plane,pose:pose)
        guard points.count >= 2 else { return nil }
        let origin = path.plane.project(pose.position),tangent = simd_normalize(points[1]-points[0])
        let lateral = abs(simd_dot(origin-points[0],simd_cross(tangent,path.plane.normal)))
        guard lateral.isFinite,lateral <= 1.0,simd_distance(origin,points[0]) <= 5 else { return nil }
        var visiblePath = path;visiblePath.points = points
        return .init(path:visiblePath,age:now-path.observedAt,historical:now-path.observedAt > gate.maxAge,
                     approach:simd_distance(origin,points[0]) > 0.03 ? [origin,points[0]] : [])
    }
}

/// Rasterizes the actual BLUE triangles, not the infinite plane. Nine subcell tests must ALL be
/// supported. Unknown holes and red projections remain closed, including diagonal corner gaps.
public struct BluePathGrid: Sendable {
    public var grid: LocalGrid
    public var mask: [Bool]
    public var blueCells: Int
    public var requiredWidth: Float
    public var halfAngle: Float
    public var maxDistance: Float
    public init?(result: AnalysisResult,options: PathOptions = .init()) {
        guard var grid = result.grid,let model = result.surfaceModel else { return nil }
        grid.cells = Array(repeating:GridCell(),count:grid.cells.count)
        var coverage = Array(repeating:UInt16(0),count:grid.cells.count)
        let offsets: [Float] = [-0.4,0,0.4]
        for t in model.triangles where t.surface == .ground {
            let vertices = [t.a,t.b,t.c].map { grid.basis.local($0) }
            guard vertices.allSatisfy({ $0.x.isFinite && $0.z.isFinite }) else { continue }
            let a = SIMD2(vertices[0].x,vertices[0].z),b = SIMD2(vertices[1].x,vertices[1].z),c = SIMD2(vertices[2].x,vertices[2].z)
            let cross: (SIMD2<Float>,SIMD2<Float>) -> Float = { $0.x*$1.y-$0.y*$1.x }
            let area = cross(b-a,c-a); guard abs(area) > 0.0000001 else { continue }
            let minX = max(0,Int(floor((min(a.x,b.x,c.x)+grid.halfWidth)/grid.cellSize)))
            let maxX = min(grid.columns-1,Int(floor((max(a.x,b.x,c.x)+grid.halfWidth)/grid.cellSize)))
            let minZ = max(0,Int(floor(min(a.y,b.y,c.y)/grid.cellSize)))
            let maxZ = min(grid.rows-1,Int(floor(max(a.y,b.y,c.y)/grid.cellSize)))
            guard minX <= maxX,minZ <= maxZ else { continue }
            for z in minZ...maxZ { for x in minX...maxX {
                let i = z*grid.columns+x,center = grid.center(i)
                if coverage[i] == 511 { continue }
                for (zz,dz) in offsets.enumerated() { for (xx,dx) in offsets.enumerated() {
                    let bit = UInt16(1 << (zz*3+xx)); if coverage[i]&bit != 0 { continue }
                    let p = center+SIMD2(dx,dz)*grid.cellSize
                    let u = cross(b-p,c-p)/area,v = cross(c-p,a-p)/area,w = 1-u-v
                    if min(u,v,w) >= -0.00001 { coverage[i] |= bit }
                }}
            }}
        }
        var count = 0
        for i in grid.cells.indices {
            let measured = result.grid!.cells[i]
            if measured.obstacleSamples > 0 || measured.state == .obstacle {
                grid.cells[i].state = .obstacle
            } else if coverage[i] == 511 {
                grid.cells[i].state = .candidate; count += 1
            }
        }
        self.grid = grid; blueCells = count
        requiredWidth = options.validated().minimumWidth
        halfAngle = options.validated().targetHalfAngleDegrees;maxDistance = result.parameters.forwardRange
        mask = PathClearance.mask(grid:grid,radius:requiredWidth/2)
    }
    public func contains(_ world: V3) -> Bool {
        let p = grid.basis.local(world)
        guard let i = grid.index(x:p.x,z:p.z) else { return false }
        return mask[i]
    }
    public func supports(_ points: [V3]) -> Bool {
        guard points.count >= 2 else { return false }
        return zip(points,points.dropFirst()).allSatisfy { a,b in
            let aa = grid.basis.local(a),bb = grid.basis.local(b)
            return PathClearance.segment(grid:grid,from:SIMD2(aa.x,aa.z),to:SIMD2(bb.x,bb.z),radius:requiredWidth/2)
        }
    }
    public func search(fixedTarget: V3? = nil) -> FanPathPlan { FanPathSearch.plan(grid:grid,mask:mask,width:requiredWidth,halfAngleDegrees:halfAngle,maxDistance:maxDistance,fixedTarget:fixedTarget) }
    public func plan() -> [V3] { search().points }

}

/// Analysis-worker owned facade: session/order validation stays outside route strategy.
/// Spatial runtime and UI continue to use the same PathUpdate contract.
public struct PathPredictor: Sendable {
    private var planner = ForwardRoutePlanner()
    private var lastFrame: UInt64 = 0
    private var lastTimestamp: Double = 0
    private var epoch: UInt64 = 0
    private var version: UInt64 = 0
    private var obstacleConfirmationSeconds: Double = 0.3
    private var experimentalOccupancyPlanning = false
    private var occupancyFilter = TemporalOccupancyGrid()
    public init(experimentalOccupancyPlanning: Bool = false) {
        self.experimentalOccupancyPlanning = experimentalOccupancyPlanning
        if experimentalOccupancyPlanning {
            obstacleConfirmationSeconds = 0 // Input cells have already passed the 300ms filter.
            planner.obstacleConfirmationSeconds = 0
        }
    }
    // Test seam for geometry-only suites. Production always uses the default 300ms.
    init(obstacleConfirmationSeconds: Double) {
        self.obstacleConfirmationSeconds = obstacleConfirmationSeconds
        planner.obstacleConfirmationSeconds = obstacleConfirmationSeconds
    }
    public mutating func reset() {
        occupancyFilter.reset();planner = .init();planner.obstacleConfirmationSeconds = obstacleConfirmationSeconds;lastFrame = 0;lastTimestamp = 0
    }
    public mutating func update(result: AnalysisResult,observation: DepthObservation?,options: PathOptions,
                                directionStable: Bool? = nil) -> PathUpdate {
        if epoch != result.epoch || version != result.parameterVersion {
            reset();epoch = result.epoch;version = result.parameterVersion
        }
        guard options.enabled else { reset();return .init(reason:"disabled") }
        guard result.frameID > lastFrame else {
            return planner.held(at:result.timestamp,options:options.validated(),reason:"out_of_order_ignored")
        }
        guard result.timestamp.isFinite,result.timestamp >= lastTimestamp else {
            reset();return .init(reason:"ground_or_metric_conflict")
        }
        lastFrame = result.frameID;lastTimestamp = result.timestamp
        if result.diagnostics?.groundReferenceInvalidation == "reference_expired_or_clock_reversed" {
            occupancyFilter.reset()
            planner.withdrawEvidence()
            return planner.held(at:result.timestamp,options:options.validated(),reason:"ground_evidence_expired")
        }
        if result.diagnostics?.groundReferenceInvalidation != nil {
            reset();return .init(reason:"ground_or_metric_conflict")
        }
        if experimentalOccupancyPlanning {
            let start = ProcessInfo.processInfo.systemUptime
            guard let planning = occupancyFilter.apply(result) else {
                planner.withdrawEvidence()
                return .init(reason: "experimental_waiting_ground")
            }
            // No raw single-frame veto in this experimental path: doing so would reintroduce
            // the ghosts removed above. Raw depth remains in the separate sensor/log pipeline.
            var update = planner.update(result:planning,observation:nil,options:options.validated(),directionStable:directionStable)
            update.occupancyFilter = occupancyFilter.diagnostics
            update.milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
            return update
        }
        return planner.update(result:result,observation:observation,options:options.validated(),directionStable:directionStable)
    }
}

public struct PathHeading: Codable, Sendable {
    public var angleDegrees: Float // signed: positive means target to the right
    public var crossTrack: Float
    public var startDistance: Float
    public var target: V3
    public var remainingLength: Float
}
public enum PathTracking {
    public static func distance(_ p: V3,to a: V3,end b: V3) -> Float {
        let d = b-a,t = max(0,min(1,simd_dot(p-a,d)/max(0.000001,simd_length_squared(d))))
        return simd_distance(p,a+d*t)
    }
    public static func remaining(_ points: [V3],plane: GroundPlane,pose: RigidPose) -> [V3] {
        guard points.count >= 2 else { return [] }
        let p = plane.project(pose.position)
        var nearest = 0,best = Float.infinity
        for i in 0..<(points.count-1) {
            let d = distance(p,to:points[i],end:points[i+1]); if d < best { best = d; nearest = i }
        }
        let a = points[nearest],b = points[nearest+1],d = b-a
        let t = max(0,min(1,simd_dot(p-a,d)/max(0.000001,simd_length_squared(d))))
        let first = a+d*t
        let tail = Array(points.dropFirst(nearest+1))
        return simd_distance(first,tail[0]) < 0.001 ? tail : [first]+tail
    }
    /// Pure-pursuit-style look-ahead target; this is heading feedback, NOT steering control.
    public static func heading(path: PredictedPath,pose: RigidPose,lookAhead: Float) -> PathHeading? {
        guard let basis = GroundBasis(plane:path.plane,pose:pose) else { return nil }
        let points = remaining(path.points,plane:path.plane,pose:pose)
        guard points.count >= 2 else { return nil }
        let length = zip(points,points.dropFirst()).reduce(Float(0)) { $0+simd_distance($1.0,$1.1) }
        guard length >= 0.25 else { return nil }
        var target = points.last!,left = lookAhead
        for (index,pair) in zip(points,points.dropFirst()).enumerated() {
            let (a,b) = pair,d = simd_distance(a,b)
            if d >= left { target = a+(b-a)*(left/max(0.001,d));break }
            // A long pure-pursuit carrot can point through the inside of a box even though
            // the polyline avoids it. Stop at a significant next corner until it is reached.
            if path.forwardStrategy == true,index+2 < points.count,d > 0.001 {
                let next = points[index+2]-b
                if simd_length(next) > 0.001,
                   simd_dot((b-a)/d,simd_normalize(next)) < cos(15 * Float.pi/180),
                   simd_distance(basis.origin,b) > 0.08 { target = b;break }
            }
            left -= d
        }
        let q = basis.local(target)
        guard hypot(q.x,q.z) > 0.05 else { return nil }
        let start = basis.local(points[0]),tangent = simd_normalize(points[1]-points[0])
        let lateral = abs(simd_dot(basis.origin-points[0],simd_cross(tangent,path.plane.normal)))
        guard lateral.isFinite else { return nil }
        return .init(angleDegrees:atan2(q.x,q.z)*180 / .pi,crossTrack:lateral,startDistance:hypot(start.x,start.z),target:target,remainingLength:length)
    }
}

