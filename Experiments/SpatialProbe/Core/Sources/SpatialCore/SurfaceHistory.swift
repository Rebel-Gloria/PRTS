import Foundation
import simd

public struct SurfacePresentation: Sendable {
    public var result: AnalysisResult
    public var historical: Bool
    public var age: Double
}

/// One bounded world-space snapshot. History is WIREFRAME ONLY, never a grid, exclusion volume,
/// distance or candidate route. Current empty geometry contradicts history and clears it.
public struct SurfaceHistory: Sendable {
    public static let maximumAge: Double = 1
    private var stored: AnalysisResult?
    private var latestFrame: UInt64 = 0
    private var epoch: UInt64 = 0,version: UInt64 = 0
    public init() {}
    public mutating func reset() { stored = nil; latestFrame = 0 }
    public mutating func ingest(_ result: AnalysisResult) {
        if epoch != result.epoch || version != result.parameterVersion {
            reset(); epoch = result.epoch; version = result.parameterVersion
        }
        guard result.frameID > latestFrame else { return }
        latestFrame = result.frameID
        if result.diagnostics?.groundReferenceInvalidation != nil { stored = nil }
        if let model = result.surfaceModel {
            stored = model.triangles.isEmpty ? nil : result
        }
    }
    public func presentation(current: AnalysisResult?,gate: ResultPresentationGate,pose: RigidPose?,now: Double) -> SurfacePresentation? {
        if let current,gate.allowsGeometry(current,now:now),current.surfaceModel != nil {
            return .init(result:current,historical:false,age:now-current.timestamp)
        }
        guard let stored,let origin = stored.sourcePose,let pose,
              gate.historyBlockReason(stored,now:now) == nil,
              simd_distance(pose.position,origin.position) <= 0.75 else { return nil }
        if let reference = stored.diagnostics?.groundReference,
           now-reference.observedAt > GroundReferenceTracker.maximumAge { return nil }
        return .init(result:stored,historical:true,age:now-stored.timestamp)
    }
}
