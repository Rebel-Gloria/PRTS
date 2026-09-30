import Foundation
import simd

/// Analysis-worker-owned product state. Only `current` is published/drawn/followed. The
/// preview is a replaceable suffix, rechecked against the latest model before promotion.
struct ObstacleWaypointPlanner: Sendable {
    private var reference: ForwardRouteReference?
    private var current: PredictedPath?
    private var goal: FixedPathGoal?
    private var continuation: [V3] = []
    private var preview: ObstacleWaypointSearch.Plan?
    private var previewAt: Double?
    private var side = 0
    private var scenario: ObstacleRouteScenario = .clear
    private var turn = StationaryRouteTurn()
    private var previousFoot: V3?
    private var outOfViewLatched = false
    private var lastUpdate = PathUpdate()

    var retainedPath: PredictedPath? { current }
    var planningForward: V3? { reference?.forward }
    func held(reason: String) -> PathUpdate {
        var held = lastUpdate
        held.reason = reason
        return held
    }

    mutating func update(result r: AnalysisResult, cameraResult: AnalysisResult?,
                         options: PathOptions, view: RouteCameraView?) -> PathUpdate {
        guard let pose = r.sourcePose, let plane = r.plane,
              let device = GroundBasis.geometry(plane: plane, pose: pose, previousForward: reference?.forward),
              var raster = RoutePlanningGrid(result: r, options: options, obstacleVeto: true)
        else { return held(reason: "waiting_route_reference") }
        let foot = plane.project(pose.position)
        let arrived = goal.map { simd_distance(foot, $0.point) <= options.arrivalRadius } ?? false
        let targetVisible = goal.flatMap { target in view.map { $0.contains(target.point + plane.normal * 0.025, pose: pose) } }
        if targetVisible != false { outOfViewLatched = false }
        let outOfView = !arrived && targetVisible == false && !outOfViewLatched
        var replan: String?
        if reference == nil { reference = .init(origin: foot, forward: device.forward, plane: plane) }
        let routeForward = current.flatMap { path -> V3? in
            guard path.points.count >= 2, simd_distance(path.points[0], path.points[1]) > 0.001 else { return nil }
            return simd_normalize(path.points[1]-path.points[0])
        } ?? reference!.forward
        let redirect = turn.update(foot: foot, forward: device.forward, routeForward: routeForward,
                                   now: r.timestamp, options: options)
        if redirect || outOfView {
            replan = redirect ? "stationary_heading_changed" : "target_out_of_view"
            reference = .init(origin: foot, forward: device.forward, plane: plane)
            if let cameraResult, let cameraRaster = RoutePlanningGrid(result: cameraResult, options: options, obstacleVeto: true) {
                raster = cameraRaster
            }
            side = 0
            preview = nil
            continuation = []
            previewAt = nil
            turn.reset()
            outOfViewLatched = outOfView
        }
        let ref = reference!
        // The held intent, not every small camera yaw, defines the lane during a manoeuvre.
        let laneBasis = GroundBasis.geometry(plane: plane,
            pose: .init(back: -ref.forward, position: pose.position), previousForward: ref.forward)!
        let obstacle = ForwardObstacleTrigger.trigger(raster: raster, device: laneBasis, reference: ref, options: options, laneOnly: true)
        guard let obstacle, obstacle.distance.isFinite else {
            current = nil; goal = nil; preview = nil; previewAt = nil; continuation = []; side = 0
            scenario = .clear
            reference = .init(origin: foot, forward: device.forward, plane: plane)
            previousFoot = foot
            return output(result: r, options: options, scenario: .clear, obstacle: nil,
                          reason: "front_clear", replan: replan, view: view)
        }

        let newScenario: ObstacleRouteScenario = obstacle.distance <= options.waypoints.nearDistance
            || (scenario == .nearObstacle && obstacle.distance <= options.waypoints.nearDistance + 0.15)
            ? .nearObstacle : .distantObstacle
        let stageChanged = scenario != newScenario
        scenario = newScenario
        if let path = current {
            let advance = max(0.5, (previousFoot.map { simd_distance(foot, $0) } ?? 0) + 0.3)
            let remaining = RouteProgressWindow.remaining(path.points, plane: plane, pose: pose, maximumAdvance: advance)
            if remaining.count >= 2 { current?.points = remaining }
        }
        previousFoot = foot
        let blocked = current.map { path in
            !raster.supports([foot] + path.points) || (newScenario == .distantObstacle && goal.map {
                !ObstacleWaypointSearch.hasStandOff($0.point, raster: raster, distance: options.waypoints.standOff)
            } == true)
        } ?? false
        if blocked { replan = "target_or_path_blocked" }
        if arrived { replan = "current_target_reached" }
        if stageChanged && replan == nil { replan = newScenario == .nearObstacle ? "obstacle_entered_near_range" : "distant_obstacle" }

        if current == nil || replan != nil {
            // Promotion is never a promise made when the preview was generated. Recheck
            // the connection and the complete suffix now, then atomically replace current.
            var plan: ObstacleWaypointSearch.Plan?
            if arrived, let pending = preview,
               raster.supports([foot] + Array(pending.points.dropFirst())) {
                plan = .init(points: [foot] + Array(pending.points.dropFirst()), side: pending.side)
            }
            if plan == nil {
                plan = newScenario == .distantObstacle
                    ? ObstacleWaypointSearch.approach(raster: raster, reference: ref, obstacle: obstacle,
                        foot: foot, standOff: options.waypoints.standOff)
                    : ObstacleWaypointSearch.avoid(raster: raster, reference: ref, obstacle: obstacle,
                        foot: foot, preferredSide: side)
            }
            if let plan, commit(plan, result: r, options: options, pose: pose, view: view) {
                preview = nil; previewAt = nil
            } else if blocked || arrived || outOfView || redirect || current == nil {
                current = nil; goal = nil; continuation = []; preview = nil; previewAt = nil
                return output(result: r, options: options, scenario: .blocked, obstacle: obstacle,
                    reason: plan == nil ? "no_detour" : "no_visible_target", replan: replan ?? "no_route", view: view)
            }
            // A failed normal search does not first erase a still-valid current segment.
        }

        if let target = goal, let path = current,
           simd_distance(foot, target.point) <= options.waypoints.previewDistance || path.length <= options.waypoints.previewDistance {
            refreshPreview(raster: raster, reference: ref, obstacle: obstacle, result: r, options: options)
        } else { preview = nil; previewAt = nil }
        return output(result: r, options: options, scenario: newScenario, obstacle: obstacle,
                      reason: newScenario == .distantObstacle ? "approach_obstacle" : "avoid_obstacle",
                      replan: replan, view: view)
    }

