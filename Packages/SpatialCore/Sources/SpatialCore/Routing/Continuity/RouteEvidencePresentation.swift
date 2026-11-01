import Foundation
import simd

public enum RouteEvidencePresentation {
    /// Evidence expiration cuts only the affected suffix. Publication never renews proof time.
    public static func validPrefix(_ path: PredictedPath, now: Double) -> PredictedPath? {
        if path.planningPolicy == .obstacleVeto { return path }
        guard path.verifiedEvidence == true else { return path }
        guard let evidence = path.evidenceIntervals, now.isFinite else { return nil }
        var end: Float = 0
        for sample in evidence {
            guard sample.observedAt <= now, now <= sample.validUntil else { break }
            end = sample.endS
        }
        guard end > 0.03 else { return nil }
        var copy = path
        copy.points = RouteArc.prefix(path.points, length: end)
        copy.evidenceIntervals = evidence.filter { $0.endS <= end }
        return copy.points.count >= 2 ? copy : nil
    }
}
