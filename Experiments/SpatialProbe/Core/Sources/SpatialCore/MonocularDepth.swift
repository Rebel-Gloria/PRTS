import Foundation
import simd

/// Hardware capability, not a guessed device name. Forced mode cannot be switched off.
public struct DepthBackendPolicy: Equatable, Sendable {
    public let supportsSceneDepth: Bool
    public var requestedSimulation: Bool
    public init(supportsSceneDepth: Bool, requestedSimulation: Bool) {
        self.supportsSceneDepth = supportsSceneDepth; self.requestedSimulation = requestedSimulation
    }
    public var usesMonocular: Bool { !supportsSceneDepth || requestedSimulation }
    public var switchEnabled: Bool { supportsSceneDepth }
}

/// Core ML image input uses a letterboxed image. Coordinates here use integer pixel centers.
public struct ModelImageMapping: Sendable {
    public let width: Int, height: Int, modelWidth: Int, modelHeight: Int
    public let orientation: ImageOrientation
    public init(width: Int, height: Int, modelWidth: Int, modelHeight: Int, orientation: ImageOrientation) {
        self.width = width; self.height = height; self.modelWidth = modelWidth; self.modelHeight = modelHeight; self.orientation = orientation
    }
    public var fit: FitRect {
        FitRect(imageWidth:Float(orientation.swapsAxes ? height : width),imageHeight:Float(orientation.swapsAxes ? width : height),viewportWidth:Float(modelWidth),viewportHeight:Float(modelHeight))
    }
    public func modelPixel(u: Float, v: Float) -> SIMD2<Float> {
        let uv = orientation.orientedUV(SIMD2((u+0.5)/Float(width),(v+0.5)/Float(height)))
        return SIMD2(fit.x+uv.x*fit.width-0.5,fit.y+uv.y*fit.height-0.5)
    }
}

