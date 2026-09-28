import Foundation
import simd

public struct DepthObservation: Sendable {
    public var width: Int; public var height: Int
    public var depth: [Float]; public var confidence: [UInt8]?
    /// A prediction-support mask is NOT sensor confidence and cannot certify free space.
    public var predictionSupport: [UInt8]? = nil
    public var isPrediction: Bool { predictionSupport != nil }
    public var hasGeometricSupport: Bool { confidence != nil || predictionSupport != nil }
    public var intrinsics: CameraIntrinsics; public var pose: RigidPose
    public var timestamp: Double; public var frameID: UInt64; public var epoch: UInt64
    public init(width: Int, height: Int, depth: [Float], confidence: [UInt8]?, intrinsics: CameraIntrinsics, pose: RigidPose, timestamp: Double, frameID: UInt64, epoch: UInt64) {
        self.width = width; self.height = height; self.depth = depth; self.confidence = confidence
        self.intrinsics = intrinsics; self.pose = pose; self.timestamp = timestamp; self.frameID = frameID; self.epoch = epoch
    }
    public var structurallyValid: Bool {
        width > 0 && height > 0 && depth.count == width*height &&
        (confidence == nil || confidence?.count == depth.count) && (predictionSupport == nil || predictionSupport?.count == depth.count) && intrinsics.width == width && intrinsics.height == height &&
        intrinsics.fx.isFinite && intrinsics.fy.isFinite && intrinsics.fx > 0 && intrinsics.fy > 0
    }
    public func valid(_ i: Int, parameters p: ProbeParameters) -> Bool {
        guard i >= 0, i < depth.count else { return false }
        let supported: Bool
        if let predictionSupport { supported = i < predictionSupport.count && predictionSupport[i] == 1 }
        else { supported = confidence.map { i < $0.count && $0[i] == 2 } ?? false }
        return supported && depth[i].isFinite && depth[i] >= p.minDepth && depth[i] <= p.maxDepth
    }
    public func points(parameters p: ProbeParameters) -> [V3] {
        guard structurallyValid else { return [] }
        var result: [V3] = []; result.reserveCapacity(width*height / (p.samplingStep*p.samplingStep))
        for v in stride(from: 0, to: height, by: p.samplingStep) {
            for u in stride(from: 0, to: width, by: p.samplingStep) {
                let i = v*width+u
                if valid(i, parameters: p) { result.append(pose.world(intrinsics.unproject(u: Float(u),v: Float(v),depth: depth[i]))) }
            }
        }
        return result
    }
    public func coverage(parameters p: ProbeParameters) -> Float {
        guard structurallyValid else { return 0 }
        return Float(depth.indices.reduce(0) { $0 + (valid($1,parameters:p) ? 1 : 0) }) / Float(depth.count)
    }
}

