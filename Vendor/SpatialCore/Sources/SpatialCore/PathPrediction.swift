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
    public init() {}
    private enum CodingKeys: String, CodingKey { case enabled,haptics,deviationDegrees,retentionSeconds,lookAhead,minimumWidth,targetHalfAngleDegrees,arrivalRadius,alignmentDegrees }
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
    public var path: PredictedPath?
    public var reason: String
    public var blueCells: Int
    public var eligibleCells: Int
    public var milliseconds: Double
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
            if let basis = GroundBasis(plane:path.plane,pose:pose) {
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

/// Analysis-worker owned. One world-space polyline, never a history of screen pixels.
public struct PathPredictor: Sendable {
    private var path: PredictedPath?
    private var goal: FixedPathGoal?
    private var outsideSince: Double?
    private var lastTimestamp: Double = 0
    private var blockedGoalSince: Double?
    private var blockedGoalLast: Double = 0
    private var blockedGoalCount = 0
    private var lastFrame: UInt64 = 0
    private var epoch: UInt64 = 0,version: UInt64 = 0
    public init() {}
    public mutating func reset() { path = nil;goal = nil;outsideSince = nil;lastFrame = 0;lastTimestamp = 0;blockedGoalSince = nil;blockedGoalCount = 0 }
    public mutating func update(result r: AnalysisResult,observation: DepthObservation?,options raw: PathOptions,directionStable: Bool? = nil) -> PathUpdate {
        let start = ProcessInfo.processInfo.systemUptime,options = raw.validated()
        if epoch != r.epoch || version != r.parameterVersion { reset();epoch = r.epoch;version = r.parameterVersion }
        guard options.enabled else { reset();return .init(reason:"disabled") }
        guard r.frameID > lastFrame else {
            var u = PathUpdate(path:path.flatMap { r.timestamp >= $0.observedAt && r.timestamp-$0.observedAt <= options.retentionSeconds ? $0 : nil },reason:"out_of_order_ignored")
            u.goal = goal;return u
        }
        guard r.timestamp.isFinite,r.timestamp >= lastTimestamp else { reset();return .init(reason:"ground_or_metric_conflict") }
        lastFrame = r.frameID;lastTimestamp = r.timestamp
        if r.diagnostics?.groundReferenceInvalidation == "reference_expired_or_clock_reversed" {
            // Lost evidence is not a contradictory world measurement. Keep only the goal ID;
            // no line or haptic survives, and renewed evidence must replan to this same point.
            path = nil;blockedGoalSince = nil;blockedGoalCount = 0
            var update = PathUpdate(reason:"ground_evidence_expired");update.goal = goal;return update
        }
        if r.diagnostics?.groundReferenceInvalidation != nil {
            path = nil;goal = nil;outsideSince = nil;return .init(reason:"ground_or_metric_conflict")
        }
        guard let pose = r.sourcePose ?? observation?.pose else { path = nil;return .init(reason:"missing_pose") }
        var reason = "waiting_blue_ground",change: String?
        if let fixed = goal {
            let origin = fixed.plane.project(pose.position),distance = simd_distance(origin,fixed.point)
            let basis = GroundBasis(plane:fixed.plane,pose:pose)
            let bearing = basis.map { b -> Float in let q = b.local(fixed.point);return abs(atan2(q.x,q.z)*180 / .pi) }
            let outside = distance > fixed.maxDistance+0.2 || (bearing.map{$0 > options.targetHalfAngleDegrees+5} ?? false)
            if distance <= options.arrivalRadius { change = "target_reached" }
            else if outside {
                if outsideSince == nil { outsideSince = r.timestamp }
                if r.timestamp-outsideSince! >= 0.3 { change = "target_out_of_range" }
            } else { outsideSince = nil }
            if let plane = r.plane,r.diagnostics?.groundConfirmed == true,abs(plane.height(fixed.point)) > 0.12 || simd_dot(plane.normal,fixed.plane.normal) < 0.97 { change = "ground_or_metric_conflict" }
            if let change { path = nil;goal = nil;outsideSince = nil;reason = change }
        }
        if reason == "ground_or_metric_conflict" { return .init(reason:reason) }
        let raster = BluePathGrid(result:r,options:options)
        let confirmed = ["current_confirmed","native_confirmed"].contains(r.diagnostics?.groundReferenceMode ?? "") && (directionStable ?? r.sourceDirectionStable ?? false) && r.plane != nil
        var obstacleInvalidated = false,search: FanPathPlan?
        if var old = path {
            if abs(old.requiredWidth-options.minimumWidth) > 0.001 || r.timestamp < old.observedAt { path = nil }
            else {
                let remaining = PathTracking.remaining(old.points,plane:old.plane,pose:pose)
                if remaining.count >= 2 { old.points = remaining }
                if intersectsObstacle(old,result:r,observation:observation) { path = nil;obstacleInvalidated = true;reason = "current_obstacle_invalidated" }
                else if let raster,raster.supports(old.points) {
                    old.observedAt = r.timestamp;old.validatedFrameID = r.frameID;path = old;reason = "revalidated_world_path"
                } else { path = old;reason = "retained_world_path" }
            }
        }
        // A blocked ROUTE pauses guidance but does not move the target. Only a currently
        // occupied goal footprint is itself invalid, rather than merely awaiting a detour.
        var goalCurrentlyBlocked = false
        if let fixed = goal,path == nil {
            let endpoint = makePath([fixed.point,fixed.point],goal:fixed,result:r,width:options.minimumWidth)
            if intersectsObstacle(endpoint,result:r,observation:observation,includeApproach:false) {
                goalCurrentlyBlocked = true;obstacleInvalidated = true;reason = "current_obstacle_invalidated"
                if blockedGoalSince == nil || r.timestamp-blockedGoalLast > 0.4 {
                    blockedGoalSince = r.timestamp;blockedGoalCount = 0
                }
                blockedGoalLast = r.timestamp;blockedGoalCount += 1
                if blockedGoalCount >= 3,r.timestamp-(blockedGoalSince ?? r.timestamp) >= 0.3,confirmed {
                    goal = nil;outsideSince = nil;change = "target_blocked"
                    blockedGoalSince = nil;blockedGoalCount = 0
                }
            }
        }
        if !goalCurrentlyBlocked { blockedGoalSince = nil;blockedGoalCount = 0 }
        // Re-route only TO the same world point. A newly visible farther area never moves it.
        if !goalCurrentlyBlocked,let fixed = goal,let raster,confirmed,(path == nil || reason == "retained_world_path") {
            search = raster.search(fixedTarget:fixed.point)
            if let points = search?.points,points.count >= 2 {
                path = makePath(points,goal:fixed,result:r,width:options.minimumWidth)
                reason = obstacleInvalidated ? "replanned_around_obstacle" : "reacquired_fixed_goal"
            }
        }
        if goal == nil,let raster,confirmed,let plane = r.plane,GroundBasis(plane:plane,pose:pose) != nil {
            search = raster.search()
            if let points = search?.points,points.count >= 2,let point = points.last,
               simd_distance(plane.project(pose.position),point) > options.arrivalRadius+0.1 {
                let fixed = FixedPathGoal(id:r.frameID,epoch:r.epoch,point:point,plane:plane,selectedAt:r.timestamp,maxDistance:r.parameters.forwardRange)
                goal = fixed;path = makePath(points,goal:fixed,result:r,width:options.minimumWidth)
                reason = obstacleInvalidated ? "replanned_around_obstacle" : "new_farthest_goal"
                if change == nil { change = "selected_farthest" }
            } else if reason == "waiting_blue_ground" { reason = "no_reachable_fan_target" }
        }
        // Expire the evidence, NOT the fixed goal. A metadata-only held goal cannot vibrate or draw.
        let visible = path.flatMap { p in r.timestamp >= p.observedAt && r.timestamp-p.observedAt <= options.retentionSeconds ? p : nil }
        if visible == nil,goal != nil,!obstacleInvalidated { reason = "fixed_goal_waiting_evidence" }
        var update = PathUpdate(path:visible,reason:reason,blueCells:raster?.blueCells ?? 0,eligibleCells:raster?.mask.filter({$0}).count ?? 0,milliseconds:(ProcessInfo.processInfo.systemUptime-start)*1000)
        update.goal = goal;update.goalChangeReason = change;update.reachableCells = search?.reachableCells
        if let fixed = goal,let basis = GroundBasis(plane:fixed.plane,pose:pose) {
            let q = basis.local(fixed.point);update.targetBearingDegrees = atan2(q.x,q.z)*180 / .pi
            update.targetGroundDistance = hypot(q.x,q.z);update.approachDistance = visible?.points.first.map { simd_distance(basis.origin,$0) }
        }
        return update
    }
    private func makePath(_ points: [V3],goal: FixedPathGoal,result r: AnalysisResult,width: Float) -> PredictedPath {
        .init(id:goal.id,epoch:r.epoch,parameterVersion:r.parameterVersion,sourceFrameID:r.frameID,validatedFrameID:r.frameID,observedAt:r.timestamp,plane:goal.plane,points:points,source:r.source,requiredWidth:width,footAtPlan:r.sourcePose.map { goal.plane.project($0.position) },targetRange:goal.maxDistance)
    }
    private func intersectsObstacle(_ path: PredictedPath,result r: AnalysisResult,observation: DepthObservation?,includeApproach: Bool = true) -> Bool {
        var worldSegments = Array(zip(path.points,path.points.dropFirst()))
        if includeApproach,let pose = r.sourcePose,let first = path.points.first { worldSegments.append((path.plane.project(pose.position),first)) }
        if let grid = r.grid {
            for (a,b) in worldSegments {
                let aa = grid.basis.local(a),bb = grid.basis.local(b)
                if !PathClearance.segment(grid:grid,from:SIMD2(aa.x,aa.z),to:SIMD2(bb.x,bb.z),radius:path.requiredWidth/2,allowUnknown:true) { return true }
            }
        }
        // Use CURRENT depth against the retained plane even when fitting a new ground failed.
        // Square-distance checks agree with planning; a circle around each cell would falsely
        // invalidate an exactly 0.50 m corridor on every following frame.
        if let o = observation,let basis = GroundBasis.geometry(plane:path.plane,pose:o.pose,previousForward:nil) {
            var counts: [SIMD2<Int>:Int] = [:]
            for p in o.points(parameters:r.parameters) {
                let q = basis.local(p)
                guard q.y > max(0.05,r.parameters.planeTolerance),q.y < r.parameters.bodyHeight+r.parameters.depthMargin else { continue }
                counts[SIMD2(Int(floor(q.x/0.1)),Int(floor(q.z/0.1))),default:0] += 1
            }
            let segments = worldSegments.map { a,b -> (SIMD2<Float>,SIMD2<Float>) in
                let aa = basis.local(a),bb = basis.local(b);return (SIMD2(aa.x,aa.z),SIMD2(bb.x,bb.z))
            }
            for (key,count) in counts where count >= 3 {
                let center = SIMD2((Float(key.x)+0.5)*0.1,(Float(key.y)+0.5)*0.1)
                if segments.contains(where:{ PathClearance.overlapsCell(from:$0.0,to:$0.1,center:center,cellSize:0.1,radius:path.requiredWidth/2) }) { return true }
            }
        }
        return false
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
        for (a,b) in zip(points,points.dropFirst()) {
            let d = simd_distance(a,b)
            if d >= left { target = a+(b-a)*(left/max(0.001,d)); break }; left -= d
        }
        let q = basis.local(target)
        guard hypot(q.x,q.z) > 0.05 else { return nil }
        let start = basis.local(points[0]),tangent = simd_normalize(points[1]-points[0])
        let lateral = abs(simd_dot(basis.origin-points[0],simd_cross(tangent,path.plane.normal)))
        guard lateral.isFinite else { return nil }
        return .init(angleDegrees:atan2(q.x,q.z)*180 / .pi,crossTrack:lateral,startDistance:hypot(start.x,start.z),target:target,remainingLength:length)
    }
}

