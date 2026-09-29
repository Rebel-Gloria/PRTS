import Foundation
import simd

/// Worker-confined state machine. World intent survives yaw and short evidence gaps; drawable
/// geometry never survives an explicit obstacle veto, reference conflict or its evidence TTL.
struct ForwardRoutePlanner: Sendable {
    private struct Maneuver: Sendable {
        var id: UInt64
        var mode: ForwardRouteMode
        var side: Int
        var obstacle: ForwardObstacle
        var join: V3?
        var points: [V3]
    }
    var obstacleConfirmationSeconds: Double = 0.3
    private var persistence = ObstaclePersistence()
    private var path: PredictedPath?
    private var goal: FixedPathGoal?
    private var reference: ForwardRouteReference?
    private var maneuver: Maneuver?
    private var turn = ForwardTurnDwell()
    private var lastDiagnostics = ForwardStrategyDiagnostics()

    mutating func withdrawEvidence() {
        path = nil
        persistence.reset()
        turn.reset()
        lastDiagnostics.invalidatesPreviousPath = true
    }
    func held(at time: Double, options: PathOptions, reason: String) -> PathUpdate {
        var update = PathUpdate(
            path: path.flatMap {
                time >= $0.observedAt && time - $0.observedAt <= options.retentionSeconds ? $0 : nil
            }, reason: reason)
        update.goal = goal
        update.strategy = lastDiagnostics
        return update
    }

