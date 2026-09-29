import Foundation
import simd

/// Initial engineering settings, not calibrated probabilities or walking stopping distances.
public struct RouteEvidenceOptions: Codable, Sendable {
  public var groundLifetime: Double = 1
  public var clearanceLifetime: Double = 0.5
  public var obstacleLifetime: Double = 1.5
  public var clearingDuration: Double = 0.15
  public var radius: Float = 6
  public init() {}
}

public struct RouteSegmentEvidence: Codable, Sendable {
  public var endS: Float
  public var observedAt: Double
  public var validUntil: Double
  public var mapVersion: UInt64
}

public struct VerifiedRoutePrefix: Sendable {
  public var points: [V3] = []
  public var evidence: [RouteSegmentEvidence] = []
  public var length: Float = 0
}

/// World-indexed bounded memory. Free evidence comes ONLY from GridBuilder's full-height
/// candidate cells. A fitted plane or absent return never writes free. Sources and stamps are
/// measurements, not publication times. Camera-oriented grids below are conservative query views.
public struct RouteEvidenceMap: Sendable {
  private struct Cell: Sendable {
    var groundAt: Double?
    var clearAt: Double?
    var obstacleAt: Double?
    var clearSince: Double?
    var lastFrame: UInt64 = 0
  }
  public private(set) var options = RouteEvidenceOptions()
  public private(set) var version: UInt64 = 0
  public private(set) var hazardWatermark: UInt64 = 0
  public private(set) var epoch: UInt64 = 0
  private var parameterVersion: UInt64 = 0
  private var basis: GroundBasis?
  private var cells: [SIMD2<Int>: Cell] = [:]
  private var lastTime: Double?
  private var cellSize: Float = 0.1
  public var count: Int { cells.count }
  public init(options: RouteEvidenceOptions = .init()) { self.options = options }
  public mutating func reset() {
    let configuration = options
    self = .init()
    options = configuration
  }

  /// False denotes a reference conflict; caller must discard all old route coordinates.
  public mutating func ingest(_ result: AnalysisResult) -> Bool {
    guard let plane = result.plane, let source = result.grid, let pose = result.sourcePose,
      source.epoch == result.epoch, source.frameID == result.frameID,
      source.timestamp == result.timestamp, result.timestamp.isFinite
    else { return true }
    if epoch != result.epoch || parameterVersion != result.parameterVersion {
      reset()
      epoch = result.epoch
      parameterVersion = result.parameterVersion
    }
    if let lastTime, result.timestamp <= lastTime { return true }
    if let b = basis {
      let oldPlane = GroundPlane(normal: b.normal, offset: -simd_dot(b.normal, b.origin))
      if abs(plane.height(oldPlane.project(pose.position))) > 0.12
        || simd_dot(plane.normal, b.normal) < 0.97
      {
        reset()
        return false
      }
    } else {
      let p = RigidPose(position: .zero)
      basis = GroundBasis.geometry(plane: plane, pose: p, previousForward: V3(0, 0, -1))
      cellSize = source.cellSize
    }
    guard let basis else { return false }
    lastTime = result.timestamp
    version &+= 1
    let foot = basis.local(pose.position)
    cells = cells.filter { key, value in
      let p = SIMD2((Float(key.x) + 0.5) * cellSize, (Float(key.y) + 0.5) * cellSize)
      let newest = max(value.clearAt ?? -.infinity, value.obstacleAt ?? -.infinity)
      return simd_distance(p, SIMD2(foot.x, foot.z)) <= options.radius
        && result.timestamp - newest <= max(options.groundLifetime, options.obstacleLifetime)
    }
    // Only rasterize this observation's finite footprint, not the entire retained window.
    let corners = [
      (-source.halfWidth, Float(0)), (source.halfWidth, Float(0)),
      (-source.halfWidth, Float(source.rows) * source.cellSize),
      (source.halfWidth, Float(source.rows) * source.cellSize),
    ]
    .map { basis.local(source.basis.world(x: $0.0, h: 0, z: $0.1)) }
    let loX = Int(floor(corners.map(\.x).min()! / cellSize))
    let hiX = Int(floor(corners.map(\.x).max()! / cellSize))
    let loZ = Int(floor(corners.map(\.z).min()! / cellSize))
    let hiZ = Int(floor(corners.map(\.z).max()! / cellSize))
    let confirmedGround = ["current_confirmed", "native_confirmed"].contains(
      result.diagnostics?.groundReferenceMode ?? "")
    for z in loZ...hiZ {
      for x in loX...hiX {
        let key = SIMD2(x, z)
        let worldCorners = [(x, z), (x + 1, z), (x, z + 1), (x + 1, z + 1)].map {
          source.basis.local(
            basis.world(x: Float($0.0) * cellSize, h: 0, z: Float($0.1) * cellSize))
        }
        let lowX = worldCorners.map(\.x).min()!
        let highX = worldCorners.map(\.x).max()!
        let lowZ = worldCorners.map(\.z).min()!
        let highZ = worldCorners.map(\.z).max()!
        // Whole bounding box is intentionally conservative for free-space reprojection.
        let sx0 = Int(floor((lowX + source.halfWidth + 0.00001) / source.cellSize))
        let sx1 = Int(floor((highX + source.halfWidth - 0.00001) / source.cellSize))
        let sz0 = Int(floor((lowZ + 0.00001) / source.cellSize))
        let sz1 = Int(floor((highZ - 0.00001) / source.cellSize))
        guard sx0 <= sx1, sz0 <= sz1, sx0 < source.columns, sz0 < source.rows, sx1 >= 0, sz1 >= 0
        else { continue }
        var free =
          confirmedGround && sx0 >= 0 && sz0 >= 0 && sx1 < source.columns && sz1 < source.rows
        var occupied = false
        var suspect = false
        for zz in max(0, sz0)...max(0, min(source.rows - 1, sz1)) {
          for xx in max(0, sx0)...max(0, min(source.columns - 1, sx1)) {
            guard xx < source.columns, zz < source.rows else {
              free = false
              continue
            }
            let c = source.cells[zz * source.columns + xx]
            free = free && c.state == .candidate
            occupied = occupied || c.state == .obstacle || c.obstacleSamples >= 3
            suspect = suspect || c.obstacleSamples > 0
          }
        }
        var value = cells[key] ?? Cell()
        if occupied {
          value.obstacleAt = result.timestamp
          value.clearAt = nil
          value.clearSince = nil
          hazardWatermark = max(hazardWatermark, result.frameID)
        } else if suspect {
          value.clearAt = nil
          value.clearSince = nil
        } else if free {
          value.groundAt = result.timestamp
          if value.obstacleAt != nil {
            if value.clearSince == nil { value.clearSince = result.timestamp }
            if result.timestamp - (value.clearSince ?? result.timestamp) >= options.clearingDuration
            {
              value.obstacleAt = nil
              value.clearAt = result.timestamp
            }
          } else {
            value.clearAt = result.timestamp
          }
        }
        if !occupied && !suspect && !free { value.clearSince = nil }
        value.lastFrame = result.frameID
        if value.groundAt != nil || value.obstacleAt != nil { cells[key] = value }
      }
    }
    return true
  }