    private mutating func commit(_ plan: ObstacleWaypointSearch.Plan, result r: AnalysisResult,
                                 options: PathOptions, pose: RigidPose, view: RouteCameraView?) -> Bool {
        guard let ref = reference,
              let index = ObstacleWaypointSearch.targetIndex(in: plan.points, pose: pose, view: view, normal: ref.plane.normal) else { return false }
        let points = Array(plan.points.prefix(index+1))
        let target = points[index]
        goal = .init(id: r.frameID, epoch: r.epoch, point: target, plane: ref.plane,
                     selectedAt: r.timestamp, maxDistance: options.forwardBufferLength)
        current = .init(id: r.frameID, epoch: r.epoch, parameterVersion: r.parameterVersion,
            sourceFrameID: r.frameID, validatedFrameID: r.frameID, observedAt: r.timestamp,
            plane: ref.plane, points: points, source: r.source, requiredWidth: options.minimumWidth,
            planningPolicy: .obstacleVeto, verifiedEvidence: false, worldLocked: true,
            forwardStrategy: true, footAtPlan: ref.plane.project(pose.position), targetRange: options.forwardBufferLength)
        continuation = Array(plan.points.dropFirst(index))
        side = plan.side
        return true
    }

    private mutating func refreshPreview(raster: RoutePlanningGrid, reference: ForwardRouteReference,
                                        obstacle: ForwardObstacle, result r: AnalysisResult, options: PathOptions) {
        guard let target = goal else { return }
        let invalid = preview.map { !raster.supports($0.points) } ?? true
        guard invalid || previewAt.map({ r.timestamp-$0 >= options.waypoints.previewInterval }) ?? true else { return }
        // Preserve the geometric bend sequence if still applicable; replace any blocked
        // suffix before arrival. This buffer never appears in path.points or speech.
        if continuation.count >= 2, raster.supports(continuation) {
            preview = .init(points: continuation, side: side)
        } else {
            preview = ObstacleWaypointSearch.avoid(raster: raster, reference: reference,
                obstacle: obstacle, foot: target.point, preferredSide: side)
        }
        previewAt = preview == nil ? nil : r.timestamp
    }

    private mutating func output(result r: AnalysisResult, options: PathOptions, scenario state: ObstacleRouteScenario,
                                 obstacle: ForwardObstacle?, reason: String, replan: String?, view: RouteCameraView?) -> PathUpdate {
        if current != nil { current?.validatedFrameID = r.frameID; current?.observedAt = r.timestamp }
        var update = PathUpdate(path: current, reason: reason)
        update.goal = goal
        update.goalChangeReason = replan
        var diagnostics = ForwardStrategyDiagnostics()
        diagnostics.reference = reference
        diagnostics.mode = state == .blocked ? .blocked : state == .nearObstacle ? .detour : .straight
        diagnostics.maneuverID = current?.id; diagnostics.side = side
        diagnostics.triggerDistance = obstacle?.distance; diagnostics.obstacleWidth = obstacle?.width
        diagnostics.turnDwell = turn.elapsed; diagnostics.routePointCount = current?.points.count
        update.strategy = diagnostics
        let visible = goal.flatMap { g in r.sourcePose.flatMap { pose in view.map { $0.contains(g.point + g.plane.normal*0.025, pose: pose) } } }
        update.waypointGuidance = .init(scenario: state, obstacleDistance: obstacle?.distance,
            nextTarget: preview.flatMap { $0.points.count >= 2 ? $0.points[1] : nil }, nextPreparedAt: previewAt,
            replanReason: replan, targetInView: visible, stationaryTurnSeconds: turn.elapsed,
            referenceForward: reference?.forward ?? V3(0,0,-1))
        if let target = goal, let pose = r.sourcePose, let basis = GroundBasis(plane: target.plane, pose: pose) {
            let local = basis.local(target.point)
            update.targetBearingDegrees = atan2(local.x, local.z)*180 / .pi
            update.targetGroundDistance = hypot(local.x, local.z)
        }
        lastUpdate = update
        return update
    }
}