    mutating func update(
        result r: AnalysisResult, observation: DepthObservation?, options: PathOptions,
        directionStable: Bool?
    ) -> PathUpdate {
        let started = ProcessInfo.processInfo.systemUptime
        guard let pose = r.sourcePose ?? observation?.pose else {
            withdrawEvidence()
            return held(at: r.timestamp, options: options, reason: "missing_pose")
        }
        var reason = "waiting_blue_ground"
        var change: String?
        var invalidated = false
        let confirmed =
            ["current_confirmed", "native_confirmed"].contains(r.diagnostics?.groundReferenceMode ?? "")
            && r.plane != nil
        let raster = RoutePlanningGrid(result: r, options: options)

        if let ref = reference, let plane = r.plane, r.diagnostics?.groundConfirmed == true,
            abs(plane.height(ref.plane.project(pose.position))) > 0.12
                || simd_dot(plane.normal, ref.plane.normal) < 0.97
        {
            let delay = obstacleConfirmationSeconds
            self = .init()
            obstacleConfirmationSeconds = delay
            return .init(reason: "ground_or_metric_conflict")
        }
        // Compare local floor heights above, not a tilted plane extrapolated to an old,
        // distant route origin. Reproject height while keeping the same world heading.
        if confirmed, let plane = r.plane, var ref = reference {
            let projected = ref.forward - plane.normal * simd_dot(ref.forward, plane.normal)
            if simd_length(projected) > 0.5 {
                ref.origin = plane.project(ref.origin)
                ref.forward = simd_normalize(projected)
                ref.plane = plane
                reference = ref
                if var old = path {
                    old.points = old.points.map { plane.project($0) }
                    old.plane = plane
                    path = old
                }
                if var fixed = goal {
                    fixed.point = plane.project(fixed.point)
                    fixed.plane = plane
                    goal = fixed
                }
                if var active = maneuver {
                    active.points = active.points.map { plane.project($0) }
                    active.join = active.join.map { plane.project($0) }
                    maneuver = active
                }
            }
        }
        if let fixed = goal {
            let distance = simd_distance(fixed.plane.project(pose.position), fixed.point)
            if distance <= options.arrivalRadius {
                change = "target_reached"
                if maneuver?.mode == .sideRoute { reference = nil }
                path = nil
                goal = nil
                maneuver = nil
                turn.reset()
                invalidated = true
            }
        }

        // Angular range exit deliberately does not release intent: a user can look to the side
        // while going around a box. Only the explicit clear-direction dwell below changes it.
        if reference == nil, confirmed, let plane = r.plane, let basis = GroundBasis(plane: plane, pose: pose) {
            reference = .init(origin: basis.origin, forward: basis.forward, plane: plane)
            // Resolve at most half a raster-cell of centre quantization. This is still a
            // parallel forward line, not a far-side target search or unknown-space dilation.
            if let raster, let ref = reference,
                ForwardPathSearch.straight(raster: raster, reference: ref, foot: basis.origin).entry == nil
            {
                for offset: Float in [-raster.grid.cellSize / 2, raster.grid.cellSize / 2] {
                    var shifted = ref
                    shifted.origin += basis.right * offset
                    if !ForwardPathSearch.straight(raster: raster, reference: shifted, foot: basis.origin).points
                        .isEmpty
                    {
                        reference = shifted
                        break
                    }
                }
            }
        }

        var previousEntry: V3?
        if var old = path {
            let remaining = PathTracking.remaining(old.points, plane: old.plane, pose: pose)
            previousEntry = remaining.first
            if remaining.count < 2 || abs(old.requiredWidth - options.minimumWidth) > 0.001 {
                path = nil
                invalidated = true
            } else {
                old.points = remaining
                if PathObstacleCheck.intersects(old, result: r, observation: observation) {
                    path = nil
                    invalidated = true
                    reason = "current_obstacle_invalidated"
                } else if let raster, raster.supports(remaining) {
                    old.observedAt = r.timestamp
                    old.validatedFrameID = r.frameID
                    path = old
                    reason = "revalidated_world_path"
                } else {
                    path = old
                    reason = "retained_world_path"
                }
            }
        }

        var diagnostics = ForwardStrategyDiagnostics()
        if let ref = reference {
            let foot = ref.plane.project(pose.position)
            let device = GroundBasis(plane: ref.plane, pose: pose)
            var trigger: ForwardObstacle?
            if let raster, let device {
                trigger = ForwardObstacleTrigger.trigger(
                    raster: raster, device: device, reference: ref, options: options)
            }
            let persistent = persistence.update(trigger, at: r.timestamp, threshold: obstacleConfirmationSeconds)
            diagnostics.obstacleAge = persistence.age
            diagnostics.obstacleConfirmed = persistent
            // Turn intention is measured relative to the NEXT route segment, not the original
            // axis. Following an avoidance bend must not start a 3-second override countdown.
            let intended =
                maneuver.map { PathTracking.remaining($0.points, plane: ref.plane, pose: pose) } ?? path?.points ?? []
            let tangent = intended.count >= 2 ? simd_normalize(intended[1] - intended[0]) : ref.forward
            var newStraight: StraightPathTrace?
            var newReference: ForwardRouteReference?
            if confirmed, directionStable ?? r.sourceDirectionStable ?? false, let raster, let device {
                let proposed = ForwardRouteReference(origin: foot, forward: device.forward, plane: ref.plane)
                newReference = proposed
                newStraight = ForwardPathSearch.straight(raster: raster, reference: proposed, foot: foot)
            }
            // A visible continuous segment in the NEW direction is sufficient. Do not
            // require the near-field camera blind zone to be shorter than one metre.
            // Missing observations still reset the continuous turn dwell.
            var clearTurn =
                newStraight.map {
                    $0.observedLength >= max(0.5, options.minimumWidth)
                } ?? false
            if clearTurn, let points = newStraight?.points, let proposed = newReference, let device,
                simd_dot(device.forward, tangent) <= cos(options.userTurnDegrees * Float.pi / 180)
            {
                let candidate = PredictedPath(
                    id: r.frameID, epoch: r.epoch, parameterVersion: r.parameterVersion,
                    sourceFrameID: r.frameID, validatedFrameID: r.frameID, observedAt: r.timestamp,
                    plane: proposed.plane,
                    points: points, source: r.source, requiredWidth: options.minimumWidth)
                clearTurn = !PathObstacleCheck.intersects(candidate, result: r, observation: observation)
            }
            let userTurn = turn.update(
                forward: device?.forward, routeForward: tangent, clear: clearTurn,
                now: r.timestamp, options: options)
            diagnostics.turnDwell = turn.elapsed
            diagnostics.turnAngle = turn.angle
            if userTurn, let newReference, let points = newStraight?.points, points.count >= 2 {
                reference = newReference
                maneuver = nil
                goal = nil
                path = nil
                accept(points, result: r, options: options)
                change = "user_direction_adopted"
                reason = "new_forward_goal"
                invalidated = true
                turn.reset()
                persistence.reset()
            } else if let raster, confirmed {
                if var active = maneuver {
                    let q = ref.coordinates(foot)
                    if active.mode != .sideRoute, let join = active.join {
                        if q.y >= ref.coordinates(join).y - 0.1, abs(q.x) <= 0.15 {
                            maneuver = nil
                            path = nil
                            invalidated = true
                            reason = "original_line_rejoined"
                        } else {
                            let remaining = PathTracking.remaining(active.points, plane: ref.plane, pose: pose)
                            if q.y >= active.obstacle.far, remaining.count >= 2 {
                                let lateral = simd_dot(simd_normalize(remaining[1] - remaining[0]), ref.right)
                                if q.x * lateral < -0.01 {
                                    active.mode = .returning
                                    maneuver = active
                                }
                            }
                        }
                    }
                }
                if maneuver != nil {
                    // Preserve an already validated polyline and its side; only rebuild when
                    // current evidence no longer supports it. Never swap sides every frame.
                    if path == nil || reason == "retained_world_path" {
                        if let active = maneuver {
                            let remaining = PathTracking.remaining(active.points, plane: ref.plane, pose: pose)
                            let entry = previousEntry ?? remaining.first
                            do {
                                let entry = entry.flatMap { raster.contains($0) ? $0 : nil }
                                let points: [V3]
                                if active.mode == .sideRoute {
                                    points =
                                        FanPathSearch.plan(
                                            grid: raster.grid, mask: raster.mask, width: raster.requiredWidth,
                                            halfAngleDegrees: 90, maxDistance: raster.maxDistance,
                                            start: entry,
                                            cellFilter: { p in
                                                let q = ref.coordinates(raster.grid.basis.world(x: p.x, h: 0, z: p.y))
                                                return Float(active.side) * q.x >= -0.00001
                                            }
                                        ).points
                                } else {
                                    points =
                                        ForwardPathSearch.detour(
                                            raster: raster, reference: ref, obstacle: active.obstacle,
                                            entry: entry, side: active.side, goal: goal?.point)?.0.points ?? []
                                }
                                if points.count >= 2 {
                                    accept(points, result: r, options: options)
                                    maneuver?.points = points
                                    reason = "reacquired_maneuver"
                                }
                            }
                        }
                    }
                } else if let obstacle = trigger {
                    diagnostics.mode = .blocked
                    let trace = ForwardPathSearch.straight(raster: raster, reference: ref, foot: foot)
                    do {
                        let entry = trace.entry
                        let small = obstacle.extentObserved && obstacle.width < options.smallObstacleWidth - 0.00001
                        let selected = persistent ? selectManeuver(
                            raster: raster, reference: ref, obstacle: obstacle, entry: entry, small: small) : nil
                        if let (side, plan, join) = selected {
                            if join == nil {
                                goal = nil
                                change = "large_obstacle_side_route"
                            } else if let fixed = goal, let join,
                                ref.coordinates(fixed.point).y <= ref.coordinates(join).y + 0.3
                            {
                                goal = nil
                                change = "target_extended_for_detour"
                            }
                            maneuver = .init(
                                id: r.frameID, mode: join == nil ? .sideRoute : .detour, side: side,
                                obstacle: obstacle, join: join, points: plan.points)
                            accept(plan.points, result: r, options: options)
                            reason = "replanned_around_obstacle"
                            invalidated = true
                        } else if trace.points.count >= 2 {
                            // A distant blocked return must not hide the still-observed prefix.
                            accept(trace.points, result: r, options: options)
                            reason = persistent ? "obstacle_ahead_truncated" : "transient_obstacle_truncated"
                        } else {
                            path = nil
                            invalidated = true
                            reason = persistent ? "near_obstacle_no_observed_detour" : "obstacle_pending_confirmation"
                        }
                    }
                } else {
                    // Greedily extend along the reference to the farthest connected observed
                    // point. An unknown stripe truncates; no lateral exploration without a hit.
                    let trace = ForwardPathSearch.straight(
                        raster: raster, reference: ref, foot: foot)
                    if trace.points.count >= 2 {
                        let hadGoal = goal != nil
                        accept(trace.points, result: r, options: options)
                        reason = hadGoal ? "reacquired_forward_line" : "new_forward_goal"
                        if !hadGoal, change == nil { change = "selected_forward" }
                        if path?.points.last != goal?.point { reason = "forward_truncated" }
                    }
                }
            }
            diagnostics.triggerDistance = trigger?.distance
            diagnostics.obstacleWidth = trigger?.width ?? maneuver?.obstacle.width
            diagnostics.obstacleExtentObserved = trigger?.extentObserved ?? maneuver?.obstacle.extentObserved
        } else {
            turn.reset()
            persistence.reset()
        }
        // A newly generated route receives the same CURRENT raw-depth veto as an old route.
        if let candidate = path, candidate.sourceFrameID == r.frameID,
            let veto = PathObstacleCheck.reason(candidate, result: r, observation: observation)
        {
            diagnostics.obstacleVeto = veto
            path = nil
            invalidated = true
            reason = "current_obstacle_invalidated"
        }
        diagnostics.reference = reference
        diagnostics.invalidatesPreviousPath = invalidated
        if let active = maneuver {
            diagnostics.mode = active.mode
            diagnostics.maneuverID = active.id
            diagnostics.side = active.side
            diagnostics.rejoinPoint = active.join
        }
        lastDiagnostics = diagnostics
        var update = held(at: r.timestamp, options: options, reason: reason)
        if update.path == nil, goal != nil, !invalidated { update.reason = "fixed_goal_waiting_evidence" }
        update.goalChangeReason = change
        update.blueCells = raster?.blueCells ?? 0
        update.eligibleCells = raster?.mask.filter({ $0 }).count ?? 0
        // Extend intent independently of measured ground coverage; never extend through an
        // active manoeuvre or a current raw-depth veto. Projection does not renew path evidence.
        if maneuver == nil, diagnostics.obstacleVeto == nil, let reference,
            let projection = RouteProjection.make(result: r, reference: reference, options: options)
        {
            let probe = PredictedPath(
                id: r.frameID, epoch: r.epoch, parameterVersion: r.parameterVersion,
                sourceFrameID: r.frameID, validatedFrameID: r.frameID, observedAt: r.timestamp,
                plane: projection.plane, points: projection.points, source: "visual_projection",
                requiredWidth: options.minimumWidth)
            if !PathObstacleCheck.intersects(probe, result: r, observation: observation) {
                update.projection = projection
            }
        }
        update.milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
        if let fixed = goal, let basis = GroundBasis(plane: fixed.plane, pose: pose) {
            let q = basis.local(fixed.point)
            update.targetBearingDegrees = atan2(q.x, q.z) * 180 / .pi
            update.targetGroundDistance = hypot(q.x, q.z)
            update.approachDistance = update.path?.points.first.map { simd_distance(basis.origin, $0) }
        }
        return update
    }

