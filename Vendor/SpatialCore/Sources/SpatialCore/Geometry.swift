import Foundation
import simd

public typealias V3 = SIMD3<Float>

public struct RigidPose: Codable, Sendable, Equatable {
    public var right: V3
    public var up: V3
    public var back: V3
    public var position: V3
    public init(right: V3 = V3(1,0,0), up: V3 = V3(0,1,0), back: V3 = V3(0,0,1), position: V3 = .zero) {
        self.right = right; self.up = up; self.back = back; self.position = position
    }
    public func world(_ p: V3) -> V3 { position + right * p.x + up * p.y + back * p.z }
    public func camera(_ p: V3) -> V3 {
        let d = p - position
        return V3(simd_dot(d, right), simd_dot(d, up), simd_dot(d, back))
    }
}

public struct CameraIntrinsics: Codable, Sendable, Equatable {
    public var fx: Float; public var fy: Float; public var cx: Float; public var cy: Float
    public var width: Int; public var height: Int
    public init(fx: Float, fy: Float, cx: Float, cy: Float, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy; self.width = width; self.height = height
    }
    // Integer pixel coordinates denote pixel centers. Normalized texture UV is (pixel + 0.5) / size.
    public func scaled(width: Int, height: Int) -> CameraIntrinsics {
        let sx = Float(width) / Float(self.width), sy = Float(height) / Float(self.height)
        return .init(fx: fx*sx, fy: fy*sy, cx: (cx+0.5)*sx-0.5, cy: (cy+0.5)*sy-0.5, width: width, height: height)
    }
    public func unproject(u: Float, v: Float, depth: Float) -> V3 {
        // Computer-vision (+x right,+y down,+z forward) -> ARKit (+x right,+y up,-z forward).
        V3((u-cx)*depth/fx, -(v-cy)*depth/fy, -depth)
    }
    public func project(_ cameraPoint: V3) -> SIMD2<Float>? {
        let z = -cameraPoint.z
        guard z > 0.001, z.isFinite else { return nil }
        return SIMD2(fx*cameraPoint.x/z+cx, -fy*cameraPoint.y/z+cy)
    }
}

public enum ImageOrientation: Int, Codable, Sendable, CaseIterable {
    case landscapeRight, portrait, landscapeLeft, portraitUpsideDown
    public var swapsAxes: Bool { self == .portrait || self == .portraitUpsideDown }
    public func orientedUV(_ p: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .landscapeRight: p
        case .portrait: SIMD2(1-p.y, p.x)
        case .landscapeLeft: SIMD2(1-p.x, 1-p.y)
        case .portraitUpsideDown: SIMD2(p.y, 1-p.x)
        }
    }
    public func imageUV(_ p: SIMD2<Float>) -> SIMD2<Float> {
        switch self {
        case .landscapeRight: p
        case .portrait: SIMD2(p.y, 1-p.x)
        case .landscapeLeft: SIMD2(1-p.x, 1-p.y)
        case .portraitUpsideDown: SIMD2(1-p.y, p.x)
        }
    }
}

public struct FitRect: Sendable, Equatable {
    public let x: Float, y: Float, width: Float, height: Float
    public init(imageWidth: Float, imageHeight: Float, viewportWidth: Float, viewportHeight: Float) {
        let scale = min(viewportWidth / max(imageWidth, 1), viewportHeight / max(imageHeight, 1))
        width = imageWidth * scale; height = imageHeight * scale
        x = (viewportWidth-width)/2; y = (viewportHeight-height)/2
    }
}

public struct GroundPlane: Codable, Sendable {
    public var normal: V3
    public var offset: Float
    public var residual: Float
    public var supportCount: Int
    public var supportArea: Float
    public var floorPriorConfirmed: Bool
    public func height(_ p: V3) -> Float { simd_dot(normal, p) + offset }
    public func project(_ p: V3) -> V3 { p - normal * height(p) }
    public init(normal: V3, offset: Float, residual: Float = 0, supportCount: Int = 0, supportArea: Float = 0, floorPriorConfirmed: Bool = false) {
        self.normal = normal; self.offset = offset; self.residual = residual
        self.supportCount = supportCount; self.supportArea = supportArea; self.floorPriorConfirmed = floorPriorConfirmed
    }
}

public struct GroundBasis: Codable, Sendable {
    public var origin: V3; public var right: V3; public var forward: V3; public var normal: V3
    public init?(plane: GroundPlane, pose: RigidPose) {
        normal = plane.normal; origin = plane.project(pose.position)
        let f = -pose.back; let projected = f - normal * simd_dot(f, normal)
        guard simd_length(projected) >= 0.5 else { return nil }
        forward = simd_normalize(projected); right = simd_normalize(simd_cross(forward, normal))
    }
    /// Geometry needs a ground-tangent basis, not a reliable human heading. The strict initializer
    /// above remains the ONLY basis authorizing directional guidance. No ground evidence is added.
    public static func geometry(plane: GroundPlane,pose: RigidPose,previousForward: V3?) -> GroundBasis? {
        let n = plane.normal,f = -pose.back,projected = f-n*simd_dot(f,n)
        let seeds = simd_length(projected) >= 0.1 ? [projected] : [previousForward ?? .zero,V3(0,0,-1),V3(1,0,0)]
        for seed in seeds {
            let tangent = seed-n*simd_dot(seed,n)
            if simd_length(tangent) >= 0.1 {
                // Construct through the strict initializer with a synthetic orientation ONLY for
                // the mathematical basis; the measured camera pose and all ray tests stay unchanged.
                var referencePose = pose; referencePose.back = -simd_normalize(tangent)
                return GroundBasis(plane:plane,pose:referencePose)
            }
        }
        return nil
    }
    public func local(_ p: V3) -> V3 {
        let d = p - origin
        return V3(simd_dot(d,right), simd_dot(d,normal), simd_dot(d,forward))
    }
    public func world(x: Float, h: Float, z: Float) -> V3 { origin + right*x + normal*h + forward*z }
}

public struct ProbeParameters: Codable, Sendable, Equatable {
    public var gridSize: Float = 0.10
    public var forwardRange: Float = 4
    public var halfWidth: Float = 1.5
    public var bodyWidth: Float = 0.60
    public var sideMargin: Float = 0.15
    public var bodyHeight: Float = 1.80
    public var planeTolerance: Float = 0.03
    public var maxPlaneTiltDegrees: Float = 12
    public var samplingStep: Int = 2
    public var processingHz: Double = 10
    public var maxResultAge: Double = 0.25
    public var maxDepth: Float = 5
    public var minDepth: Float = 0.15
    public var depthMargin: Float = 0.05
    public var maxAngularSpeed: Float = 30
    public var stableDuration: Double = 0.5
    public init() {}
    public var requiredWidth: Float { bodyWidth + 2*sideMargin }
    public func validated() -> ProbeParameters {
        var p = self
        p.gridSize = 0.1; p.forwardRange = 4; p.halfWidth = 1.5
        p.bodyWidth = min(1.2,max(0.3,bodyWidth)); p.sideMargin = min(0.5,max(0.05,sideMargin))
        p.bodyHeight = min(2.4,max(1.0,bodyHeight)); p.samplingStep = min(8,max(1,samplingStep))
        p.processingHz = min(20,max(2,processingHz)); p.planeTolerance = min(0.05,max(0.01,planeTolerance))
        p.maxResultAge = min(0.25,max(0.05,maxResultAge))
        return p
    }
}
