import simd

/// Keep the original measured cells, never the planner's searchable, obstacle-veto raster.
/// Grid arrays are immutable here and shared with the analysis result by copy-on-write.
public struct WaypointSurvey: Sendable {
    private struct Sample: Sendable {
        let grid: LocalGrid
        let pose: RigidPose
    }
    private var samples: [Sample] = []
    public init() {}

    public mutating func record(_ grid: LocalGrid, pose: RigidPose, retention: Double) {
        samples.removeAll { grid.timestamp - $0.grid.timestamp > retention }
        samples.append(Sample(grid: grid, pose: pose))
    }

    public static func seesForwardGround(_ grid: LocalGrid, pose: RigidPose, options: PathOptions)
        -> Bool
    {
        coversStep(Sample(grid: grid, pose: pose), pose: pose, target: nil, options: options)
    }

    public func coversStep(from pose: RigidPose, target: V3?, options: PathOptions, now: Double)
        -> Bool
    {
        measuredAt(from: pose, target: target, options: options, now: now) != nil
    }

    public func measuredAt(
        from pose: RigidPose,
        target: V3?,
        options: PathOptions,
        now: Double,
        noLaterThan: Double = .infinity
    )
        -> Double?
    {
        samples.reversed().first {
            let age = now - $0.grid.timestamp
            return $0.grid.timestamp <= noLaterThan && age >= 0 && age <= options.retentionSeconds
                && Self.coversStep($0, pose: pose, target: target, options: options)
        }?.grid.timestamp
    }

    public func leftMappedArea(pose: RigidPose, options: PathOptions) -> Bool {
        guard let last = samples.last else { return false }
        let offset =
            last.grid.basis.local(pose.position) - last.grid.basis.local(last.pose.position)
        guard hypot(offset.x, offset.z) >= options.arrivalRadius else { return false }
        return !samples.reversed().contains {
            let grid = $0.grid
            let foot = grid.basis.local(pose.position)
            guard let i = grid.index(x: foot.x, z: foot.z) else { return false }
            return grid.cells[i].surveyedGround
        }
    }

    private static func coversStep(
        _ sample: Sample,
        pose: RigidPose,
        target: V3?,
        options: PathOptions
    ) -> Bool {
        let grid = sample.grid
        let p = grid.basis.local(pose.position)
        let origin = SIMD2(p.x, p.z)
        let t = grid.basis.local(target ?? (pose.position - pose.back))
        let delta = SIMD2(t.x, t.z) - origin
        let length = simd_length(delta)
        guard length > 0.05 else { return false }
        let forward = delta / length
        let right = SIMD2(forward.y, -forward.x)
        func scanned(_ distance: Float) -> Bool {
            let center = origin + forward * distance
            let steps = max(1, Int(ceil(options.minimumWidth / grid.cellSize)))
            for i in 0...steps {
                let q = center + right * (options.minimumWidth * (Float(i) / Float(steps) - 0.5))
                guard let index = grid.index(x: q.x, z: q.y), grid.cells[index].surveyedGround
                else { return false }
            }
            return true
        }
        let previous = grid.basis.local(sample.pose.position)
        if target == nil, simd_distance(origin, SIMD2(previous.x, previous.z)) <= grid.cellSize {
            // A camera cannot normally see the floor under its own lens. At the observation
            // position use the visible forward strip, not that blind spot. Never use this
            // shortcut to extend the measured area as the user walks.
            return stride(
                from: options.lookAhead,
                through: options.lookAhead * 2,
                by: grid.cellSize
            ).contains {
                scanned($0) && scanned($0 + grid.cellSize)
            }
        }
        let end = target == nil ? options.lookAhead : min(length, options.lookAhead)
        let steps = max(1, Int(ceil(end / grid.cellSize)))
        return (0...steps).allSatisfy { scanned(end * Float($0) / Float(steps)) }
    }
}

extension GridCell {
    fileprivate var surveyedGround: Bool {
        state != .obstacle && obstacleSamples == 0 && (state == .candidate || groundSamples > 0)
    }
}

extension AnalysisResult {
    /// A blank or synthetic search grid is not a current sensor observation.
    var waypointSensorGrid: LocalGrid? {
        guard let grid, grid.frameID == frameID, grid.epoch == epoch, grid.timestamp == timestamp,
            grid.cells.contains(where: {
                $0.surveyedGround || $0.state == .obstacle || $0.obstacleSamples > 0
            })
        else { return nil }
        return grid
    }
}
