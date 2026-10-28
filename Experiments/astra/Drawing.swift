import Foundation
import simd
@testable import SpatialCore

struct DrawingOutput:Encodable {
    var before:[V3],after:[V3],afterUnfiltered:[V3]
    var beforeVertices:Int,afterVertices:Int,accepted:Bool,smoothingRadius:Float
    var beforeCollision:Bool,afterCollision:Bool,rawCollision:Bool,body060Collision:Bool
    var localGroundUsed:Bool,ms:Double,meshMS:Double,maxWidthError:Float
    var routeID:UInt64
    var rejectedReason:String?
}
func resample(_ points:[V3],step:Float=0.05)->[V3] {
    guard points.count>=2 else{return points}
    let length=RouteArc.length(points)
    guard length>0.00001 else{return [points[0]]}
    var out=[points[0]],index=0,travel:Float=0
    for s in stride(from:step,to:length,by:step) {
        while index+1<points.count-1 && travel+simd_distance(points[index],points[index+1])<s {
            travel+=simd_distance(points[index],points[index+1]);index+=1
        }
        let a=points[index],b=points[index+1],d=simd_distance(a,b)
        out.append(a+(b-a)*((s-travel)/max(d,0.000001)))
    }
    out.append(points.last!);return out
}
func nearest(_ p:V3,to points:[V3])->V3 {
    var result=points.first ?? p,minimum=Float.infinity
    for (a,b) in zip(points,points.dropFirst()) {
        let ab=b-a,t=max(0,min(1,simd_dot(p-a,ab)/max(0.0000001,simd_length_squared(ab))))
        let q=a+ab*t,d=simd_distance(p,q)
        if d<minimum {minimum=d;result=q}
    }
    return result
}
func withinHorizontalDeviation(_ points:[V3],reference:[V3],limit:Float=0.05)->Bool {
    let flat=reference.map{V3($0.x,0,$0.z)}
    // Both polylines are piecewise linear. Subdivide to 1cm and add that Lipschitz
    // bound to certify the limit between samples, not merely at sparse vertices.
    return resample(points,step:0.01).allSatisfy {p in
        let q=V3(p.x,0,p.z)
        return simd_distance(q,nearest(q,to:flat))<=limit-0.005
    }
}
func rounded(_ points:[V3],radius:Float)->[V3] {
    guard points.count>=3,radius>0 else{return resample(points)}
    var q=[points[0]]
    for i in 1..<points.count-1 {
        let a=points[i-1],b=points[i],c=points[i+1],d0=simd_distance(a,b),d1=simd_distance(b,c)
        guard min(d0,d1)>0.0001 else{continue}
        let v=(b-a)/d0,w=(c-b)/d1
        if simd_dot(v,w)>0.9999 {q.append(b);continue}
        // Near reversal is not a meaningful smooth route; retain and let the checker decide.
        if simd_dot(v,w)<(-0.95) {q.append(b);continue}
        let trim=min(radius,min(d0,d1)*0.25),p0=b-v*trim,p2=b+w*trim
        q.append(p0)
        // Quadratic chord deviation <= |p0-2b+p2|/(4*n*n), <= 1mm.
        let n=max(2,Int(ceil(sqrt(simd_length(p0-2*b+p2)/0.004))))
        for j in 1...n {let t=Float(j)/Float(n);q.append((1-t)*(1-t)*p0+2*t*(1-t)*b+t*t*p2)}
    }
    q.append(points.last!);return resample(q)
}
struct RibbonVertex {var point:V3;var alpha:Float}
func joinedRibbon(_ points:[V3],normal:V3,camera:V3,width:Float=0.036)->([RibbonVertex],Float) {
    guard points.count>=2 else{return ([],0)}
    let p=points.map{$0+normal*0.025},half=width/2
    func vertex(_ p:V3)->RibbonVertex {
        let d=simd_distance(p,camera),u=max(0,min(1,(d-2)/2))
        return .init(point:p,alpha:1-u*u*(3-2*u))
    }
    var vertices=[RibbonVertex]()
    var directions=[V3](),sides=[V3](),maxError:Float=0
    for i in 0..<p.count-1 {
        let tangent=simd_normalize(p[i+1]-p[i]),side=simd_normalize(simd_cross(tangent,normal))
        directions.append(tangent);sides.append(side)
        let a=p[i]-side*half,b=p[i]+side*half,c=p[i+1]-side*half,d=p[i+1]+side*half
        vertices += [a,b,c,c,b,d].map(vertex)
        maxError=max(maxError,abs(simd_distance(a,b)-width))
    }
    // Constant-radius round outer joins. The inner halves overlap; alpha blending of
    // overlaps is a stated limitation of this CPU prototype, to be unified in production.
    if directions.count>=2 {for i in 1..<p.count-1 {
        let angle=atan2(simd_dot(normal,simd_cross(sides[i-1],sides[i])),simd_dot(sides[i-1],sides[i]))
        guard abs(angle)>0.001 else{continue}
        let side=sides[i-1]*(angle>0 ? half:-half)
        let steps=max(1,Int(ceil(abs(angle)/(.pi/12))))
        func arc(_ j:Int)->V3 {
            let a=angle*Float(j)/Float(steps)
            return p[i]+side*cos(a)+simd_cross(normal,side)*sin(a)
        }
        for j in 0..<steps {vertices += [p[i],arc(j),arc(j+1)].map(vertex)}
    }}
    // Same 24-segment goal ring as production, now lifted to the selected local ground.
    let right=simd_normalize(V3(1,0,0)-normal*normal.x),forward=simd_cross(normal,right),target=p.last!
    for i in 0..<24 {
        func ring(_ j:Int,_ radius:Float)->V3 {let a=Float(j)/24*2*Float.pi;return target+(right*cos(a)+forward*sin(a))*radius}
        let a=ring(i,0.06),b=ring(i,0.09),c=ring(i+1,0.06),d=ring(i+1,0.09)
        vertices += [a,b,c,c,b,d].map(vertex)
    }
    return (vertices,maxError)
}
struct DrawingPrototype {
    var previous:[V3]=[],id:UInt64?,time:Double?
    var groundAnchor:GroundReference?
    mutating func process(update:PathUpdate,result r:AnalysisResult,observation:DepthObservation?)->DrawingOutput? {
        guard let path=update.path,let pose=r.sourcePose else{previous=[];id=nil;time=nil;return nil}
        let start=ProcessInfo.processInfo.systemUptime
        let foot=path.plane.project(pose.position)
        let approach=path.points.first.map{simd_distance(foot,$0)>0.03 ? [foot,$0]:[]} ?? []
        let presentation=PathPresentation(path:path,age:0,historical:false,approach:approach)
        let oldMeshes=PathDrawing.meshes(presentation)
        let before=(approach.isEmpty ? []:[foot])+path.points
        let model=update.confirmedObstacles ?? []
        var source=before
        if let reference=r.diagnostics?.groundReference {groundAnchor=reference}
        let local=groundAnchor.map{r.timestamp-$0.observedAt<=2 && simd_distance(pose.position,$0.cameraPosition)<=1} ?? false
        let plane=local ? groundAnchor!.plane : path.plane
        if local {source=source.map{V3($0.x,-(plane.offset+plane.normal.x*$0.x+plane.normal.z*$0.z)/plane.normal.y,$0.z)}}
        let untrimmed=source
        // Reversing from feet to the retained 20cm tail and then forward makes a hook.
        // Trim only the entry segment at its closest foot projection; preserve all bends.
        if source.count>=3,!approach.isEmpty {
            let a=source[1],b=source[2],v=b-a
            let t=max(0,min(1,simd_dot(source[0]-a,v)/max(0.000001,simd_length_squared(v))))
            let match=a+v*t
            source=[source[0],match]+Array(source.dropFirst(2))
        }
        source=RouteArc.coalescingCollinear(source)
        var after=[V3](),radius:Float=0
        let width=max(path.requiredWidth,r.parameters.bodyWidth)
        for candidateSource in [source,untrimmed] where local && after.isEmpty {
            for candidate:Float in [0.12,0.06,0] {
                let q=rounded(candidateSource,radius:candidate)
                if q.count>=2,withinHorizontalDeviation(q,reference:before),!collision(q,model,width+0.002) {after=q;radius=candidate;break}
            }
        }
        let unfiltered=after
        if id==path.id,let oldTime=time,r.timestamp-oldTime>0,r.timestamp-oldTime<=0.25,!previous.isEmpty,!after.isEmpty {
            let alpha=1-exp(-Float(r.timestamp-oldTime)/0.15)
            let blended=after.map{p->V3 in
                let old=nearest(p,to:previous)
                // Keep horizontal world anchors unchanged; low-pass only local elevation.
                return simd_distance(p,old)<=0.08 ? V3(p.x,p.y*alpha+old.y*(1-alpha),p.z):p
            }
            let candidate=resample(blended)
            if withinHorizontalDeviation(candidate,reference:before),!collision(candidate,model,width+0.002) {after=candidate}
        }
        previous=after;id=path.id;time=r.timestamp
        let meshStart=ProcessInfo.processInfo.systemUptime
        let (mesh,widthError)=joinedRibbon(after,normal:plane.normal,camera:pose.position)
        let meshMS=(ProcessInfo.processInfo.systemUptime-meshStart)*1000
        let raw=r.grid.map{g in g.cells.indices.filter{g.cells[$0].state == .obstacle}.map{i in OccupancyFootprint(center:g.basis.world(x:g.center(i).x,h:0,z:g.center(i).y),right:g.basis.right,forward:g.basis.forward,size:g.cellSize)}} ?? []
        return .init(before:before,after:after,afterUnfiltered:unfiltered,beforeVertices:oldMeshes.reduce(0){$0+$1.vertices.count},afterVertices:mesh.count,accepted:!after.isEmpty,smoothingRadius:radius,beforeCollision:collision(before,model,path.requiredWidth),afterCollision:collision(after,model,path.requiredWidth),rawCollision:collision(after,raw,path.requiredWidth),body060Collision:collision(after,model,0.6),localGroundUsed:local,ms:(ProcessInfo.processInfo.systemUptime-start)*1000,meshMS:meshMS,maxWidthError:widthError,routeID:path.id,rejectedReason:!local ? "local_ground_unavailable":after.isEmpty ? "body_sweep_rejected":nil)
    }
}
