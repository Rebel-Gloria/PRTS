import Foundation
import simd

/// A measured, confirmed world-space reference, never an occupancy/free-space observation.
public struct GroundReference: Codable, Sendable {
    public var plane: GroundPlane
    public var observedAt: Double
    public var frameID: UInt64
    public var epoch: UInt64
    public var parameterVersion: UInt64
    public var cameraPosition: V3
}

public struct GroundReferenceSelection: Sendable {
    public var reference: GroundReference?
    public var currentConfirmed: Bool
    public var confirmations: Int
    public var invalidation: String?
}

/// Analysis-worker owned. Missing ground resets current confirmation, not the last measured plane.
/// Cached references expire from their ORIGINAL observation, never from reuse or mesh callbacks.
public struct GroundReferenceTracker: Sendable {
    public static let maximumAge: Double = 2
    public static let maximumTranslation: Float = 1
    private var reference: GroundReference?
    private var previousPlane: GroundPlane?
    private var previousTime: Double = 0
    private var confirmations = 0
    private var epoch: UInt64 = 0,version: UInt64 = 0
    public init() {}
    public mutating func reset() { reference = nil; previousPlane = nil; previousTime = 0; confirmations = 0 }
    public mutating func update(fitted: GroundPlane?,pose: RigidPose,time: Double,frameID: UInt64,
                                epoch: UInt64,parameterVersion: UInt64) -> GroundReferenceSelection {
        var invalidation: String?
        if self.epoch != epoch || version != parameterVersion {
            reset(); self.epoch = epoch; version = parameterVersion; invalidation = "session_or_parameters_changed"
        }
        guard time.isFinite,pose.position.x.isFinite,pose.position.y.isFinite,pose.position.z.isFinite else {
            reset(); return .init(reference:nil,currentConfirmed:false,confirmations:0,invalidation:"invalid_pose_or_clock")
        }
        if let old = reference {
            if time < old.observedAt || time-old.observedAt > Self.maximumAge { invalidation = "reference_expired_or_clock_reversed" }
            else if simd_distance(pose.position,old.cameraPosition) > Self.maximumTranslation ||
                abs(simd_dot(pose.position-old.cameraPosition,old.plane.normal)) > 0.35 { invalidation = "reference_motion_limit" }
            else if let fitted,fitted.floorPriorConfirmed,
                    abs(fitted.height(pose.position)-old.plane.height(pose.position)) > 0.12 ||
                    simd_dot(fitted.normal,old.plane.normal) < cos(8 * .pi / 180) { invalidation = "reference_conflicts_with_current_floor" }
            if invalidation != nil { reset() }
        }
        if let fitted {
            if let previousPlane,time > previousTime,time-previousTime < 0.3,
               // Compare the same physical location, not plane coefficients at an arbitrary world origin.
               abs(previousPlane.height(pose.position)-fitted.height(pose.position)) < 0.04,
               simd_dot(previousPlane.normal,fitted.normal) > cos(3 * .pi / 180),fitted.floorPriorConfirmed {
                confirmations = min(3,confirmations+1)
            } else { confirmations = fitted.floorPriorConfirmed ? 1 : 0 }
            previousPlane = fitted; previousTime = time
            if confirmations >= 3,fitted.floorPriorConfirmed {
                reference = .init(plane:fitted,observedAt:time,frameID:frameID,epoch:epoch,
                                  parameterVersion:parameterVersion,cameraPosition:pose.position)
                return .init(reference:reference,currentConfirmed:true,confirmations:confirmations,invalidation:invalidation)
            }
        } else { previousPlane = nil; previousTime = 0; confirmations = 0 }
        return .init(reference:reference,currentConfirmed:false,confirmations:confirmations,invalidation:invalidation)
    }
}
