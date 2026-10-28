import Foundation
import simd

/// Display-only centerline. A fallback is still drawn and is never promoted to route authority.
public struct GroundRouteShape: Sendable {
    public var points: [V3]
    public var usedFallback: Bool
    public var reason: String?
}
public enum GroundRouteDrawing {
    public static func make(_ presentation: PathPresentation, obstacles: [OccupancyFootprint]?,
                            bodyWidth: Float? = nil) -> GroundRouteShape {
        let original = Array(presentation.approach.dropLast()) + presentation.path.points
        func fallback(_ reason: String) -> GroundRouteShape {
            .init(points:original,usedFallback:true,reason:reason)
        }
        let plane = presentation.path.plane
        let width = max(presentation.path.requiredWidth,bodyWidth ?? presentation.path.requiredWidth)
        guard LocalGroundRebase.accepts(plane), original.count >= 2, let obstacles else { return fallback("drawing_constraints_unavailable") }
        var source = original.map { LocalGroundRebase.lift($0,to:plane) }
        // The retained planning tail may be behind the feet. Join its nearest entry
        // projection without touching any planning vertex, goal, or following corner.
        if !presentation.approach.isEmpty, source.count >= 3 {
            let a=source[1], v=source[2]-a
            let t=max(0,min(1,simd_dot(source[0]-a,v)/max(0.000001,simd_length_squared(v))))
            source=[source[0],a+v*t]+Array(source.dropFirst(2))
        }
        source=coalesced(source)
        for trim:Float in [0.12,0.06] {
            let candidate=rounded(source,trim:trim)
            guard withinDeviation(candidate,original:original),
                  // Check EVERY final rendered chord after all geometric operations.
                  zip(candidate,candidate.dropFirst()).allSatisfy({a,b in
                      !obstacles.contains{$0.overlaps(from:a,to:b,radius:width/2+0.001)}
                  }) else { continue }
            return .init(points:candidate,usedFallback:false,reason:nil)
        }
        // Display coverage must never depend on smoothing success. The original may
        // intersect today's model; keeping its visualization is not a safety certificate.
        return fallback("smoothing_constraints_rejected")
    }

    private static func coalesced(_ points:[V3])->[V3] {
        var result:[V3]=[]
        for p in points where result.last.map({simd_distance($0,p)>0.00001}) ?? true {result.append(p)}
        return result
    }
    static func rounded(_ points:[V3],trim:Float)->[V3] {
        guard points.count >= 3, trim > 0 else {return points}
        var result=[points[0]]
        for i in 1..<points.count-1 {
            let a=points[i-1], b=points[i], c=points[i+1]
            let d0=simd_distance(a,b),d1=simd_distance(b,c)
            guard min(d0,d1)>0.00001 else{continue}
            let v=(b-a)/d0,w=(c-b)/d1,dot=simd_dot(v,w)
            if dot>0.9999 || dot < -0.95 {result.append(b);continue}
            let t=min(trim,min(d0,d1)*0.25),p0=b-v*t,p2=b+w*t
            result.append(p0)
            // Bound the quadratic-to-chord deviation to 1mm. Keep these exact chords
            // for collision validation and tessellation (no unchecked resampling later).
            let n=max(2,Int(ceil(sqrt(simd_length(p0-2*b+p2)/0.004))))
            for j in 1...n {
                let u=Float(j)/Float(n)
                result.append((1-u)*(1-u)*p0+2*u*(1-u)*b+u*u*p2)
            }
        }
        result.append(points.last!)
        return coalesced(result)
    }
    private static func withinDeviation(_ points:[V3],original:[V3])->Bool {
        let flat=original.map{V3($0.x,0,$0.z)}
        for (a,b) in zip(points,points.dropFirst()) {
            let n=max(1,Int(ceil(simd_distance(a,b)/0.01)))
            for i in 0...n {
                let p=a+(b-a)*Float(i)/Float(n),q=V3(p.x,0,p.z)
                let distance=zip(flat,flat.dropFirst()).map{PathTracking.distance(q,to:$0,end:$1)}.min() ?? .infinity
                // Distance to the original union is 1-Lipschitz: reserve half a sample.
                if distance>0.045 {return false}
            }
        }
        return true
    }
}
