import Foundation
import simd

public struct PathPresentation: Sendable {
    public var path: PredictedPath
    public var age: Double
    public var historical: Bool
    // Visual-only feet projection to observed path entry. Unknown is explicit.
    public var approach: [V3] = []
    public static func make(
        path: PredictedPath,
        gate: ResultPresentationGate,
        pose: RigidPose,
        options: PathOptions,
        now: Double
    ) -> Self? {
        guard options.enabled, gate.enabled, gate.trackingNormal,
            path.epoch == gate.epoch, path.parameterVersion == gate.parameterVersion,
            path.sourceFrameID >= gate.minimumGeometryFrameID,
            path.validatedFrameID <= gate.frameID,
            now.isFinite, now >= gate.frameTimestamp, now - gate.frameTimestamp <= gate.maxAge,
            now >= path.observedAt,
            (path.planningPolicy == .obstacleVeto
                || now - path.observedAt <= options.validated().retentionSeconds),
            (path.verifiedEvidence == true
                || abs(path.requiredWidth - options.validated().minimumWidth) < 0.001),
            path.points.count >= 2
        else { return nil }
        if path.verifiedEvidence != true && path.planningPolicy != .obstacleVeto,
            let goal = path.points.last
        {
            let distance = simd_distance(path.plane.project(pose.position), goal)
            guard distance > options.validated().arrivalRadius,
                distance <= (path.targetRange ?? 4) + 0.2
            else { return nil }
            if path.forwardStrategy != true, let basis = GroundBasis(plane: path.plane, pose: pose)
            {
                let p = basis.local(goal)
                guard
                    abs(atan2(p.x, p.z) * 180 / .pi) <= options.validated().targetHalfAngleDegrees
                        + 5
                else { return nil }
            }
        }
        // Drawing a world line must NOT depend on a reliable phone heading. Near-vertical
        // pitch pauses haptics, but visible parts still reproject correctly while tracked.
        guard let evidenced = RouteEvidencePresentation.validPrefix(path, now: now) else {
            return nil
        }
        let points =
            (path.verifiedEvidence == true || path.planningPolicy == .obstacleVeto)
            ? evidenced.points : PathTracking.remaining(path.points, plane: path.plane, pose: pose)
        guard points.count >= 2 else { return nil }
        let origin = path.plane.project(pose.position)
        let tangent = simd_normalize(points[1] - points[0])
        let lateral = abs(simd_dot(origin - points[0], simd_cross(tangent, path.plane.normal)))
        guard lateral.isFinite else { return nil }
        if path.planningPolicy != .obstacleVeto {
            guard lateral <= 1.0, simd_distance(origin, points[0]) <= 5 else { return nil }
        }
        var visiblePath = evidenced
        visiblePath.points = points
        return .init(
            path: visiblePath,
            age: now - path.observedAt,
            historical: path.verifiedEvidence == true
                ? (evidenced.evidenceIntervals?.contains { now - $0.observedAt > gate.maxAge }
                    ?? false) : now - path.observedAt > gate.maxAge,
            approach: simd_distance(origin, points[0]) > 0.03 ? [origin, points[0]] : []
        )
    }
}
