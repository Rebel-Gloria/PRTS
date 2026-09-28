// SYNTHETIC offscreen rendering with the app's real Metal shader. Not iPhone sensor evidence.
import Foundation
import Metal
import simd
import AppKit
import SpatialCore

struct Vertex { var position: SIMD4<Float>;var color: SIMD4<Float> }
struct Uniforms {
    var display0 = SIMD4<Float>(1,0,0,0),display1 = SIMD4<Float>(0,1,0,0)
    var intrinsics = SIMD4<Float>(400,400,255.5,255.5)
    var imageAndModes = SIMD4<Float>(512,512,0,0)
    var rangeAndFlags = SIMD4<Float>.zero,colorEncoding = SIMD4<Float>.zero
    var worldToCamera = matrix_identity_float4x4
}
@main struct Main {
    static func main() throws {
        let source = try String(contentsOfFile:"App/ProbeShaders.metal.txt",encoding:.utf8)
        guard let device = MTLCreateSystemDefaultDevice(),let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let library = try device.makeLibrary(source:source,options:nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name:"worldVertex");desc.fragmentFunction = library.makeFunction(name:"worldFragment")
        desc.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor:desc)
        func render(_ vertices: [Vertex],_ uniforms: Uniforms) throws -> [UInt8] {
            let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba8Unorm,width:512,height:512,mipmapped:false)
            td.usage = [.renderTarget];td.storageMode = .shared
            let texture = device.makeTexture(descriptor:td)!,command = queue.makeCommandBuffer()!
            let pass = MTLRenderPassDescriptor();pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear;pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,1)
            let encoder = command.makeRenderCommandEncoder(descriptor:pass)!
            encoder.setRenderPipelineState(pipeline);encoder.setCullMode(.none)
            let vb = device.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<Vertex>.stride)!
            var u = uniforms;encoder.setVertexBuffer(vb,offset:0,index:0)
            encoder.setVertexBytes(&u,length:MemoryLayout<Uniforms>.stride,index:1)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:vertices.count);encoder.endEncoding()
            command.commit();command.waitUntilCompleted()
            if let error = command.error { throw error }
            var pixels = [UInt8](repeating:0,count:512*512*4)
            texture.getBytes(&pixels,bytesPerRow:512*4,from:MTLRegionMake2D(0,0,512,512),mipmapLevel:0)
            return pixels
        }
        func save(_ pixels: [UInt8],_ name: String) throws {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:512,pixelsHigh:512,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:512*4,bitsPerPixel:32)!
            pixels.withUnsafeBytes { bitmap.bitmapData!.update(from:$0.bindMemory(to:UInt8.self).baseAddress!,count:pixels.count) }
            try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:name))
        }
        let white = SIMD4<Float>(1,1,1,1)
        // Triangle crosses the near/camera plane. All points lie on the same image centre ray.
        let near = [Vertex(position:SIMD4(-0.001,0,-1,1),color:white),Vertex(position:SIMD4(0.001,0,-1,1),color:white),Vertex(position:SIMD4(0,0.001,0.1,1),color:white)]
        let clipped = try render(near,Uniforms())
        var lit = 0,outside = 0
        for y in 0..<512 { for x in 0..<512 where clipped[(y*512+x)*4] > 0 { lit += 1;if abs(x-256)>5 { outside += 1 } } }
        precondition(lit > 0 && outside == 0,"Behind-camera vertex teleported across image")
        // Regression: homogeneous transform agrees with the old projection for front-facing points.
        for z: Float in [0.03,0.2,1,3] { for x: Float in [-0.2,0,0.3] {
            let old = ((400*x/z+256)/512*2-1)*z
            let new = 2*((400*x+256*z)/512)-z
            precondition(abs(old-new)<0.00001)
        }}
        // Actual PathDrawing ribbons, metric dashes and goal marker, shown from a pitched camera.
        let plane = GroundPlane(normal:V3(0,1,0),offset:0,floorPriorConfirmed:true)
        let points = [V3(0,0,-0.6),V3(0.65,0,-1.7),V3(0.05,0,-3.7)]
        struct Fixture: Encodable {
            let id = 1,epoch = 1,parameterVersion = 0,sourceFrameID = 1,validatedFrameID = 1
            let observedAt = 0.0,source = "synthetic",requiredWidth = 0.5
            let plane: GroundPlane,points: [V3]
        }
        let path = try JSONDecoder().decode(PredictedPath.self,from:JSONEncoder().encode(Fixture(plane:plane,points:points)))
        var gate = ResultPresentationGate();gate.enabled = true;gate.trackingNormal = true
        gate.epoch = 1;gate.frameID = 1;gate.frameTimestamp = 0
        let presentation = PathPresentation.make(path:path,gate:gate,pose:RigidPose(position:V3(0,1.4,0)),options:.init(),now:0)!
        var vertices: [Vertex] = []
        // Blue ground support, red obstacle. Neither this fixture nor its screenshot is a real room.
        func quad(_ a: V3,_ b: V3,_ c: V3,_ d: V3,_ color: SIMD4<Float>) { vertices += [a,b,c,c,b,d].map{.init(position:SIMD4($0,1),color:color)} }
        quad(V3(-1.2,0,-0.6),V3(1.2,0,-0.6),V3(-1.2,0,-4),V3(1.2,0,-4),SIMD4(0.05,0.2,0.65,1))
        quad(V3(-0.28,0.006,-1.25),V3(0.28,0.006,-1.25),V3(-0.28,0.006,-1.6),V3(0.28,0.006,-1.6),SIMD4(0.95,0.05,0.1,1))
        for mesh in PathDrawing.meshes(presentation) {
            let color: SIMD4<Float> = mesh.role == .unknownApproach ? SIMD4(0,1,1,1) : SIMD4(1,0.85,0.05,1)
            vertices += mesh.vertices.map{.init(position:SIMD4($0,1),color:color)}
        }
        var u = Uniforms();let rotation = simd_float4x4(simd_quatf(angle:0.9,axis:V3(1,0,0)))
        var translation = matrix_identity_float4x4;translation.columns.3 = SIMD4(0,-1.4,0,1)
        u.worldToCamera = rotation*translation
        let pixels = try render(vertices,u)
        let colorPixels = stride(from:0,to:pixels.count,by:4).filter{pixels[$0]>20 || pixels[$0+1]>20 || pixels[$0+2]>20}.count
        let cyanPixels = stride(from:0,to:pixels.count,by:4).filter{pixels[$0]<30 && pixels[$0+1]>200 && pixels[$0+2]>200}.count
        let yellowPixels = stride(from:0,to:pixels.count,by:4).filter{pixels[$0]>200 && pixels[$0+1]>180 && pixels[$0+2]<30}.count
        precondition(colorPixels>1000 && cyanPixels>10 && yellowPixels>10)
        let output = CommandLine.arguments.count>1 ? CommandLine.arguments[1] : "build/FanPathPlanning/synthetic-path-metal.png"
        try save(pixels,output)
        print("SYNTHETIC Metal pass: homogeneous projection/near clip (lit=\(lit), outside=\(outside)); actual path meshes (colored=\(colorPixels)); \(output)")
    }
}
