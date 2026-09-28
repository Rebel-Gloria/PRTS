import Foundation
import simd

/// A diagnostic model of visible measured surfaces, NOT a watertight object reconstruction.
public enum ObservedSurface: String, Codable, Sendable { case ground, protrusion }

public struct SurfaceTriangle: Codable, Sendable {
    public var a: V3
    public var b: V3
    public var c: V3
    public var surface: ObservedSurface
}

public struct SurfaceModelSummary: Codable, Sendable {
    public var groundTriangles: Int
    public var protrusionTriangles: Int
    public var minimumProtrusionHeight: Float
    public var maximumObservedProtrusionHeight: Float?
    public var samplingStep: Int
    public var blockingVolume: BlockingVolumeSummary? = nil
}

public struct SurfaceModel: Codable, Sendable {
    public var triangles: [SurfaceTriangle]
    public var summary: SurfaceModelSummary
    public var blockingVolume: BlockingVolumeModel? = nil
}

public enum SurfaceModelBuilder {
    public static let minimumProtrusionHeight: Float = 0.05
    // 256x192 with step 2 has 24,130 triangles. The former 12k budget silently forced step 3.
    public static let triangleBudget = 24_576
    public static let maximumEdge: Float = 0.15
    public static let maximumDepthJump: Float = 0.08

    public static func samplingStep(width: Int,height: Int,requested: Int) -> Int {
        var step = max(1,requested)
        while 2*(max(0,width-1)/step)*(max(0,height-1)/step) > triangleBudget { step += 1 }
        return step
    }

    /// All classification uses signed height above a confirmed plane, not ARKit object labels.
    /// Sampling affects mesh detail only. Every original pixel in a coarse patch is checked,
    /// so triangles never bridge a missing/low-confidence pixel or a ground/protrusion boundary.
    public static func build(observation o: DepthObservation, plane: GroundPlane, grid: LocalGrid,
                             groundConfirmed: Bool, parameters p: ProbeParameters) -> SurfaceModel? {
        guard groundConfirmed,(plane.floorPriorConfirmed || o.isPrediction),o.structurallyValid,o.hasGeometricSupport,
              grid.epoch == o.epoch,grid.frameID == o.frameID,grid.timestamp == o.timestamp else { return nil }
        let threshold = max(minimumProtrusionHeight,p.planeTolerance+0.02)
        let step = samplingStep(width:o.width,height:o.height,requested:p.samplingStep)
        var points = [V3?](repeating:nil,count:o.width*o.height)
        var kinds = [ObservedSurface?](repeating:nil,count:points.count)
        for v in 0..<o.height { for u in 0..<o.width {
            let i = v*o.width+u
            guard o.valid(i,parameters:p) else { continue }
            let world = o.pose.world(o.intrinsics.unproject(u:Float(u),v:Float(v),depth:o.depth[i]))
            let local = grid.basis.local(world)
            guard let cell = grid.index(x:local.x,z:local.z) else { continue }
            let evidence = grid.cells[cell]
            if abs(local.y) <= p.planeTolerance,evidence.groundSamples >= 3 {
                kinds[i] = .ground
            } else if local.y >= threshold,local.y < p.bodyHeight+p.depthMargin,
                      evidence.state == .obstacle,evidence.obstacleSamples >= 3 {
                kinds[i] = .protrusion
            }
            if kinds[i] != nil { points[i] = world }
        }}
        var triangles: [SurfaceTriangle] = []
        triangles.reserveCapacity(min(triangleBudget,2*points.count/(step*step)))
        var groundCount = 0,protrusionCount = 0
        var maximumHeight: Float?
        if o.width > step,o.height > step {
            for v in stride(from:0,to:o.height-step,by:step) {
                for u in stride(from:0,to:o.width-step,by:step) {
                    let tl = v*o.width+u,tr = tl+step,bl = (v+step)*o.width+u,br = bl+step
                    guard let kind = kinds[tl],kinds[tr] == kind,kinds[bl] == kind,kinds[br] == kind,
                          let a = points[tl],let b = points[tr],let c = points[bl],let d = points[br] else { continue }
                    var continuous = true,minDepth = Float.greatestFiniteMagnitude,maxDepth: Float = 0
                    for y in v...(v+step) {
                        for x in u...(u+step) {
                            let i = y*o.width+x
                            if kinds[i] != kind { continuous = false; break }
                            minDepth = min(minDepth,o.depth[i]); maxDepth = max(maxDepth,o.depth[i])
                        }
                        if !continuous { break }
                    }
                    guard continuous,maxDepth-minDepth <= maximumDepthJump,
                          simd_distance(a,b) <= maximumEdge,simd_distance(a,c) <= maximumEdge,
                          simd_distance(b,c) <= maximumEdge,simd_distance(b,d) <= maximumEdge,
                          simd_distance(c,d) <= maximumEdge,
                          simd_length(simd_cross(b-a,c-a)) > 0.000001,
                          simd_length(simd_cross(d-b,c-b)) > 0.000001 else { continue }
                    triangles.append(.init(a:a,b:b,c:c,surface:kind))
                    triangles.append(.init(a:b,b:d,c:c,surface:kind))
                    if kind == .ground { groundCount += 2 }
                    else {
                        protrusionCount += 2
                        for point in [a,b,c,d] { maximumHeight = max(maximumHeight ?? 0,plane.height(point)) }
                    }
                }
            }
        }
        let blocking = BlockingVolumeBuilder.build(grid:grid,groundConfirmed:groundConfirmed,parameters:p)
        return SurfaceModel(triangles:triangles,summary:.init(groundTriangles:groundCount,
            protrusionTriangles:protrusionCount,minimumProtrusionHeight:threshold,
            maximumObservedProtrusionHeight:maximumHeight,samplingStep:step,blockingVolume:blocking?.summary),blockingVolume:blocking)
    }
}
