import Foundation
import simd

/// Fast rejection reuses confidence/cluster checks. It is independent of the slow side latch.
public enum RouteSafety {
    public static func invalidationReason(
        _ path: PredictedPath,
        result: AnalysisResult,
        observation: DepthObservation?,
        includeCurrentObstacles: Bool = true
    ) -> String? {
        if let reason = result.diagnostics?.groundReferenceInvalidation { return reason }
        if let plane = result.plane, let pose = result.sourcePose,
            ["current_confirmed", "native_confirmed"].contains(
                result.diagnostics?.groundReferenceMode ?? ""
            ),
            abs(plane.height(path.plane.project(pose.position))) > 0.12
                || simd_dot(plane.normal, path.plane.normal) < 0.97
        {
            return "ground_reference_conflict"
        }
        return includeCurrentObstacles && conflicts(path, result: result, observation: observation)
            ? "current_hazard" : nil
    }

    public static func conflicts(
        _ path: PredictedPath,
        result: AnalysisResult,
        observation: DepthObservation?
    ) -> Bool {
        PathObstacleCheck.intersects(
            path,
            result: result,
            observation: observation,
            includeApproach: false
        )
    }
}
