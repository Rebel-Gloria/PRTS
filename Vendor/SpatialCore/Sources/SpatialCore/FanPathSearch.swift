import Foundation
import simd

/// Collision checks for a swept disk against cell SQUARES. Exact tangency has no overlapping
/// area: a measured 0.50 m corridor can support the requested 0.50 m prediction envelope.
/// The caller selects unknown/boundary permissions; obstacle-veto and the verified comparator
/// share exactly the same occupied-cell overlap calculation.
public enum PathClearance {
    public static func mask(grid: LocalGrid,radius: Float,allowUnknown: Bool = false) -> [Bool] {
        let reach = Int(ceil(radius/grid.cellSize+0.5))
        var offsets: [(Int,Int)] = []
        for z in -reach...reach { for x in -reach...reach {
            let d = SIMD2(max(0,Float(abs(x))*grid.cellSize-grid.cellSize/2),max(0,Float(abs(z))*grid.cellSize-grid.cellSize/2))
            if simd_length_squared(d) < radius*radius-0.000001 { offsets.append((x,z)) }
        }}
        return grid.cells.indices.map { i in
            guard grid.cells[i].state == .candidate || (allowUnknown && grid.cells[i].state == .unknown) else { return false }
            return offsets.allSatisfy { dx,dz in
                let x = i%grid.columns+dx,z = i/grid.columns+dz
                guard x >= 0 && x < grid.columns && z >= 0 && z < grid.rows else { return allowUnknown }
                let state = grid.cells[z*grid.columns+x].state
                return state == .candidate || (allowUnknown && state == .unknown)
            }
        }
    }
    public static func segment(grid: LocalGrid,from a: SIMD2<Float>,to b: SIMD2<Float>,radius: Float,allowUnknown: Bool = false) -> Bool {
        guard a.x.isFinite,a.y.isFinite,b.x.isFinite,b.y.isFinite else { return false }
        let low = simd_min(a,b)-SIMD2(repeating:radius),high = simd_max(a,b)+SIMD2(repeating:radius)
        if !allowUnknown && (low.x < -grid.halfWidth-0.00001 || high.x > grid.halfWidth+0.00001 || low.y < -0.00001 || high.y > Float(grid.rows)*grid.cellSize+0.00001) { return false }
        let x0 = max(0,Int(floor((low.x+grid.halfWidth)/grid.cellSize))),x1 = min(grid.columns-1,Int(floor((high.x+grid.halfWidth)/grid.cellSize)))
        let z0 = max(0,Int(floor(low.y/grid.cellSize))),z1 = min(grid.rows-1,Int(floor(high.y/grid.cellSize)))
        guard x0 <= x1,z0 <= z1 else { return allowUnknown }
        let half = SIMD2<Float>(repeating:grid.cellSize/2)
        for z in z0...z1 { for x in x0...x1 {
            let i = z*grid.columns+x,state = grid.cells[i].state
            if state == .candidate || (allowUnknown && state == .unknown) { continue }
            let c = grid.center(i)
            if distanceSquared(a,b,boxLow:c-half,boxHigh:c+half) < radius*radius-0.000001 { return false }
        }}
        return true
    }
    public static func overlapsCell(from a: SIMD2<Float>,to b: SIMD2<Float>,center: SIMD2<Float>,cellSize: Float,radius: Float) -> Bool {
        let half = SIMD2<Float>(repeating:cellSize/2)
        return distanceSquared(a,b,boxLow:center-half,boxHigh:center+half) < radius*radius-0.000001
    }
    private static func distanceSquared(_ a: SIMD2<Float>,_ b: SIMD2<Float>,boxLow lo: SIMD2<Float>,boxHigh hi: SIMD2<Float>) -> Float {
        let d = b-a
        var lower: Float = 0,upper: Float = 1,intersects = true
        for axis in 0..<2 {
            if abs(d[axis]) < 0.000001 {
                if a[axis] < lo[axis] || a[axis] > hi[axis] { intersects = false }
            } else {
                let p = (lo[axis]-a[axis])/d[axis],q = (hi[axis]-a[axis])/d[axis]
                lower = max(lower,min(p,q)); upper = min(upper,max(p,q))
            }
        }
        if intersects && lower <= upper { return 0 }
        func pointBox(_ p: SIMD2<Float>) -> Float { simd_length_squared(p-simd_clamp(p,lo,hi)) }
        var answer = min(pointBox(a),pointBox(b))
        for p in [lo,hi,SIMD2(lo.x,hi.y),SIMD2(hi.x,lo.y)] {
            let t = max(0,min(1,simd_dot(p-a,d)/max(0.0000001,simd_length_squared(d))))
            answer = min(answer,simd_length_squared(p-(a+d*t)))
        }
        return answer
    }
}

