import Foundation
import simd

public struct OccupancyFilterDiagnostics: Codable, Sendable {
  public var thresholdSeconds: Double = 0.3
  public var maximumAssociationGap: Double? = 0.75
  public var referenceSource: String? = nil
  public var forwardBufferLength: Float? = nil
  public var pendingCells: Int = 0
  public var confirmedCells: Int = 0
  public var maximumAge: Double = 0
  public var policy: String = "obstacle_veto_v1"
}

/// Obstacle-veto route input. Every cell not vetoed by the temporal obstacle model is
/// searchable. Keep the measured grid and its ground/clearance diagnostics unchanged.
struct TemporalOccupancyGrid: Sendable {
  private struct Track: Sendable {
    var anchor: V3
    var since: Double
    var last: Double
  }
  private var previous: [SIMD3<Int>: Track] = [:]
  // Multiple measured squares may quantize to one association bin. Keep ALL confirmed
  // squares for collision geometry; choosing one timer must not discard the other area.
  private var confirmedFootprints: [OccupancyFootprint] = []
  private var referencePlane: GroundPlane?
  private var referenceForward: V3?
  private var epoch: UInt64?
  private var parameterVersion: UInt64?
  private(set) var referenceSource = "unavailable"
  static let defaultCameraHeight: Float = 1.4
  private(set) var diagnostics = OccupancyFilterDiagnostics()
  mutating func reset() { self = .init() }

  mutating func apply(_ result: AnalysisResult, forwardLength: Float = 8, routeForward: V3? = nil)
    -> AnalysisResult?
  {
    guard let pose = result.sourcePose else { return nil }
    if epoch != result.epoch || parameterVersion != result.parameterVersion {
      reset()
      epoch = result.epoch
      parameterVersion = result.parameterVersion
    }
    if referencePlane == nil {
      if let plane = result.plane {
        referencePlane = plane
        referenceSource = "input_plane"
      } else if let raw = result.grid {
        referencePlane = GroundPlane(
          normal: raw.basis.normal, offset: -simd_dot(raw.basis.normal, raw.basis.origin))
        referenceSource = "input_grid_reference"
      } else if let prior = result.floorPriors.first {
        referencePlane = GroundPlane(
          normal: prior.normal, offset: -simd_dot(prior.normal, prior.center))
        referenceSource = "floor_prior"
      } else {
        referencePlane = GroundPlane(
          normal: V3(0, 1, 0), offset: Self.defaultCameraHeight - pose.position.y)
        referenceSource = "camera_height_1.4m"
      }
    }
    let drawingPose = RigidPose(
      back: -(routeForward ?? referenceForward ?? -pose.back), position: pose.position)
    guard let plane = referencePlane,
      let basis = GroundBasis.geometry(
        plane: plane, pose: drawingPose, previousForward: referenceForward)
    else { return nil }
    referenceForward = basis.forward
    var parameters = result.parameters
    parameters.forwardRange = forwardLength
    let grid: LocalGrid
    if let raw = result.grid, raw.epoch == result.epoch, raw.frameID == result.frameID,
      raw.timestamp == result.timestamp
    {
      grid = raw
    } else {
      grid = LocalGrid(
        basis: basis, parameters: parameters, timestamp: result.timestamp, frameID: result.frameID,
        epoch: result.epoch)
    }
    diagnostics = .init()
    diagnostics.referenceSource = referenceSource
    diagnostics.forwardBufferLength = forwardLength
    var current: [SIMD3<Int>: Track] = [:]
    confirmedFootprints.removeAll(keepingCapacity:true)
    func key(_ p: V3) -> SIMD3<Int> {
      SIMD3(Int(floor(p.x / 0.1)), Int(floor(p.y / 0.1)), Int(floor(p.z / 0.1)))
    }
    for i in grid.cells.indices {
      let c = grid.cells[i]
      let occupied = c.state == .obstacle || c.obstacleSamples > 0
      var confirmed = false
      if occupied {
        let center = grid.center(i)
        let world = grid.basis.world(x: center.x, h: 0, z: center.y)
        let k = key(world)
        var match: Track?
        var best: Float = .infinity
        for y in -1...1 {
          for z in -1...1 {
            for x in -1...1 {
              guard let old = previous[k &+ SIMD3(x, y, z)],
                result.timestamp > old.last,
                result.timestamp - old.last <= (diagnostics.maximumAssociationGap ?? 0.75)
                  + 0.000001
              else { continue }
              // Fixed anchor bounds motion; a walking object cannot carry the timer
              // indefinitely by hopping from one neighbouring bin to the next.
              let distance = simd_distance(world, old.anchor)
              if distance <= 0.16 && distance < best {
                match = old
                best = distance
              }
            }
          }
        }
        var track = match ?? Track(anchor: world, since: result.timestamp, last: result.timestamp)
        track.last = result.timestamp
        let age = result.timestamp - track.since
        confirmed = age + 0.000001 >= diagnostics.thresholdSeconds
        diagnostics.maximumAge = max(diagnostics.maximumAge, age)
        if confirmed {
          diagnostics.confirmedCells += 1
          confirmedFootprints.append(.init(center:world,right:grid.basis.right,forward:grid.basis.forward,size:grid.cellSize))
        } else { diagnostics.pendingCells += 1 }
        // Keep the older matching track when multiple samples quantize to one bin.
        if current[k].map({ $0.since > track.since }) ?? true { current[k] = track }
      }
    }
    previous = current  // A missing detection does not carry its timer into a later sighting.
    return projected(result, forwardLength: forwardLength, forward: basis.forward)
  }

  /// Re-query the SAME confirmed world tracks in another direction; never ingest twice or
  /// restart confirmation when testing a user's new heading outside the old route window.
  func projected(_ result: AnalysisResult, forwardLength: Float, forward: V3) -> AnalysisResult? {
    guard let pose = result.sourcePose, let plane = referencePlane,
      let basis = GroundBasis.geometry(plane: plane,
        pose: RigidPose(back: -forward, position: pose.position), previousForward: referenceForward)
    else { return nil }
    var parameters = result.parameters
    parameters.forwardRange = forwardLength
    var planningGrid = LocalGrid(
      basis: basis, parameters: parameters, timestamp: result.timestamp, frameID: result.frameID,
      epoch: result.epoch)
    planningGrid.cells = Array(repeating: GridCell(state: .candidate), count: planningGrid.cells.count)
    let footprints = confirmedFootprints.sorted {
      if $0.center.x != $1.center.x { return $0.center.x < $1.center.x }
      if $0.center.z != $1.center.z { return $0.center.z < $1.center.z }
      return $0.center.y < $1.center.y
    }
    for footprint in footprints { footprint.stamp(into: &planningGrid) }
    var planning = result
    planning.grid = planningGrid
    planning.planningObstacles = footprints
    planning.plane = plane
    planning.parameters = parameters
    planning.source = result.source + ":obstacle_veto_300ms"
    return planning
  }
}
