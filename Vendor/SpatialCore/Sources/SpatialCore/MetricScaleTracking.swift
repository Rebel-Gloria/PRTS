import Foundation
import simd

/// One model output and its independently measured native references. Never stores RGB.
public struct MetricScaleFrame: Sendable {
    public let timestamp: Double
    public let epoch: UInt64, parameterVersion: UInt64
    public let orientation: ImageOrientation
    public let intrinsics: CameraIntrinsics, pose: RigidPose
    public let relative: [Float], samples: [ScaleSample]
    public let fit: InverseDepthCalibration?
    public init(timestamp: Double,epoch: UInt64,parameterVersion: UInt64,orientation: ImageOrientation,
                intrinsics: CameraIntrinsics,pose: RigidPose,relative: [Float],samples: [ScaleSample],fit: InverseDepthCalibration?) {
        self.timestamp = timestamp; self.epoch = epoch; self.parameterVersion = parameterVersion; self.orientation = orientation
        self.intrinsics = intrinsics; self.pose = pose; self.relative = relative; self.samples = samples; self.fit = fit
    }
}

public struct MetricScaleDecision: Codable, Sendable {
    public var confirmations = 0
    public var requiredConfirmations = 3
    public var reason = "no_previous_metric_reference"
    public var projectedReferences = 0
    public var evaluatedReferences = 0
    public var matchingFeatureIDs = 0
    public var referenceConflicts = 0
    public var inliers = 0
    public var spatialBins = 0
    public var evaluatedSpatialBins = 0
    public var medianRelativeError: Float?
    public var referenceAge: Double?
    public var calibration: InverseDepthCalibration?
    public var invalidatesHistory: Bool { reason == "metric_world_reference_conflict" }
    public init() {}
}

/// Validate physical correspondences, NOT identical raw q across normalized model outputs.
/// Every published map uses a NEW, valid per-frame fit. Missing/bad fits never inherit coefficients.
public struct MetricScaleTracker: Sendable {
    private var previous: MetricScaleFrame?
    private var confirmations = 0
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func update(_ frame: MetricScaleFrame) -> MetricScaleDecision {
        var d = MetricScaleDecision()
        guard let fit = frame.fit,frame.intrinsics.width > 0,frame.intrinsics.height > 0,
              frame.relative.count == frame.intrinsics.width*frame.intrinsics.height else {
            reset(); d.reason = "current_metric_fit_unavailable"; return d
        }
        defer { previous = frame }
        guard let old = previous,let oldFit = old.fit else {
            confirmations = 1; d.confirmations = 1; return d
        }
        let dt = frame.timestamp-old.timestamp
        d.referenceAge = dt
        guard old.epoch == frame.epoch,old.parameterVersion == frame.parameterVersion,old.orientation == frame.orientation,
              dt > 0,dt < 0.5,simd_distance(old.pose.position,frame.pose.position) <= 0.75 else {
            confirmations = 1; d.confirmations = 1; d.reason = "reference_time_pose_or_session_barrier"; return d
        }
        let k = frame.intrinsics
        // IDs validate native-map continuity where available. Older DIAG lacks IDs; it can
        // still replay the SAME world-reference reprojection branch, explicitly labelled.
        var currentIDs: [UInt64:ScaleSample] = [:]
        for sample in frame.samples { if let id = sample.featureID { currentIDs[id] = sample } }
        var errors: [Float] = [], bins = Set<Int>(), evaluatedBins = Set<Int>(), pixels = Set<Int>()
        for sample in old.samples {
            guard sample.meters.isFinite,sample.meters >= 0.3,sample.meters <= 8,
                  sample.u.isFinite,sample.v.isFinite,sample.u >= 0,sample.u <= 1,sample.v >= 0,sample.v <= 1,
                  let oldDepth = oldFit.meters(sample.relative),abs(oldDepth-sample.meters)/sample.meters < 0.15 else { continue }
            let world = old.pose.world(old.intrinsics.unproject(u:sample.u*Float(old.intrinsics.width),v:sample.v*Float(old.intrinsics.height),depth:sample.meters))
            let point = frame.pose.camera(world), expected = -point.z
            guard expected >= 0.3,expected <= 8,let uv = k.project(point),uv.x >= 1,uv.y >= 1,
                  uv.x < Float(k.width-2),uv.y < Float(k.height-2) else { continue }
            let x = Int(uv.x.rounded()),y = Int(uv.y.rounded())
            // Do not multiply evidence from several references landing on the same pixel.
            guard pixels.insert(y*k.width+x).inserted else { continue }
            d.projectedReferences += 1
            let bin = min(3,x*4/k.width)+4*min(3,y*4/k.height)
            if let id = sample.featureID,let current = currentIDs[id] {
                d.matchingFeatureIDs += 1
                let currentWorld = frame.pose.world(k.unproject(u:current.u*Float(k.width),v:current.v*Float(k.height),depth:current.meters))
                if !current.meters.isFinite || !current.u.isFinite || !current.v.isFinite || simd_distance(currentWorld,world) > max(0.08,0.015*expected) {
                    d.referenceConflicts += 1; errors.append(1); evaluatedBins.insert(bin); continue
                }
            }
            // Outside this frame's calibrated q range means unknown pixels, not a global
            // scale jump. Enough OTHER distributed references must still validate the fit.
            guard let currentDepth = fit.meters(frame.relative[y*k.width+x]) else { continue }
            let error = abs(currentDepth-expected)/expected
            errors.append(error); evaluatedBins.insert(bin)
            if error < 0.2 {
                d.inliers += 1
                bins.insert(bin)
            }
        }
        d.evaluatedReferences = errors.count; d.spatialBins = bins.count; d.evaluatedSpatialBins = evaluatedBins.count
        let sorted = errors.sorted()
        d.medianRelativeError = sorted.isEmpty ? nil : sorted[sorted.count/2]
        let adequate = d.inliers >= 16 && bins.count >= 6
        let consistent = adequate && Float(d.inliers)/Float(max(1,errors.count)) >= 0.65 && (d.medianRelativeError ?? 1) < 0.08
        if consistent {
            confirmations = min(3,confirmations+1)
            d.reason = confirmations >= 3 ? "world_reprojection_confirmed" : "world_reprojection_confirming"
        } else {
            confirmations = 1
            d.reason = errors.count >= 16 && evaluatedBins.count >= 6 && (Float(d.inliers)/Float(errors.count) < 0.65 || (d.medianRelativeError ?? 1) >= 0.08)
                ? "metric_world_reference_conflict" : "insufficient_distributed_world_overlap"
        }
        d.confirmations = confirmations
        d.calibration = confirmations >= 3 ? fit : nil
        return d
    }
}