    /// Deterministic choice is separate from committing the route state.
    private func selectManeuver(
        raster: RoutePlanningGrid, reference ref: ForwardRouteReference,
        obstacle: ForwardObstacle, entry: V3?, small: Bool
    ) -> (Int, FanPathPlan, V3?)? {
        var choices: [(Int, FanPathPlan, V3?)] = []
        for side in [-1, 1] {
            if small {
                if let (plan, join) = GreedyDetourSearch.plan(
                    raster: raster, reference: ref, obstacle: obstacle, entry: entry, side: side) {
                    choices.append((side, plan, join))
                    continue
                }
                if let (plan, join) = ForwardPathSearch.detour(
                    raster: raster, reference: ref, obstacle: obstacle,
                    entry: entry, side: side, goal: goal?.point)
                {
                    choices.append((side, plan, join))
                    continue
                }
            }
            do {
                let plan = ForwardPathSearch.sideRoute(
                    raster: raster, reference: ref, obstacle: obstacle, entry: entry, side: side)
                if plan.points.count >= 2 { choices.append((side, plan, nil)) }
            }
        }
        // Shortest local avoidance; large-object alternatives prefer progress.
        // Stable left tie-break only when geometry scores are equal.
        return choices.min { a, b in
            // Prefer a demonstrated return over a side-only fallback for a small object.
            if small, (a.2 != nil) != (b.2 != nil) { return a.2 != nil }
            if !small, abs((a.1.targetDistance ?? 0) - (b.1.targetDistance ?? 0)) > 0.05 {
                return (a.1.targetDistance ?? 0) > (b.1.targetDistance ?? 0)
            }
            let la = routeLength(a.1.points)
            let lb = routeLength(b.1.points)
            return abs(la - lb) > 0.001 ? la < lb : a.0 < b.0
        }
    }

    private func routeLength(_ points: [V3]) -> Float {
        zip(points, points.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) }
    }

    private mutating func accept(_ points: [V3], result r: AnalysisResult, options: PathOptions) {
        guard let ref = reference, let end = points.last else { return }
        if goal == nil {
            goal = .init(
                id: r.frameID, epoch: r.epoch, point: end, plane: ref.plane,
                selectedAt: r.timestamp, maxDistance: r.parameters.forwardRange)
        }
        // A straight target is a rolling horizon, not a pin that shortens the next trace.
        // Keep identity stable for speech/haptics; a committed manoeuvre still holds its goal.
        if maneuver == nil || maneuver?.mode == .sideRoute {
            goal?.point = end
            goal?.plane = ref.plane
        }
        guard let fixed = goal else { return }
        path = .init(
            id: fixed.id, epoch: r.epoch, parameterVersion: r.parameterVersion,
            sourceFrameID: r.frameID, validatedFrameID: r.frameID, observedAt: r.timestamp,
            plane: ref.plane, points: points, source: r.source, requiredWidth: options.minimumWidth,
            forwardStrategy: true, footAtPlan: r.sourcePose.map { ref.plane.project($0.position) },
            targetRange: r.parameters.forwardRange)
    }
}
