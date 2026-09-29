import Foundation
import simd

/// Visual route intent on the estimated floor. Unknown cells remain unknown; this ray is
/// never passed to target arrival, speech, haptics or the measured-route search.
/// A moving finite draw window represents an unbounded ray without infinite GPU coordinates.
public struct RouteProjection: Codable, Sendable {
  public var epoch: UInt64
  public var parameterVersion: UInt64
  public var frameID: UInt64
  public var timestamp: Double
  public var plane: GroundPlane
  public var points: [V3]
  public var clippedByObstacle: Bool
  public var drawDistance: Float

  public static func make(
    result: AnalysisResult, reference: ForwardRouteReference, options: PathOptions,
    drawDistance: Float = 20
  ) -> Self? {
    guard let grid = result.grid, let pose = result.sourcePose,
      grid.epoch == result.epoch, grid.frameID == result.frameID,
      grid.timestamp == result.timestamp, drawDistance.isFinite, drawDistance > 0,
      ["current_confirmed", "native_confirmed"].contains(
        result.diagnostics?.groundReferenceMode ?? "")
    else { return nil }
    let foot = reference.plane.project(pose.position)
    let start = reference.point(reference.coordinates(foot).y)
    guard simd_distance(start, foot) <= 1 else { return nil }
    let localStart = grid.basis.local(start)
    let localEnd = grid.basis.local(start + reference.forward)
    let vector = SIMD2(localEnd.x - localStart.x, localEnd.z - localStart.z)
    guard simd_length(vector) > 0.99 else { return nil }
    let direction = simd_normalize(vector)
    let origin = SIMD2(localStart.x, localStart.z)
    let radius = options.validated().minimumWidth / 2
    var length = min(drawDistance, 100)
    var clipped = false
    // Use the same swept disk vs square-cell test as route planning. Circumscribed
    // disks around cells would unnecessarily close exactly 0.50 m corridors.
    for index in grid.cells.indices {
      let cell = grid.cells[index]
      guard cell.state == .obstacle || cell.obstacleSamples > 0 else { continue }
      func overlaps(_ distance: Float) -> Bool {
        PathClearance.overlapsCell(
          from: origin, to: origin + direction * distance, center: grid.center(index),
          cellSize: grid.cellSize, radius: radius)
      }
      guard overlaps(length) else { continue }
      var low: Float = 0
      var high = length
      // Intersection of a growing prefix is monotonic; 16 steps give sub-mm precision.
      for _ in 0..<16 {
        let middle = (low + high) / 2
        if overlaps(middle) { high = middle } else { low = middle }
      }
      length = max(0, low - 0.002)
      clipped = true
    }
    guard length > 0.05 else { return nil }
    return .init(
      epoch: result.epoch, parameterVersion: result.parameterVersion,
      frameID: result.frameID, timestamp: result.timestamp, plane: reference.plane,
      points: [start, start + reference.forward * length],
      clippedByObstacle: clipped, drawDistance: min(drawDistance, 100))
  }

  public func visible(gate: ResultPresentationGate, now: Double) -> Bool {
    gate.enabled && gate.trackingNormal && epoch == gate.epoch
      && parameterVersion == gate.parameterVersion && frameID >= gate.minimumGeometryFrameID
      && frameID <= gate.frameID && timestamp <= gate.frameTimestamp && now >= timestamp
      && now - timestamp <= gate.maxAge
      && now >= gate.frameTimestamp && now - gate.frameTimestamp <= gate.maxAge
  }
}