public struct NativePlaneObservation: Codable, Sendable {
    public var id: String, classification: String
    public var pose: RigidPose
    public var boundary: [V3]
    public var timestamp: Double
    public init(id: String, classification: String, pose: RigidPose, boundary: [V3], timestamp: Double) {
        self.id = id; self.classification = classification; self.pose = pose; self.boundary = boundary; self.timestamp = timestamp
    }
    public var normal: V3 { pose.up.y >= 0 ? pose.up : -pose.up }
    public var area: Float {
        guard boundary.count >= 3 else { return 0 }
        var sum: Float = 0
        for i in boundary.indices { let a = boundary[i], b = boundary[(i+1)%boundary.count]; sum += a.x*b.z-b.x*a.z }
        return abs(sum)/2
    }
    public func contains(_ world: V3) -> Bool {
        let p = pose.camera(world)
        guard boundary.count >= 3 else { return false }
        var inside = false
        var j = boundary.count-1
        for i in boundary.indices {
            let a = boundary[i], b = boundary[j]
            if (a.z > p.z) != (b.z > p.z), p.x < (b.x-a.x)*(p.z-a.z)/(b.z-a.z)+a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    public var ground: GroundPlane {
        GroundPlane(normal:normal,offset:-simd_dot(normal,pose.position),floorPriorConfirmed:classification == "floor")
    }
    public func rayDepth(u: Float,v: Float,intrinsics: CameraIntrinsics,camera: RigidPose) -> Float? {
        let ray = camera.world(intrinsics.unproject(u:u,v:v,depth:1))-camera.position
        let denominator = simd_dot(normal,ray)
        guard abs(denominator) > 0.08 else { return nil }
        let depth = -ground.height(camera.position)/denominator
        guard depth > 0.3,depth < 8,contains(camera.position+ray*depth) else { return nil }
        return depth
    }
}

/// The state of a bounded native reference, not the age of a surface observation.
public struct NativeGroundSelection: Codable, Sendable {
    public var plane: NativePlaneObservation?
    public var mode: String
    public var age: Double
    public var reason: String
    public init(plane: NativePlaneObservation? = nil,mode: String = "uninitialized",age: Double = 0,reason: String = "no_native_ground") {
        self.plane = plane; self.mode = mode; self.age = age; self.reason = reason
    }
    public var canSupplyScaleSamples: Bool { mode == "confirmed" && plane?.classification == "floor" }
}

/// Short retention preserves only a structural REFERENCE. No historical empty-space proof.
public struct NativeGroundTracker: Sendable {
    private var id: String?
    private var since: Double = 0
    private var previous: GroundPlane?
    private var retained: NativePlaneObservation?
    private var referenceTime: Double = 0
    private var referencePose: RigidPose?
    public init() {}
    public mutating func reset() { self = Self() }
    public mutating func select(_ planes: [NativePlaneObservation],camera: RigidPose,time: Double) -> NativePlaneObservation? {
        let result = update(planes,camera:camera,time:time)
        return result.mode == "retained_reference" ? nil : result.plane
    }
    public mutating func update(_ planes: [NativePlaneObservation],camera: RigidPose,time: Double) -> NativeGroundSelection {
        let possible = planes.filter {
            let height = $0.ground.height(camera.position)
            return ($0.classification == "floor" || $0.classification == "unknown") && $0.normal.y > 0.978 &&
                height > 0.45 && height < 2.3 && $0.area >= ($0.classification == "floor" ? 0.3 : 0.7) &&
                time >= $0.timestamp && time-$0.timestamp <= 0.3
        }.sorted {
            if ($0.classification == "floor") != ($1.classification == "floor") { return $0.classification == "floor" }
            return $0.ground.height(camera.position) > $1.ground.height(camera.position)
        }
        guard let selected = possible.first else {
            let contradicted = retained.map { old in planes.contains { $0.id == old.id &&
                ($0.classification != "floor" && $0.classification != "unknown" ||
                 abs($0.ground.height(camera.position)-old.ground.height(camera.position)) > 0.05 ||
                 simd_dot($0.normal,old.normal) < 0.9986) } } ?? false
            if !contradicted,let retained,let referencePose {
                let age = time-referenceTime
                if age >= 0,age <= 2,simd_distance(camera.position,referencePose.position) <= 1,
                   abs(simd_dot(camera.position-referencePose.position,retained.normal)) <= 0.35 {
                    return .init(plane:retained,mode:"retained_reference",age:age,reason:"native_snapshot_missing_bounded_reference_only")
                }
            }
            reset(); return .init(mode:"invalid",reason:contradicted ? "native_ground_conflict" : "reference_missing_or_expired")
        }
        let plane = selected.ground
        let conflict = previous.map { abs($0.height(camera.position)-plane.height(camera.position)) > 0.05 || simd_dot($0.normal,plane.normal) < 0.9986 } ?? false
        if id != selected.id || conflict || time < referenceTime || time-referenceTime > 2 {
            id = selected.id; since = time; retained = nil; referencePose = nil
        }
        previous = plane; referenceTime = time
        guard time-since >= 0.4 else { return .init(mode:"provisional",reason:conflict ? "new_plane_conflict_reconfirming" : "native_plane_stabilizing") }
        retained = selected; referencePose = camera
        return .init(plane:selected,mode:selected.classification == "floor" ? "confirmed" : "provisional_ground",
                     reason:selected.classification == "floor" ? "native_floor_reference" : "unclassified_horizontal_reference")
    }
}

public struct ScaleSample: Codable, Sendable {
    public let relative: Float, meters: Float, u: Float, v: Float
    public let source: String
    public let featureID: UInt64?
    public init(relative: Float,meters: Float,u: Float,v: Float,source: String,featureID: UInt64? = nil) {
        self.relative = relative; self.meters = meters; self.u = u; self.v = v; self.source = source; self.featureID = featureID
    }
}
public struct InverseDepthCalibration: Codable, Sendable {
    public var slope: Float, intercept: Float, center: Float, spread: Float
    public var minimum: Float, maximum: Float
    public var inliers: Int, samples: Int
    public var medianRelativeError: Float
    public func meters(_ raw: Float) -> Float? {
        guard raw.isFinite,raw >= minimum-0.1*(maximum-minimum),raw <= maximum+0.1*(maximum-minimum) else { return nil }
        let inverse = slope*((raw-center)/spread)+intercept
        guard inverse > 0, inverse.isFinite else { return nil }; return 1/inverse
    }
    /// Robust affine inverse-depth alignment to independently observed ARKit geometry.
    /// No hardware-depth input and no known camera-height constant are used.
    public static func fit(_ input: [ScaleSample]) -> Self? {
        let samples = input.filter { $0.relative.isFinite && $0.meters.isFinite && $0.meters >= 0.3 && $0.meters <= 8 && $0.u >= 0 && $0.u <= 1 && $0.v >= 0 && $0.v <= 1 }
        guard samples.count >= 16 else { return nil }
        let values = samples.map(\.relative).sorted(), center = values[values.count/2]
        let spread = values[values.count*9/10]-values[values.count/10]
        guard spread > 0.00001 else { return nil }
        let xs = samples.map { ($0.relative-center)/spread },ys = samples.map { 1/$0.meters }
        var best: [Int] = []
        var seed: UInt64 = 0x5eed
        for _ in 0..<128 {
            seed = seed &* 6364136223846793005 &+ 1; let i = Int((seed >> 32) % UInt64(samples.count))
            seed = seed &* 6364136223846793005 &+ 1; let j = Int((seed >> 32) % UInt64(samples.count))
            guard abs(xs[i]-xs[j]) > 0.2 else { continue }
            let a = (ys[i]-ys[j])/(xs[i]-xs[j]),b = ys[i]-a*xs[i]
            guard a > 0 else { continue }
            let good = samples.indices.filter { let pred = a*xs[$0]+b; return pred > 0 && abs(1/pred-samples[$0].meters)/samples[$0].meters < 0.15 }
            if good.count > best.count { best = good }
        }
        guard best.count >= 16,Float(best.count)/Float(samples.count) >= 0.65 else { return nil }
        let bins = Set(best.map { min(3,Int(samples[$0].u*4))+4*min(3,Int(samples[$0].v*4)) })
        let ds = best.map { samples[$0].meters }.sorted()
        guard bins.count >= 6,ds[ds.count*9/10]-ds[ds.count/10] > 0.35 else { return nil }
        let n = Float(best.count),mx = best.reduce(Float(0)) { $0+xs[$1] }/n,my = best.reduce(Float(0)) { $0+ys[$1] }/n
        let xx = best.reduce(Float(0)) { $0+pow(xs[$1]-mx,2) }
        guard xx > 0.0001 else { return nil }
        let a = best.reduce(Float(0)) { $0+(xs[$1]-mx)*(ys[$1]-my) }/xx,b = my-a*mx
        guard a > 0 else { return nil }
        let residual = best.map { abs(1/(a*xs[$0]+b)-samples[$0].meters)/samples[$0].meters }.sorted()
        guard residual.allSatisfy(\.isFinite),residual[residual.count/2] < 0.08 else { return nil }
        return .init(slope:a,intercept:b,center:center,spread:spread,minimum:best.map { samples[$0].relative }.min()!,maximum:best.map { samples[$0].relative }.max()!,inliers:best.count,samples:samples.count,medianRelativeError:residual[residual.count/2])
    }
}
