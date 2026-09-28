import Foundation

/// Separate display-only policy: never routes, never certifies clearance from network predictions.
public enum PredictedGeometry {
    public static func analyze(_ o: DepthObservation, ground: NativePlaneObservation?, parameters p: ProbeParameters,
                               parameterVersion: UInt64,groundReference: NativeGroundSelection? = nil) -> AnalysisResult {
        let start = ProcessInfo.processInfo.systemUptime
        var r = AnalysisResult(epoch:o.epoch,frameID:o.frameID,timestamp:o.timestamp,parameters:p,parameterVersion:parameterVersion,
            status:"预测深度：等待原生地面参考；通道未知",source:"coreml_relative_arkit_aligned_display_only")
        r.diagnostics = AnalysisDiagnostics(); r.diagnostics?.confidenceReadStatus = "not_provided_by_model"; r.diagnostics?.groundReferenceMode = "native_plane_prediction_display_only"
        if let reference = groundReference {
            r.diagnostics?.groundReferenceMode = reference.mode == "retained_reference" ? "retained_native_reference" : "native_\(reference.mode)"
            r.diagnostics?.groundReferenceAge = reference.age
        }
        r.sourcePose = o.pose; r.sourceDirectionStable = false
        r.validDepthCoverage = o.coverage(parameters:p)
        guard o.isPrediction,o.structurallyValid,let ground,
              let basis = GroundBasis.geometry(plane:ground.ground,pose:o.pose,previousForward:nil) else { return r }
        let plane = ground.ground,points = o.points(parameters:p)
        var grid = GridBuilder.build(points:points,observation:o,plane:plane,basis:basis,parameters:p)
        // Defense in depth even if the visibility implementation changes later.
        for i in grid.cells.indices where grid.cells[i].state == .candidate {
            grid.cells[i].state = .unknown; grid.cells[i].reason = .groundUnconfirmed
        }
        r.plane = plane; r.grid = grid; r.footprintMask = Array(repeating:false,count:grid.cells.count)
        r.stageMilliseconds["groundGrid"] = (ProcessInfo.processInfo.systemUptime-start)*1000
        let modelStart = ProcessInfo.processInfo.systemUptime
        r.surfaceModel = SurfaceModelBuilder.build(observation:o,plane:plane,grid:grid,groundConfirmed:true,parameters:p)
        r.stageMilliseconds["surfaceModel"] = (ProcessInfo.processInfo.systemUptime-modelStart)*1000
        r.diagnostics?.modelState = r.surfaceModel == nil ? "blocked" : r.surfaceModel?.triangles.isEmpty == true ? "built_empty" : "built"
        r.status = ground.classification == "floor" ? "原生 floor＋预测几何；非测量深度，通道未知" : "待确认水平面＋预测几何；未确认地面，通道未知"
        if groundReference?.mode == "retained_reference" { r.status = "短时原生地面参考＋当前预测几何；非实时地面确认，通道未知" }
        r.stageMilliseconds["analysisTotal"] = (ProcessInfo.processInfo.systemUptime-start)*1000
        return r
    }
}