/// A complete min-depth pyramid. Invalid/confidence-missing pixels become zero, never infinity.
/// Querying the enclosing bounding rectangle is intentionally conservative (no hole interpolation).
public struct VisibilityDepth: Sendable {
    /// Conservative computational limit: exhausting it returns UNKNOWN, never clear.
    public static let defaultFramePixelBudget = 262144
    public static let maximumQueryPixels = 8192
    private let observation: DepthObservation
    private let minimum: [Float]
    private let levels: [(offset: Int, width: Int, height: Int)]
    public init(_ observation: DepthObservation, parameters: ProbeParameters) {
        self.observation = observation
        guard observation.structurallyValid else { minimum = []; levels = []; return }
        var data = observation.depth.indices.map { observation.valid($0,parameters:parameters) ? observation.depth[$0] : 0 }
        var lv = [(offset: 0, width: observation.width, height: observation.height)]
        while let last = lv.last, last.width > 1 || last.height > 1 {
            let w = (last.width+1)/2, h = (last.height+1)/2, offset = data.count
            for y in 0..<h { for x in 0..<w {
                var z = Float.greatestFiniteMagnitude
                for dy in 0..<2 { for dx in 0..<2 {
                    let xx = x*2+dx, yy = y*2+dy
                    if xx < last.width && yy < last.height { z = min(z,data[last.offset+yy*last.width+xx]) }
                }}
                data.append(z)
            }}
            lv.append((offset,w,h))
        }
        minimum = data; levels = lv
    }
    public func isClear(corners: [V3], margin: Float) -> Bool {
        var budget = Self.defaultFramePixelBudget
        return isClear(corners:corners,margin:margin,pixelBudget:&budget)
    }
    public func isClear(corners: [V3], margin: Float,pixelBudget: inout Int) -> Bool {
        guard !observation.isPrediction, corners.count == 8, !levels.isEmpty else { return false }
        var minU = Float.greatestFiniteMagnitude, maxU: Float = -1
        var minV = Float.greatestFiniteMagnitude, maxV: Float = -1, farZ: Float = 0
        for corner in corners {
            let c = observation.pose.camera(corner)
            guard let uv = observation.intrinsics.project(c), uv.x.isFinite, uv.y.isFinite,
                  uv.x >= 0, uv.y >= 0, uv.x <= Float(observation.width-1), uv.y <= Float(observation.height-1) else { return false }
            minU = min(minU,uv.x); maxU = max(maxU,uv.x); minV = min(minV,uv.y); maxV = max(maxV,uv.y)
            farZ = max(farZ,-c.z)
        }
        let x0 = Int(floor(minU)), x1 = Int(ceil(maxU)), y0 = Int(floor(minV)), y1 = Int(ceil(maxV))
        // A coarser enclosing rectangle may reject extra cells, but never certifies uncovered pixels.
        var level = 0
        while level+1 < levels.count && (x1-x0+1)>>(level+1) >= 2 && (y1-y0+1)>>(level+1) >= 2 { level += 1 }
        let l = levels[level]
        var fastClear = true
        for y in (y0>>level)...(y1>>level) { for x in (x0>>level)...(x1>>level) {
            if minimum[l.offset+y*l.width+x] <= farZ + margin { fastClear = false }
        }}
        if fastClear { return true }
        // A box-wide far depth incorrectly rejects floor-adjacent volumes: rays near the
        // camera hit the floor before the far corner of an unrelated ray. Bound each
        // pixel footprint's possible box-exit depth instead. Direction intervals on
        // each orthogonal slab OVERestimate intersections, never under-estimate them.
        let pixels = (x1-x0+1)*(y1-y0+1)
        guard pixels <= Self.maximumQueryPixels else { return false }
        let origin = observation.pose.position
        let edges = [corners[1]-corners[0],corners[2]-corners[0],corners[4]-corners[0]]
        let lengths = edges.map { simd_length($0) }
        guard lengths.allSatisfy({ $0 > 0.00001 }) else { return false }
        let axes = zip(edges,lengths).map { $0 / $1 }
        guard abs(simd_dot(axes[0],axes[1])) < 0.001,
              abs(simd_dot(axes[0],axes[2])) < 0.001,
              abs(simd_dot(axes[1],axes[2])) < 0.001 else { return false }
        let localOrigin = axes.map { simd_dot(origin-corners[0],$0) }
        // A pixel's four world ray corners are affine in u/v. Compute their slab
        // intervals analytically instead of allocating 4 rays and 3 arrays per pixel.
        let du = observation.pose.right/observation.intrinsics.fx
        let dv = -observation.pose.up/observation.intrinsics.fy
        let base = -observation.pose.back-du*observation.intrinsics.cx-dv*observation.intrinsics.cy
        let xCoefficients = axes.map { simd_dot(du,$0) },yCoefficients = axes.map { simd_dot(dv,$0) }
        let constants = axes.map { simd_dot(base,$0) }
        let radii = (0..<3).map { (abs(xCoefficients[$0])+abs(yCoefficients[$0]))*0.5 }
        for y in y0...y1 { for x in x0...x1 {
            guard pixelBudget > 0 else { return false }
            pixelBudget -= 1
            if minimum[y*observation.width+x] > farZ+margin { continue }
            var near: Float = 0,far = farZ
            for a in 0..<3 {
                let center = constants[a]+Float(x)*xCoefficients[a]+Float(y)*yCoefficients[a]
                // Expand for floating-point rounding: never shrink the set of possible rays.
                let padding: Float = 0.000002*(1+abs(center)+radii[a])
                let low = -localOrigin[a],high = lengths[a]-localOrigin[a]
                let dMin = center-radii[a]-padding,dMax = center+radii[a]+padding
                // Necessary inequalities for some ray in this pixel to enter this slab:
                // t*dMax >= low, t*dMin <= high, t >= 0.
                if dMax > 0 { near = max(near,low/dMax) }
                else if dMax < 0 { far = min(far,low/dMax) }
                else if low > 0 { far = -1 }
                if dMin > 0 { far = min(far,high/dMin) }
                else if dMin < 0 { near = max(near,high/dMin) }
                else if high < 0 { far = -1 }
            }
            if far >= near,far > 0,minimum[y*observation.width+x] <= far+margin { return false }
        }}
        return true
    }
}
