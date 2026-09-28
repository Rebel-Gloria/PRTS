import Foundation

/// This is a navigation exclusion volume, not a claim that the air above an object is solid.
public struct BlockingColumn: Codable, Sendable {
    public var cellIndex: Int
    public var measuredBottom: Float
    public var measuredTop: Float
    public var ceiling: Float
}
public struct BlockingVolumeSummary: Codable, Sendable {
    public var columnCount: Int
    public var supportedGroups: Int
    public var minimumEnvelopeVolume: Float
    public var supportedEnvelopeVolume: Float
    public var nominalCeiling: Float
}
public struct BlockingVolumeModel: Codable, Sendable {
    public var columns: [BlockingColumn]
    public var summary: BlockingVolumeSummary
}
public enum BlockingVolumeBuilder {
    public static let minimumCells = 2
    public static let minimumPoints = 6
    public static let minimumEnvelopeVolume: Float = 0.001 // 1 L, at 10 cm horizontal grid resolution.

    /// Evidence must already be current, high-confidence, non-ground occupancy.
    /// Volume is the sum of supported cell area * observed top height above ground.
    /// It is a resolution-dependent geometric envelope, NOT measured solid/material volume.
    /// Never fill a bounding rectangle or connect an unknown gap between components.
    public static func build(grid: LocalGrid,groundConfirmed: Bool,parameters p: ProbeParameters) -> BlockingVolumeModel? {
        guard groundConfirmed else { return nil }
        let threshold = max(SurfaceModelBuilder.minimumProtrusionHeight,p.planeTolerance+0.02)
        func eligible(_ i: Int) -> Bool {
            let cell = grid.cells[i]
            guard cell.state == .obstacle,cell.obstacleSamples >= 3,
                  let low = cell.minObstacleHeight,let top = cell.maxObstacleHeight,
                  low.isFinite,top.isFinite,low >= 0,top >= low else { return false }
            return top >= threshold && top < p.bodyHeight+p.depthMargin
        }
        var visited = Set<Int>(),columns: [BlockingColumn] = []
        var groupCount = 0,totalVolume: Float = 0
        for seed in grid.cells.indices where !visited.contains(seed) && eligible(seed) {
            var group = [seed],head = 0; visited.insert(seed)
            while head < group.count {
                let i = group[head]; head += 1
                for (dx,dz) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let x = i%grid.columns+dx,z = i/grid.columns+dz
                    guard x >= 0,x < grid.columns,z >= 0,z < grid.rows else { continue }
                    let next = z*grid.columns+x
                    if !visited.contains(next),eligible(next) { visited.insert(next); group.append(next) }
                }
            }
            let samples = group.reduce(0) { $0+grid.cells[$1].obstacleSamples }
            let volume = group.reduce(Float(0)) { $0+grid.cellSize*grid.cellSize*(grid.cells[$1].maxObstacleHeight ?? 0) }
            guard group.count >= minimumCells,samples >= minimumPoints,volume >= minimumEnvelopeVolume else { continue }
            groupCount += 1; totalVolume += volume
            for i in group.sorted() {
                let cell = grid.cells[i],top = cell.maxObstacleHeight!
                columns.append(.init(cellIndex:i,measuredBottom:cell.minObstacleHeight!,measuredTop:top,ceiling:max(p.bodyHeight,top)))
            }
        }
        columns.sort { $0.cellIndex < $1.cellIndex }
        return .init(columns:columns,summary:.init(columnCount:columns.count,supportedGroups:groupCount,
            minimumEnvelopeVolume:minimumEnvelopeVolume,supportedEnvelopeVolume:totalVolume,nominalCeiling:p.bodyHeight))
    }
}
