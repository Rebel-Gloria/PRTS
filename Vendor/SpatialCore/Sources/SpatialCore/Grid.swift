import Foundation
import simd

public enum CellState: String, Codable, Sendable { case unknown, obstacle, candidate }
public enum UnknownReason: String, Codable, Sendable {
    case noGround, uncertainSurface, noClearance, footprintUnknown, inflatedObstacle, groundUnconfirmed, none
}
public struct GridCell: Codable, Sendable {
    public var state: CellState = .unknown
    public var reason: UnknownReason = .noGround
    public var groundSamples: Int = 0
    public var obstacleSamples: Int = 0
    public var minObstacleHeight: Float?
    public var maxObstacleHeight: Float?
    public var observedAt: Double = 0
    public init(state: CellState = .unknown) { self.state = state; reason = state == .unknown ? .noGround : .none }
}
public struct LocalGrid: Codable, Sendable {
    public var columns: Int; public var rows: Int; public var cellSize: Float; public var halfWidth: Float
    public var cells: [GridCell]; public var basis: GroundBasis
    public var timestamp: Double; public var frameID: UInt64; public var epoch: UInt64
    public init(basis: GroundBasis, parameters p: ProbeParameters, timestamp: Double = 0, frameID: UInt64 = 0, epoch: UInt64 = 0) {
        columns = Int(round(2*p.halfWidth/p.gridSize)); rows = Int(round(p.forwardRange/p.gridSize))
        cellSize = p.gridSize; halfWidth = p.halfWidth; cells = Array(repeating:GridCell(),count:columns*rows)
        self.basis = basis; self.timestamp = timestamp; self.frameID = frameID; self.epoch = epoch
    }
    public func index(x: Float, z: Float) -> Int? {
        guard x.isFinite,z.isFinite,x >= -halfWidth,x < halfWidth,z >= 0,z < Float(rows)*cellSize else { return nil }
        let c = Int(floor((x+halfWidth)/cellSize)), r = Int(floor(z/cellSize))
        guard c >= 0, c < columns, r >= 0, r < rows else { return nil }; return r*columns+c
    }
    public func center(_ index: Int) -> SIMD2<Float> {
        SIMD2((Float(index%columns)+0.5)*cellSize-halfWidth,(Float(index/columns)+0.5)*cellSize)
    }
    public var unknownFraction: Float { Float(cells.filter { $0.state == .unknown }.count)/Float(max(1,cells.count)) }
}

