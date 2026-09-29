import Foundation

/// Debounces manoeuvre commitment, never current-frame collision rejection.
/// Bounds are in the retained route's world reference, not moving camera pixels.
struct ObstaclePersistence: Sendable {
  private var previous: ForwardObstacle?
  private var first: Double?
  private var last: Double?
  private(set) var age: Double = 0

  mutating func reset() { self = .init() }

  mutating func update(_ obstacle: ForwardObstacle?, at time: Double, threshold: Double = 0.3, maximumGap: Double = 0.2, retainOnMissing: Bool = false)
    -> Bool
  {
    guard time.isFinite else { reset(); return false }
    guard let obstacle else {
      // Missing data cannot advance confirmation, nor erase a recent confirmed track.
      if retainOnMissing, let last, time >= last, time-last <= maximumGap {
        return age + 0.000001 >= threshold
      }
      reset(); return false
    }
    let same =
      previous.map {
        // Require overlapping world footprints; unrelated detections cannot share a timer.
        min($0.far, obstacle.far) >= max($0.near, obstacle.near) - 0.05
          && min($0.maxLateral, obstacle.maxLateral) >= max($0.minLateral, obstacle.minLateral)
            - 0.05
      } ?? false
    let continuous = last.map { time > $0 && time - $0 <= maximumGap + 0.000001 } ?? false
    if !same || !continuous { first = time }
    previous = obstacle
    last = time
    age = max(0, time - (first ?? time))
    return age + 0.000001 >= threshold
  }
}