  private func state(_ value: Cell?, at time: Double) -> (CellState, Double?, Double?) {
    guard let value else { return (.unknown, nil, nil) }
    if let hit = value.obstacleAt {
      // Decay occupancy to unknown, never to free without clearing measurements.
      return (time - hit <= options.obstacleLifetime ? .obstacle : .unknown, nil, nil)
    }
    guard let clear = value.clearAt, let ground = value.groundAt else {
      return (.unknown, nil, nil)
    }
    let until = min(clear + options.clearanceLifetime, ground + options.groundLifetime)
    return time <= until ? (.candidate, min(clear, ground), until) : (.unknown, nil, nil)
  }

  /// Validate a swept body segment against stable world cells and return actual evidence times.
  public func support(from a: V3, to b: V3, width: Float, at time: Double) -> (
    observedAt: Double, validUntil: Double
  )? {
    guard let basis, width.isFinite, width > 0 else { return nil }
    let aa = basis.local(a)
    let bb = basis.local(b)
    let p = SIMD2(aa.x, aa.z)
    let q = SIMD2(bb.x, bb.z)
    let radius = width / 2
    let lo = simd_min(p, q) - SIMD2(repeating: radius)
    let hi = simd_max(p, q) + SIMD2(repeating: radius)
    var oldest = Double.infinity
    var expiry = Double.infinity
    for z in Int(floor(lo.y / cellSize))...Int(floor(hi.y / cellSize)) {
      for x in Int(floor(lo.x / cellSize))...Int(floor(hi.x / cellSize)) {
        let center = SIMD2((Float(x) + 0.5) * cellSize, (Float(z) + 0.5) * cellSize)
        guard
          PathClearance.overlapsCell(
            from: p, to: q, center: center, cellSize: cellSize, radius: radius)
        else { continue }
        let s = state(cells[SIMD2(x, z)], at: time)
        guard s.0 == .candidate, let observed = s.1, let until = s.2 else { return nil }
        oldest = min(oldest, observed)
        expiry = min(expiry, until)
      }
    }
    return oldest.isFinite ? (oldest, expiry) : nil
  }

  public func prefix(_ points: [V3], width: Float, at time: Double) -> VerifiedRoutePrefix {
    guard let first = points.first, points.count >= 2,
      support(from: first, to: first, width: width, at: time) != nil
    else { return .init() }
    var result = VerifiedRoutePrefix(points: [first])
    for (a, b) in zip(points, points.dropFirst()) {
      let count = max(1, Int(ceil(simd_distance(a, b) / (cellSize / 2))))
      for n in 1...count {
        let next = a + (b - a) * Float(n) / Float(count)
        let previous = result.points.last!
        guard let proof = support(from: previous, to: next, width: width, at: time) else {
          return result
        }
        result.length += simd_distance(previous, next)
        result.points.append(next)
        result.evidence.append(
          .init(
            endS: result.length, observedAt: proof.observedAt,
            validUntil: proof.validUntil, mapVersion: version))
      }
    }
    // Keep original corners; fine samples above are evidence intervals, not extra geometry.
    result.points = points
    return result
  }

  public func snapshot(_ result: AnalysisResult) -> AnalysisResult {
    var output = result
    guard var grid = result.grid else { return output }
    for i in grid.cells.indices {
      let p = grid.center(i)
      let world = grid.basis.world(x: p.x, h: 0, z: p.y)
      var c = GridCell()
      if let proof = support(
        from: world, to: world, width: grid.cellSize * sqrt(2), at: result.timestamp)
      {
        c.state = .candidate
        c.reason = .none
        c.observedAt = proof.observedAt
      } else if let basis {
        let q = basis.local(world)
        let key = SIMD2(Int(floor(q.x / cellSize)), Int(floor(q.z / cellSize)))
        if state(cells[key], at: result.timestamp).0 == .obstacle {
          c.state = .obstacle
          c.obstacleSamples = 3
        }
      }
      grid.cells[i] = c
    }
    output.grid = grid
    return output
  }
}