public enum GridBuilder {
    public static func build(points: [V3], observation o: DepthObservation, plane: GroundPlane, basis: GroundBasis, parameters p: ProbeParameters, evaluateClearance: Bool = true) -> LocalGrid {
        var grid = LocalGrid(basis:basis,parameters:p,timestamp:o.timestamp,frameID:o.frameID,epoch:o.epoch)
        var suspect = Set<Int>(); var quadrants = Array(repeating:UInt8(0),count:grid.cells.count)
        for point in points {
            let local = basis.local(point)
            guard let i = grid.index(x:local.x,z:local.z) else { continue }
            if abs(local.y) <= p.planeTolerance {
                grid.cells[i].groundSamples += 1
                let center = grid.center(i)
                let q = (local.x >= center.x ? 1 : 0) + (local.z >= center.y ? 2 : 0)
                quadrants[i] |= UInt8(1<<q)
            } else if local.y > p.planeTolerance && local.y < p.bodyHeight + p.depthMargin {
                grid.cells[i].obstacleSamples += 1
                grid.cells[i].minObstacleHeight = min(grid.cells[i].minObstacleHeight ?? local.y,local.y)
                grid.cells[i].maxObstacleHeight = max(grid.cells[i].maxObstacleHeight ?? local.y,local.y)
                suspect.insert(i)
            }
        }
        let visibility = evaluateClearance && plane.floorPriorConfirmed ? VisibilityDepth(o,parameters:p) : nil
        var clearanceBudget = VisibilityDepth.defaultFramePixelBudget
        for i in grid.cells.indices {
            grid.cells[i].observedAt = o.timestamp
            if grid.cells[i].obstacleSamples >= 3 {
                grid.cells[i].state = .obstacle; grid.cells[i].reason = .none; continue
            }
            if suspect.contains(i) { grid.cells[i].reason = .uncertainSurface; continue }
            guard evaluateClearance,plane.floorPriorConfirmed,let visibility else { grid.cells[i].reason = .groundUnconfirmed; continue }
            guard grid.cells[i].groundSamples >= 3, quadrants[i].nonzeroBitCount >= 2 else { continue }
            let center = grid.center(i), half = grid.cellSize/2
            var clear = true
            var h: Float = max(0.06,p.planeTolerance*2)
            while h < p.bodyHeight {
                let top = min(h+0.1,p.bodyHeight)
                var corners: [V3] = []; corners.reserveCapacity(8)
                for x in [center.x-half,center.x+half] { for z in [center.y-half,center.y+half] { for y in [h,top] {
                    corners.append(basis.world(x:x,h:y,z:z))
                }}}
                if !visibility.isClear(corners:corners,margin:p.depthMargin,pixelBudget:&clearanceBudget) { clear = false; break }
                h = top
            }
            grid.cells[i].state = clear ? .candidate : .unknown
            grid.cells[i].reason = clear ? .none : .noClearance
        }
        return grid
    }
    /// Configuration space: whole circular footprint must be observed, not just its center.
    /// Distance to cell squares (rather than centers) avoids under-inflating at diagonals.
    public static func footprintMask(grid: LocalGrid, radius: Float) -> [Bool] {
        let n = Int(ceil(radius/grid.cellSize + 0.5))
        var offsets: [(Int,Int)] = []
        for dz in -n...n { for dx in -n...n {
            let x = max(0,Float(abs(dx))*grid.cellSize-grid.cellSize/2)
            let z = max(0,Float(abs(dz))*grid.cellSize-grid.cellSize/2)
            if hypot(x,z) <= radius { offsets.append((dx,dz)) }
        }}
        return grid.cells.indices.map { i in
            guard grid.cells[i].state == .candidate else { return false }
            let x = i%grid.columns,z = i/grid.columns
            return offsets.allSatisfy { dx,dz in
                let xx = x+dx,zz = z+dz
                return xx >= 0 && xx < grid.columns && zz >= 0 && zz < grid.rows && grid.cells[zz*grid.columns+xx].state == .candidate
            }
        }
    }
}

