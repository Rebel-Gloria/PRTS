import Foundation
import simd

public struct FloorPrior: Codable, Sendable {
    public var center: V3; public var normal: V3
    public var anchorID: String; public var revision: UInt64; public var callbackTime: Double
    public init(center: V3, normal: V3, anchorID: String = "synthetic", revision: UInt64 = 0, callbackTime: Double = 0) {
        self.center = center; self.normal = normal; self.anchorID = anchorID; self.revision = revision; self.callbackTime = callbackTime
    }
}

public enum GroundEstimator {
    public static func fit(points: [V3], priors: [FloorPrior], camera: V3, parameters p: ProbeParameters) -> GroundPlane? {
        let pts = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && simd_distance($0,camera) < p.maxDepth }
        guard pts.count >= 40 else { return nil }
        let cosine = cos(p.maxPlaneTiltDegrees * .pi / 180)
        let sampleStep = max(1,pts.count/600)
        let samples = stride(from: 0,to: pts.count,by:sampleStep).map { pts[$0] }
        let nearbyPriors = priors.filter { abs($0.normal.y) >= cosine && simd_distance($0.center,camera) < p.maxDepth }
        var hypotheses = nearbyPriors.prefix(64).map { prior -> GroundPlane in
            let n = prior.normal.y < 0 ? -prior.normal : prior.normal
            return GroundPlane(normal:n,offset:-simd_dot(n,prior.center))
        }
        var random: UInt64 = 0x1234abcd // Reproducible, never a nondeterministic test fixture.
        func next() -> Int { random = random &* 6364136223846793005 &+ 1; return Int((random >> 32) % UInt64(samples.count)) }
        for _ in 0..<96 {
            let a = samples[next()], b = samples[next()], c = samples[next()]
            var n = simd_cross(b-a,c-a)
            guard simd_length(n) > 0.015 else { continue }
            n = simd_normalize(n); if n.y < 0 { n = -n }
            guard n.y >= cosine else { continue }
            hypotheses.append(.init(normal:n,offset:-simd_dot(n,a)))
        }
        var best: GroundPlane?; var bestScore = 0
        for plane in hypotheses {
            let height = plane.height(camera)
            guard height > 0.45 && height < 2.3 else { continue }
            let support = samples.reduce(0) { $0 + (abs(plane.height($1)) <= p.planeTolerance ? 1 : 0) }
            let matchesPrior = nearbyPriors.contains { abs(plane.height($0.center)) < 0.07 }
            let score = support + (matchesPrior ? samples.count : 0)
            if support >= 20 && score > bestScore { best = plane; bestScore = score }
        }
        guard var plane = best else { return nil }
        for _ in 0..<3 {
            let inliers = pts.filter { abs(plane.height($0)) <= p.planeTolerance }
            guard inliers.count >= 40 else { return nil }
            let mean = inliers.reduce(V3.zero,+)/Float(inliers.count)
            var xx: Float = 0, zz: Float = 0, xz: Float = 0, xy: Float = 0, zy: Float = 0
            for point in inliers {
                let d = point-mean; xx += d.x*d.x; zz += d.z*d.z; xz += d.x*d.z; xy += d.x*d.y; zy += d.z*d.y
            }
            let det = xx*zz-xz*xz
            guard det > 0.0001 else { return nil }
            let a = (xy*zz-zy*xz)/det, b = (zy*xx-xy*xz)/det
            let n = simd_normalize(V3(-a,1,-b))
            guard n.y >= cosine else { return nil }
            plane.normal = n; plane.offset = -simd_dot(n,mean)
        }
        let inliers = pts.filter { abs(plane.height($0)) <= p.planeTolerance }
        let occupied = Set(inliers.map { "\(Int(floor($0.x/0.25))):\(Int(floor($0.z/0.25)))" })
        plane.supportArea = Float(occupied.count)*0.0625
        guard inliers.count >= 40, plane.supportArea >= 0.3 else { return nil }
        plane.supportCount = inliers.count
        plane.residual = sqrt(inliers.reduce(Float(0)) { $0 + pow(plane.height($1),2) }/Float(inliers.count))
        // A matching plane at an unrelated location is insufficient: require depth near classified floor faces.
        plane.floorPriorConfirmed = nearbyPriors.contains { prior in
            abs(plane.height(prior.center)) < 0.07 && simd_dot(plane.normal,prior.normal) > cosine &&
            inliers.contains { simd_distance($0,prior.center) < 0.35 }
        }
        return plane
    }
}

public struct DirectionGate: Sendable {
    public private(set) var diagnostics = DirectionDiagnostics()
    private var previousPose: RigidPose?
    private var previousTime: Double?
    private var stableSince: Double?
    public init() {}
    public mutating func reset() { previousPose = nil; previousTime = nil; stableSince = nil; diagnostics = .init() }
    public mutating func update(pose: RigidPose, time: Double, trackingNormal: Bool, parameters p: ProbeParameters) -> Bool {
        defer { previousPose = pose; previousTime = time }
        diagnostics = .init()
        diagnostics.horizontalProjection = simd_length(SIMD2(pose.back.x,pose.back.z))
        guard trackingNormal else { stableSince = nil; diagnostics.reason = "tracking_not_normal"; return false }
        guard diagnostics.horizontalProjection >= 0.5 else { stableSince = nil; diagnostics.reason = "reference_vertical"; return false }
        if let old = previousPose, let t = previousTime {
            let dt = time-t; diagnostics.deltaTime = dt
            guard dt > 0, dt < 0.3 else { stableSince = nil; diagnostics.reason = "frame_time_gap"; return false }
            // Check full rotation, including roll (not just forward vector).
            let trace = simd_dot(old.right,pose.right)+simd_dot(old.up,pose.up)+simd_dot(old.back,pose.back)
            let angle = acos(min(1,max(-1,(trace-1)/2))) * 180 / .pi
            diagnostics.angularSpeedDegrees = angle/Float(dt)
            if angle/Float(dt) > p.maxAngularSpeed { stableSince = nil; diagnostics.reason = "angular_speed"; return false }
        }
        if stableSince == nil { stableSince = time }
        diagnostics.stableFor = time - (stableSince ?? time)
        diagnostics.reason = diagnostics.stableFor >= p.stableDuration ? "stable" : "stabilizing"
        return diagnostics.stableFor >= p.stableDuration
    }
}

public struct ResultGate: Sendable {
    public private(set) var epoch: UInt64 = 0
    public private(set) var latestFrame: UInt64 = 0
    public init() {}
    public mutating func reset(epoch: UInt64) { self.epoch = epoch; latestFrame = 0 }
    public mutating func accept(epoch: UInt64, frameID: UInt64, timestamp: Double, now: Double, maxAge: Double) -> Bool {
        guard epoch == self.epoch, frameID > latestFrame, now >= timestamp, now-timestamp <= maxAge else { return false }
        latestFrame = frameID; return true
    }
}