public struct FanPathPlan: Sendable {
    public var points: [V3] = [] // observed component only; NEVER prepends unobserved feet
    public var reachableCells = 0
    public var targetBearingDegrees: Float?
    public var targetDistance: Float?
    public var approachDistance: Float?
    public init() {}
}
private struct PathHeap {
    private var items: [(Float,Int)] = []
    mutating func push(_ score: Float,_ i: Int) {
        items.append((score,i)); var child = items.count-1
        while child > 0 {
            let parent = (child-1)/2
            guard items[child].0 < items[parent].0 else { break }
            items.swapAt(child,parent); child = parent
        }
    }
    mutating func pop() -> (Float,Int)? {
        guard let first = items.first else { return nil }
        if items.count == 1 { items.removeLast(); return first }
        items[0] = items.removeLast(); var p = 0
        while p*2+1 < items.count {
            var c = p*2+1
            if c+1 < items.count,items[c+1].0 < items[c].0 { c += 1 }
            guard items[c].0 < items[p].0 else { break }
            items.swapAt(c,p); p = c
        }
        return first
    }
}

/// One bounded Dijkstra search over the connected observed blue area, then target selection.
/// This permits sideways moves around obstacles instead of stopping at one broken forward row.
public enum FanPathSearch {
    public static let halfAngleDegrees: Float = 45
    public static func plan(grid: LocalGrid,mask: [Bool],width: Float,halfAngleDegrees: Float = 45,maxDistance: Float = .infinity,fixedTarget: V3? = nil,
                            start: V3? = nil,allowUnknown: Bool = false,cellFilter: ((SIMD2<Float>) -> Bool)? = nil,
                            targetFilter: ((SIMD2<Float>) -> Bool)? = nil) -> FanPathPlan {
        var output = FanPathPlan()
        guard mask.count == grid.cells.count else { return output }
        let radius = width/2
        let halfAngle = min(90,max(15,halfAngleDegrees))*Float.pi/180
        func inFan(_ p: SIMD2<Float>) -> Bool { p.y > 0 && abs(atan2(p.x,p.y)) <= halfAngle+0.00001 && simd_length(p) <= maxDistance+0.00001 }
        let allowed = mask.indices.map { mask[$0] && inFan(grid.center($0)) && (cellFilter?(grid.center($0)) ?? true) }
        var cost = Array(repeating:Float.infinity,count:mask.count),parent = Array(repeating:-1,count:mask.count)
        var roots = Array(repeating:-1,count:mask.count),heap = PathHeap()
        // Virtual feet node connects only to the FIRST footprint-supported cell on each ray.
        // Never jump from one observed island across an unknown gap to a farther island.
        for i in allowed.indices where allowed[i] {
            // A manoeuvre starts in the currently connected observed component. Do not use
            // the old virtual-feet fan roots to jump to an island on the far side of a box.
            if let start {
                let q = grid.basis.local(start),a = SIMD2(q.x,q.z),b = grid.center(i)
                guard simd_distance(a,b) <= grid.cellSize*1.5,
                      PathClearance.segment(grid:grid,from:a,to:b,radius:radius,allowUnknown:allowUnknown) else { continue }
                cost[i] = simd_distance(a,b);roots[i] = i;heap.push(cost[i],i);continue
            }
            let c = grid.center(i),steps = max(1,Int(ceil(simd_length(c)/(grid.cellSize/3))))
            var first: Int?
            for n in 0...steps {
                let q = c*Float(n)/Float(steps)
                if let j = grid.index(x:q.x,z:q.y),allowed[j] { first = j; break }
            }
            guard first == i,PathClearance.segment(grid:grid,from:.zero,to:c,radius:radius,allowUnknown:true) else { continue }
            cost[i] = simd_length(c); roots[i] = i; heap.push(cost[i],i)
        }
        while let (score,i) = heap.pop() {
            if score > cost[i]+0.000001 { continue }
            let x = i%grid.columns,z = i/grid.columns
            for dz in -1...1 { for dx in -1...1 where dx != 0 || dz != 0 {
                let xx = x+dx,zz = z+dz
                guard xx >= 0,xx < grid.columns,zz >= 0,zz < grid.rows else { continue }
                let j = zz*grid.columns+xx
                guard allowed[j] else { continue }
                if dx != 0 && dz != 0 && (!allowed[z*grid.columns+xx] || !allowed[zz*grid.columns+x]) { continue }
                let a = grid.center(i),b = grid.center(j)
                let next = score+simd_distance(a,b)
                guard next+0.000001 < cost[j],PathClearance.segment(grid:grid,from:a,to:b,radius:radius,allowUnknown:allowUnknown) else { continue }
                cost[j] = next; parent[j] = i; roots[j] = roots[i]; heap.push(next,j)
            }}
        }
        let targets = cost.indices.filter { i in
            guard cost[i].isFinite,parent[i] >= 0,roots[i] >= 0,(targetFilter?(grid.center(i)) ?? true) else { return false }
            return simd_distance(grid.center(i),grid.center(roots[i])) >= 0.3-0.00001
        }
        output.reachableCells = cost.filter(\.isFinite).count
        let target: Int
        var exactTarget: SIMD2<Float>?
        if let fixedTarget {
            let q = grid.basis.local(fixedTarget),point = SIMD2(q.x,q.z)
            guard let i = grid.index(x:q.x,z:q.z),targets.contains(i),
                  PathClearance.segment(grid:grid,from:grid.center(i),to:point,radius:radius,allowUnknown:allowUnknown) else { return output }
            target = i;exactTarget = point
        } else {
            // Farthest radial ground-plane distance, NOT forward-z or heading preference.
            // Equal distances use shortest route then stable index solely as deterministic ties.
            guard let i = targets.min(by:{ a,b in
                let da = simd_length_squared(grid.center(a)),db = simd_length_squared(grid.center(b))
                if abs(da-db) > 0.000001 { return da > db }
                if abs(cost[a]-cost[b]) > 0.000001 { return cost[a] < cost[b] }
                return a < b
            }) else { return output };target = i
        }
        var reversed: [Int] = [],i = target
        while i >= 0 { reversed.append(i);i = parent[i] }
        let chain = Array(reversed.reversed())
        // Collision-checked string pulling, not unconstrained spline smoothing.
        var compact: [Int] = [chain[0]],cursor = 0
        while cursor+1 < chain.count {
            var end = chain.count-1
            while end > cursor+1 && !PathClearance.segment(grid:grid,from:grid.center(chain[cursor]),to:grid.center(chain[end]),radius:radius,allowUnknown:allowUnknown) { end -= 1 }
            compact.append(chain[end]);cursor = end
        }
        output.points = compact.map { let c = grid.center($0);return grid.basis.world(x:c.x,h:0,z:c.y) }
        if let fixedTarget,let exactTarget {
            // Append the exact world goal if replacing the last cell centre would cut a corner.
            if output.points.count >= 2 {
                let prev = grid.basis.local(output.points[output.points.count-2])
                if PathClearance.segment(grid:grid,from:SIMD2(prev.x,prev.z),to:exactTarget,radius:radius,allowUnknown:allowUnknown) { output.points[output.points.count-1] = fixedTarget }
                else { output.points.append(fixedTarget) }
            }
        }
        if let start,let first = output.points.first,simd_distance(start,first) > 0.001 {
            output.points.insert(start,at:0)
        }
        // Include the exact entry in string pulling: a virtual-foot to cell-centre hop
        // must not survive as an unnecessary tiny turn before the real avoidance corner.
        while output.points.count > 2 {
            let a = grid.basis.local(output.points[0]),b = grid.basis.local(output.points[2])
            guard PathClearance.segment(grid:grid,from:SIMD2(a.x,a.z),to:SIMD2(b.x,b.z),
                radius:radius,allowUnknown:allowUnknown) else { break }
            output.points.remove(at:1)
        }
        let endpoint = exactTarget ?? grid.center(target)
        output.targetBearingDegrees = atan2(endpoint.x,endpoint.y)*180 / .pi;output.targetDistance = simd_length(endpoint)
        output.approachDistance = simd_length(grid.center(chain[0]))
        return output
    }
}