public enum Sector: String, CaseIterable, Codable, Sendable { case left, center, right
    public static func forPosition(x: Float,z: Float) -> Sector {
        let degrees = atan2(x,z)*180/Float.pi
        return degrees < -15 ? .left : (degrees > 15 ? .right : .center)
    }
    public var title: String { switch self { case .left: "左"; case .center: "中"; case .right: "右" } }
}
public struct ObstacleDistance: Codable, Sendable {
    public var sector: Sector
    public var groundDistance: Float
    public var interquantileSpread: Float
    public var supportedCells: Int
    public var sampleCount: Int
}
public struct CandidateSegment: Codable, Sendable {
    public var sector: Sector
    public var cellIndices: [Int]
    public var startDistance: Float
    public var length: Float
    public var minimumObservedWidth: Float
    public var stopReason: String
}
public enum ChannelPlanner {
    public static func distances(grid: LocalGrid) -> [ObstacleDistance] {
        var visited = Set<Int>(); var results: [Sector:ObstacleDistance] = [:]
        for seed in grid.cells.indices where grid.cells[seed].state == .obstacle && !visited.contains(seed) {
            var queue = [seed]; visited.insert(seed); var head = 0
            while head < queue.count {
                let i = queue[head]; head += 1
                for (dx,dz) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let x = i%grid.columns+dx,z = i/grid.columns+dz
                    guard x >= 0,x < grid.columns,z >= 0,z < grid.rows else { continue }
                    let j = z*grid.columns+x
                    if grid.cells[j].state == .obstacle && visited.insert(j).inserted { queue.append(j) }
                }
            }
            for sector in Sector.allCases {
                let indices = queue.filter { let c = grid.center($0); return Sector.forPosition(x:c.x,z:c.y) == sector }
                let samples = indices.reduce(0) { $0+grid.cells[$1].obstacleSamples }
                guard !indices.isEmpty,samples >= 6 else { continue }
                let d = indices.map { simd_length(grid.center($0)) }.sorted()
                let q10 = d[Int(Float(d.count-1)*0.1)],q90 = d[Int(Float(d.count-1)*0.9)]
                let estimate = ObstacleDistance(sector:sector,groundDistance:q10,interquantileSpread:q90-q10,supportedCells:indices.count,sampleCount:samples)
                if results[sector] == nil || q10 < results[sector]!.groundDistance { results[sector] = estimate }
            }
        }
        return Sector.allCases.compactMap { results[$0] }
    }
    public static func segments(grid: LocalGrid, mask: [Bool]) -> [CandidateSegment] {
        guard mask.count == grid.cells.count else { return [] }
        var results: [CandidateSegment] = []
        for sector in Sector.allCases {
            // Seed only the nearest observed configuration-space row in this sector.
            // Never restart farther away after an unknown gap.
            guard let first = mask.indices.first(where: { i in
                let c = grid.center(i); return mask[i] && Sector.forPosition(x:c.x,z:c.y) == sector
            }) else { continue }
            let startRow = first/grid.columns
            var parent: [Int:Int] = [:]; var reachable = Set<Int>()
            for x in 0..<grid.columns {
                let i = startRow*grid.columns+x,c = grid.center(i)
                if mask[i] && Sector.forPosition(x:c.x,z:c.y) == sector { reachable.insert(i); parent[i] = -1 }
            }
            var lastRow = reachable
            if startRow+1 < grid.rows {
                for row in (startRow+1)..<grid.rows {
                    var next = Set<Int>()
                    for x in 0..<grid.columns {
                        let i = row*grid.columns+x,c = grid.center(i)
                        guard mask[i],Sector.forPosition(x:c.x,z:c.y) == sector else { continue }
                        // Straight first; lateral change requires both corner cells, so no diagonal squeezing.
                        for dx in [0,-1,1] {
                            let px = x+dx
                            guard px >= 0,px < grid.columns else { continue }
                            let prev = (row-1)*grid.columns+px
                            guard lastRow.contains(prev) else { continue }
                            if dx != 0 && (!mask[(row-1)*grid.columns+x] || !mask[row*grid.columns+px]) { continue }
                            parent[i] = prev; next.insert(i); break
                        }
                    }
                    if next.isEmpty { break }
                    lastRow = next; reachable.formUnion(next)
                }
            }
            func width(_ i: Int) -> Float {
                let row = i/grid.columns,x = i%grid.columns
                var l = x,r = x
                while l > 0 && grid.cells[row*grid.columns+l-1].state == .candidate { l -= 1 }
                while r+1 < grid.columns && grid.cells[row*grid.columns+r+1].state == .candidate { r += 1 }
                return Float(r-l+1)*grid.cellSize
            }
            let ordered = lastRow.sorted {
                let wa = width($0),wb = width($1)
                if abs(wa-wb) > 0.0001 { return wa > wb }
                let ca = abs(grid.center($0).x),cb = abs(grid.center($1).x)
                return ca == cb ? $0 < $1 : ca < cb
            }
            guard var end = ordered.first else { continue }
            var path: [Int] = []
            while end >= 0 { path.append(end); end = parent[end] ?? -1 }
            path.reverse()
            guard path.count >= 3 else { continue }
            var length: Float = 0
            for j in 1..<path.count { length += simd_distance(grid.center(path[j-1]),grid.center(path[j])) }
            results.append(.init(sector:sector,cellIndices:path,startDistance:simd_length(grid.center(path[0])),length:length,
                                 minimumObservedWidth:path.map(width).min() ?? 0,stopReason:"未知、足迹净空不足或观测边界；不跨区连接"))
        }
        return results
    }
}
