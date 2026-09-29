import Foundation
import simd

public struct OccupancyFilterDiagnostics: Codable, Sendable {
  public var thresholdSeconds: Double = 0.3
  public var pendingCells: Int = 0
  public var confirmedCells: Int = 0
  public var maximumAge: Double = 0
  public var policy: String = "experimental_occupancy_only"
}

/// Experimental route input only. Never modifies the sensor result, exported raw grid or
/// clearance classification. Absence of occupancy is a planning hypothesis, not ground evidence.
struct TemporalOccupancyGrid: Sendable {
  private struct Track: Sendable {
    var anchor: V3
    var since: Double
    var last: Double
  }
  private var previous: [SIMD3<Int>: Track] = [:]
  private(set) var diagnostics = OccupancyFilterDiagnostics()
  mutating func reset() { self = .init() }

  mutating func apply(_ result: AnalysisResult) -> AnalysisResult? {
    guard var grid = result.grid, result.plane != nil,
      grid.frameID == result.frameID, grid.epoch == result.epoch,
      grid.timestamp == result.timestamp,
      ["current_confirmed", "native_confirmed"].contains(
        result.diagnostics?.groundReferenceMode ?? "")
    else {
      reset()
      return nil
    }
    diagnostics = .init()
    var current: [SIMD3<Int>: Track] = [:]
    func key(_ p: V3) -> SIMD3<Int> {
      SIMD3(Int(floor(p.x / 0.15)), Int(floor(p.y / 0.15)), Int(floor(p.z / 0.15)))
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
                result.timestamp > old.last, result.timestamp - old.last <= 0.2 + 0.000001
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
        if confirmed { diagnostics.confirmedCells += 1 } else { diagnostics.pendingCells += 1 }
        // Keep the older matching track when multiple samples quantize to one bin.
        if current[k].map({ $0.since > track.since }) ?? true { current[k] = track }
      }
      // This private raster is expressly occupancy-only, including unknown and pending
      // cells. The original AnalysisResult stays untouched for UI, DIAG and validation.
      grid.cells[i].state = confirmed ? .obstacle : .candidate
      grid.cells[i].obstacleSamples = confirmed ? max(1, c.obstacleSamples) : 0
    }
    previous = current  // A missing detection does not carry its timer into a later sighting.
    var planning = result
    planning.grid = grid
    planning.source = result.source + ":experimental_occupancy_300ms"
    return planning
  }
}
