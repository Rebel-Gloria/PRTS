/// Metal renderer for RGB/depth and world-space overlays. It never performs sensor analysis.

import SwiftUI
import MetalKit
import ARKit
import SpatialCore

private struct ShaderUniforms {
    var display0: SIMD4<Float>
    var display1: SIMD4<Float>
    var intrinsics: SIMD4<Float>
    var imageAndModes: SIMD4<Float>
    var rangeAndFlags: SIMD4<Float>
    var colorEncoding: SIMD4<Float>
    var worldToCamera: simd_float4x4
}
private struct WorldVertex {
    var position: SIMD4<Float>
    var color: SIMD4<Float>
    init(_ p: V3,_ c: SIMD4<Float>) { position = SIMD4(p,1); color = c }
}
private struct CompiledLibrary: @unchecked Sendable { let value: MTLLibrary }
private struct TextureLifetime: @unchecked Sendable {
    let textures: [CVMetalTexture]
    let frame: FrameSnapshot?
}
private struct MeshBuffers {
    let revision: UInt64
    let triangles: MTLBuffer?
    let triangleCount: Int
    let lines: MTLBuffer?
    let lineCount: Int
}

@MainActor
struct CameraMetalView: UIViewRepresentable {
    let store: SharedStore
    let diagnostics: DiagnosticRecorder
    func makeCoordinator() -> ProbeRenderer { ProbeRenderer(store:store,diagnostics:diagnostics) }
    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame:.zero,device:MTLCreateSystemDefaultDevice())
        view.backgroundColor = .black; view.clearColor = MTLClearColorMake(0,0,0,1)
        view.colorPixelFormat = .bgra8Unorm; view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 30; view.isPaused = false; view.enableSetNeedsDisplay = false
        context.coordinator.prepare(view); view.delegate = context.coordinator
        return view
    }
    func updateUIView(_ view: MTKView,context: Context) {}
}

@MainActor
final class ProbeRenderer: NSObject, MTKViewDelegate {
    private let store: SharedStore
    private let diagnostics: DiagnosticRecorder
    private var renderSerial: UInt64 = 0
    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var imagePipeline: MTLRenderPipelineState?
    private var worldPipeline: MTLRenderPipelineState?
    private var noDepth: MTLDepthStencilState?
    private var worldDepth: MTLDepthStencilState?
    private var textureCache: CVMetalTextureCache?
    private var dummyDepth: MTLTexture?
    private var dummyConfidence: MTLTexture?
    private var meshes: [String:MeshBuffers] = [:]
    private var meshEpoch: UInt64 = 0
    private var nativePlaneBuffer: MTLBuffer?
    private var nativePlaneCount = 0
    private var nativePlaneKey = ""
    private var surfaceBuffer: MTLBuffer?
    private var surfaceCount = 0
    private var surfaceKey = ""
    private var blockingBuffer: MTLBuffer?
    private var blockingCount = 0
    private var blockingLines: MTLBuffer?
    private var blockingLineCount = 0
    private var gridBuffer: MTLBuffer?
    private var gridCount = 0
    private var channelBuffer: MTLBuffer?
    private var channelCount = 0
    private var pathBuffer: MTLBuffer?
    private var pathCount = 0
    private var pathApproachCount = 0,pathTargetCount = 0
    private var pathKey = ""
    private var analysisKey: String = ""
    private var lastDraw: Double = 0
    private var fps: Double = 0
    private let inFlight = DispatchSemaphore(value:2)
    init(store: SharedStore,diagnostics: DiagnosticRecorder) { self.store = store; self.diagnostics = diagnostics; super.init() }
    func prepare(_ view: MTKView) {
        guard let device = view.device else { store.update { $0.status = "Metal 设备不可用" }; return }
        self.device = device; commandQueue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil,nil,device,nil,&textureCache)
        let format = view.colorPixelFormat
        Task { [weak self] in
            do {
                let compiled = try await Task.detached(priority:.userInitiated) {
                    guard let sourceURL = Bundle.main.url(forResource:"ProbeShaders.metal",withExtension:"txt") else {
                        throw NSError(domain:"Metal",code:1,userInfo:[NSLocalizedDescriptionKey:"缺少 Metal shader 源资源"])
                    }
                    let source = try String(contentsOf:sourceURL,encoding:.utf8)
                    let options = MTLCompileOptions(); options.fastMathEnabled = false
                    return CompiledLibrary(value:try device.makeLibrary(source:source,options:options))
                }.value
                self?.finishPrepare(device:device,library:compiled.value,format:format)
            } catch { self?.store.update { $0.renderStatus = "Metal 初始化失败：\(error.localizedDescription)" } }
        }
    }
    private func finishPrepare(device: MTLDevice,library: MTLLibrary,format: MTLPixelFormat) {
        do {
            func pipeline(vertex: String,fragment: String,blend: Bool) throws -> MTLRenderPipelineState {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = library.makeFunction(name:vertex); desc.fragmentFunction = library.makeFunction(name:fragment)
                desc.colorAttachments[0].pixelFormat = format; desc.depthAttachmentPixelFormat = .depth32Float
                if blend {
                    desc.colorAttachments[0].isBlendingEnabled = true
                    desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
                    desc.colorAttachments[0].sourceAlphaBlendFactor = .one; desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor:desc)
            }
            imagePipeline = try pipeline(vertex:"imageVertex",fragment:"imageFragment",blend:false)
            worldPipeline = try pipeline(vertex:"worldVertex",fragment:"worldFragment",blend:true)
            let no = MTLDepthStencilDescriptor(); no.depthCompareFunction = .always; no.isDepthWriteEnabled = false
            noDepth = device.makeDepthStencilState(descriptor:no)
            let world = MTLDepthStencilDescriptor(); world.depthCompareFunction = .lessEqual; world.isDepthWriteEnabled = true
            worldDepth = device.makeDepthStencilState(descriptor:world)
            dummyDepth = device.makeTexture(descriptor:MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r32Float,width:1,height:1,mipmapped:false))
            dummyConfidence = device.makeTexture(descriptor:MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.r8Unorm,width:1,height:1,mipmapped:false))
            var zero: Float = 0; dummyDepth?.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&zero,bytesPerRow:4)
            var byte: UInt8 = 0; dummyConfidence?.replace(region:MTLRegionMake2D(0,0,1,1),mipmapLevel:0,withBytes:&byte,bytesPerRow:1)
            store.update { $0.renderStatus = "Metal 就绪" }
        } catch { store.update { $0.renderStatus = "Metal 初始化失败：\(error.localizedDescription)" } }
    }
    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
    private func texture(_ buffer: CVPixelBuffer,format: MTLPixelFormat,plane: Int = 0) -> (MTLTexture,CVMetalTexture)? {
        guard let textureCache else { return nil }
        let planar = CVPixelBufferIsPlanar(buffer)
        let w = planar ? CVPixelBufferGetWidthOfPlane(buffer,plane) : CVPixelBufferGetWidth(buffer)
        let h = planar ? CVPixelBufferGetHeightOfPlane(buffer,plane) : CVPixelBufferGetHeight(buffer)
        var ref: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil,textureCache,buffer,nil,format,w,h,plane,&ref) == kCVReturnSuccess,
              let ref,let texture = CVMetalTextureGetTexture(ref) else { return nil }
        return (texture,ref)
    }
    private func updateNativePlanes(_ s: SharedSnapshot) {
        let key = "\(s.epoch):\(s.nativePlaneFrameID)"
        guard key != nativePlaneKey else { return }; nativePlaneKey = key
        var vertices: [WorldVertex] = []
        var planes = s.nativePlanes
        let retained = s.retainedNativeGround(now:ProcessInfo.processInfo.systemUptime)
        if let retained,!planes.contains(where:{ $0.id == retained.id }) { planes.append(retained) }
        for plane in planes {
            let color: SIMD4<Float> = retained?.id == plane.id ? SIMD4(1,0.55,0.12,0.4) : plane.classification == "floor" ? SIMD4(0.05,0.5,1,0.75) : SIMD4(1,0.7,0.1,0.6)
            for i in plane.boundary.indices {
                vertices.append(WorldVertex(plane.pose.world(plane.boundary[i]),color))
                vertices.append(WorldVertex(plane.pose.world(plane.boundary[(i+1)%plane.boundary.count]),color))
            }
        }
        nativePlaneCount = vertices.count
        nativePlaneBuffer = vertices.isEmpty ? nil : device?.makeBuffer(bytes:vertices,length:vertices.count*MemoryLayout<WorldVertex>.stride,options:.storageModeShared)
    }
    func draw(in view: MTKView) {
        let start = ProcessInfo.processInfo.systemUptime,s = store.read()
        renderSerial &+= 1
        let renderID = renderSerial
        guard inFlight.wait(timeout:.now()) == .success else { diagnostics.renderSkipped(renderID:renderID,state:s,reason:"gpu_inflight_full"); return }
        var committed = false
        defer { if !committed { inFlight.signal() } }
        guard let command = commandQueue?.makeCommandBuffer(),let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,let encoder = command.makeRenderCommandEncoder(descriptor:pass) else { diagnostics.renderSkipped(renderID:renderID,state:s,reason:"drawable_command_or_encoder_unavailable"); return }
        var retainedTextures: [CVMetalTexture] = []
        var drawnSurfaces = 0,drawnBlocking = 0,drawnChannels = 0,drawnNativePlanes = 0
        var rgbSubmitted = false
        var imageTransform: [Double]?,contentRect: [Double]?
        let snapshot = s.displayedFrame
        let prediction = s.activeMonocular
        let surface = s.activeSurfacePresentation(now:start)
        let predictedPath = s.activePath(now:start)
        var drawnPath = 0
        if let frame = snapshot,s.running,let imagePipeline,let worldPipeline,
           let y = texture(frame.frame.capturedImage,format:.r8Unorm),let cbcr = texture(frame.frame.capturedImage,format:.rg8Unorm,plane:1) {
            retainedTextures += [y.1,cbcr.1]
            let orientation = view.window?.windowScene?.interfaceOrientation ?? .portrait
            let swap = orientation.isPortrait
            let iw = CGFloat(frame.intrinsics.width),ih = CGFloat(frame.intrinsics.height)
            let orientedSize = CGSize(width:swap ? ih : iw,height:swap ? iw : ih)
            let fit = FitRect(imageWidth:Float(orientedSize.width),imageHeight:Float(orientedSize.height),viewportWidth:Float(view.drawableSize.width),viewportHeight:Float(view.drawableSize.height))
            // Equal-aspect virtual viewport removes displayTransform's aspect-fill crop. Black bars live outside it.
            let transform = frame.frame.displayTransform(for:orientation,viewportSize:orientedSize)
            imageTransform = [transform.a,transform.b,transform.c,transform.d,transform.tx,transform.ty].map(Double.init)
            contentRect = [fit.x,fit.y,fit.width,fit.height].map(Double.init)
            encoder.setViewport(MTLViewport(originX:Double(fit.x),originY:Double(fit.y),width:Double(fit.width),height:Double(fit.height),znear:0,zfar:1))
            let sx = max(0,Int(ceil(fit.x))),sy = max(0,Int(ceil(fit.y)))
            let sw = max(1,Int(floor(fit.x+fit.width))-sx),sh = max(1,Int(floor(fit.y+fit.height))-sy)
            encoder.setScissorRect(MTLScissorRect(x:sx,y:sy,width:sw,height:sh))
            // Confidence always belongs to the depth variant on screen. Geometry remains raw sceneDepth.
            let depthData = s.usesMonocular ? nil : (s.options.smoothedDisplay ? frame.frame.smoothedSceneDepth : frame.frame.sceneDepth)
            let modelBuffer = prediction?.frame.id == frame.id ? prediction?.displayBuffer : nil
            let depth = s.usesMonocular ? modelBuffer.flatMap { texture($0,format:.r32Float) } : depthData.flatMap { texture($0.depthMap,format:.r32Float) }
            let confidence = depthData?.confidenceMap.flatMap { texture($0,format:.r8Unorm) }
            if let depth { retainedTextures.append(depth.1) }; if let confidence { retainedTextures.append(confidence.1) }
            let pixelFormat = CVPixelBufferGetPixelFormatType(frame.frame.capturedImage)
            let matrix = CVBufferCopyAttachment(frame.frame.capturedImage,kCVImageBufferYCbCrMatrixKey,nil) as? String
            var uniforms = ShaderUniforms(display0:SIMD4(Float(transform.a),Float(transform.c),Float(transform.tx),0),
                display1:SIMD4(Float(transform.b),Float(transform.d),Float(transform.ty),0),
                intrinsics:SIMD4(frame.intrinsics.fx,frame.intrinsics.fy,frame.intrinsics.cx,frame.intrinsics.cy),
                imageAndModes:SIMD4(Float(iw),Float(ih),Float(s.options.layer.rawValue),s.options.overlayDepth ? 1 : 0),
                rangeAndFlags:SIMD4(s.usesMonocular && prediction?.observation == nil ? 1 : s.options.heatMax,s.options.overlayAlpha,depth == nil ? 0 : 1,confidence == nil ? 0 : 1),
                colorEncoding:SIMD4(pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 1 : 0,matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) ? 1 : 0,s.options.showCameraImage ? 0 : 1,0),
                worldToCamera:simd_inverse(frame.frame.camera.transform))
            encoder.setRenderPipelineState(imagePipeline); encoder.setDepthStencilState(noDepth)
            encoder.setVertexBytes(&uniforms,length:MemoryLayout<ShaderUniforms>.stride,index:0)
            encoder.setFragmentBytes(&uniforms,length:MemoryLayout<ShaderUniforms>.stride,index:0)
            encoder.setFragmentTexture(y.0,index:0); encoder.setFragmentTexture(cbcr.0,index:1)
            encoder.setFragmentTexture(depth?.0 ?? dummyDepth,index:2); encoder.setFragmentTexture(confidence?.0 ?? dummyConfidence,index:3)
            encoder.drawPrimitives(type:.triangleStrip,vertexStart:0,vertexCount:4); rgbSubmitted = s.options.showCameraImage && s.options.layer == .rgb
            encoder.setRenderPipelineState(worldPipeline); encoder.setDepthStencilState(worldDepth); encoder.setCullMode(.none)
            encoder.setVertexBytes(&uniforms,length:MemoryLayout<ShaderUniforms>.stride,index:1)
            if s.options.showOverlays,s.frozen == nil,frame.trackingNormal,start-frame.frame.timestamp <= s.parameters.maxResultAge {
                if s.usesMonocular,s.options.showFloor,s.nativePlaneFrameID >= s.minimumGeometryFrameID,s.geometryEnabled,
                   (s.nativePlanes.first.map({ start-$0.timestamp <= 1 }) == true || s.retainedNativeGround(now:start) != nil) {
                    updateNativePlanes(s)
                    if let nativePlaneBuffer,nativePlaneCount > 0 {
                        encoder.setVertexBuffer(nativePlaneBuffer,offset:0,index:0)
                        encoder.drawPrimitives(type:.line,vertexStart:0,vertexCount:nativePlaneCount); drawnNativePlanes = nativePlaneCount
                    }
                }
                let result = s.activeGeometryResult(now:start)
                updateAnalysisBuffers(result,epoch:s.epoch)
                updateSurfaceBuffers(surface)
                if s.options.showSurfaceModel,let surfaceBuffer,surfaceCount > 0 {
                    encoder.setVertexBuffer(surfaceBuffer,offset:0,index:0)
                    encoder.drawPrimitives(type:surface?.historical == true ? .line : .triangle,vertexStart:0,vertexCount:surfaceCount); drawnSurfaces = surfaceCount
                }
                if s.options.showMesh || (s.options.showFloor && !s.options.showSurfaceModel) {
                    updateMeshBuffers(s)
                    for mesh in meshes.values {
                        if s.options.showFloor && !s.options.showSurfaceModel,let b = mesh.triangles,mesh.triangleCount > 0 { encoder.setVertexBuffer(b,offset:0,index:0); encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:mesh.triangleCount) }
                        if s.options.showMesh,let b = mesh.lines,mesh.lineCount > 0 { encoder.setVertexBuffer(b,offset:0,index:0); encoder.drawPrimitives(type:.line,vertexStart:0,vertexCount:mesh.lineCount) }
                    }
                }
                // Diagnostic overlay is intentionally x-ray: scene mesh must not hide unknown regions behind obstacles.
                encoder.setDepthStencilState(noDepth)
                if s.options.showGrid && !s.options.showSurfaceModel,let gridBuffer,gridCount > 0 { encoder.setVertexBuffer(gridBuffer,offset:0,index:0); encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:gridCount) }
                // Red air-space is an explicit exclusion column, not a measured opaque surface.
                if s.options.showSurfaceModel && s.options.showBlockingColumns {
                    if let blockingBuffer,blockingCount > 0 {
                        encoder.setVertexBuffer(blockingBuffer,offset:0,index:0)
                        encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:blockingCount); drawnBlocking = blockingCount
                    }
                    if let blockingLines,blockingLineCount > 0 {
                        encoder.setVertexBuffer(blockingLines,offset:0,index:0)
                        encoder.drawPrimitives(type:.line,vertexStart:0,vertexCount:blockingLineCount)
                    }
                }
                updatePathBuffer(predictedPath, projection: s.activeRouteProjection(now: ProcessInfo.processInfo.systemUptime))
                if s.options.showPath,let pathBuffer,pathCount > 0 {
                    // Locked Dev routes are annotations. A noisy floor triangle must not
                    // alternately cover/reveal a fixed world line (apparent broken dashes).
                    if s.pathUpdate.occupancyFilter != nil { encoder.setDepthStencilState(noDepth) }
                    encoder.setVertexBuffer(pathBuffer,offset:0,index:0)
                    encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:pathCount); drawnPath = pathCount
                    encoder.setDepthStencilState(worldDepth)
                }
                // Legacy multi-sector diagnostics remain available only when single-path mode is off.
                if s.options.showPath,!s.pathOptions.enabled,s.options.showChannels,s.activeGuidanceResult(now:start) != nil,let channelBuffer,channelCount > 0 { encoder.setVertexBuffer(channelBuffer,offset:0,index:0); encoder.drawPrimitives(type:.line,vertexStart:0,vertexCount:channelCount); drawnChannels = channelCount }
            }
        } else if !s.running { meshes.removeAll(); gridBuffer = nil; surfaceBuffer = nil; surfaceCount = 0; blockingBuffer = nil; blockingCount = 0; blockingLines = nil; blockingLineCount = 0; channelBuffer = nil; analysisKey = ""; surfaceKey = "" }
        encoder.endEncoding()
        let end = ProcessInfo.processInfo.systemUptime
        if lastDraw > 0 { let instantaneous = 1/max(0.001,start-lastDraw); fps = fps == 0 ? instantaneous : fps*0.9+instantaneous*0.1 }
        lastDraw = start
        let result = s.activeGeometryResult(now:start),delta = result.flatMap { r in snapshot.map { ($0.frame.timestamp-r.timestamp)*1000 } }
        if s.running || s.frame != nil {
            let geometryReason = s.result.map { s.presentationGate.geometryBlockReason($0,now:start) } ?? "no_analysis_result"
            let guidanceReason = s.result.map { s.presentationGate.guidanceBlockReason($0,now:start) } ?? "no_analysis_result"
            diagnostics.render(.init(phase:"submitted",
                routeContext:s.pathUpdate.continuity,routePublicationReason:s.routePublicationReason,
                routePublishTime:s.routePublishTime,
                routePresentationReason:drawnPath == 0 ? "not_submitted_display_gate_or_no_geometry" : predictedPath != nil ? (predictedPath!.historical ? "historically_supported" : "current_supported") : (s.activeRouteProjection(now:start) != nil ? "direction_projection_only" : s.pathUpdate.reason),
                routeDisplayedVerifiedLength:drawnPath > 0 && predictedPath?.path.verifiedEvidence == true ? predictedPath?.path.length : 0,
                renderID:renderID,epoch:s.epoch,frameID:snapshot?.id,uptime:start,sourceTimestamp:snapshot?.frame.timestamp,
                analysisFrameID:s.result?.frameID,analysisTimestamp:s.result?.timestamp,geometryBlockReason:geometryReason,guidanceBlockReason:guidanceReason,
                modelBlockReasons:s.result?.diagnostics?.modelBlockReasons ?? [],running:s.running,frozen:s.frozen != nil,options:s.options,
                surfaceVertices:drawnSurfaces,
                blockingVertices:drawnBlocking,
                channelVertices:drawnChannels,
                cpuMS:(end-start)*1000,drawableWidth:Double(view.drawableSize.width),drawableHeight:Double(view.drawableSize.height),orientation:view.window?.windowScene?.interfaceOrientation.rawValue,rgbSubmitted:rgbSubmitted,imageDisplayTransform:imageTransform,contentRect:contentRect,
                surfaceSourceFrameID:drawnSurfaces > 0 ? surface?.result.frameID : nil,
                surfacePresentationMode:drawnSurfaces > 0 ? (surface?.historical == true ? "historical_wireframe" : "current_depth") : "none",
                surfaceAgeMS:drawnSurfaces > 0 ? surface.map { $0.age*1000 } : nil,
                depthBackend:s.usesMonocular ? "apple_coreml_no_lidar" : "arkit_scene_depth",nativePlaneVertices:drawnNativePlanes,
                predictionSourceFrameID:prediction?.frame.id,predictionScaleConfirmed:prediction?.calibration != nil,pathID:predictedPath?.path.id,pathHistorical:predictedPath?.historical,pathAge:predictedPath?.age,pathVertices:drawnPath,pathApproachVertices:drawnPath > 0 ? pathApproachCount : 0,pathTargetVertices:drawnPath > 0 ? pathTargetCount : 0))
        }
        store.update { $0.renderMetrics.fps = fps; $0.renderMetrics.cpuMS = (end-start)*1000; $0.renderMetrics.analysisDisplayDeltaMS = delta; $0.renderMetrics.renderedFrameID = snapshot?.id ?? 0 }
        let lifetime = TextureLifetime(textures:retainedTextures,frame:snapshot),shared = store,semaphore = inFlight
        let diagnostic = diagnostics,diagnosticEpoch = s.epoch,diagnosticFrameID = snapshot?.id,logRender = s.running || s.frame != nil
        command.addCompletedHandler { buffer in
            _ = lifetime // Keep CVMetalTexture and source CVPixelBuffer alive until GPU completion.
            shared.update { if buffer.gpuEndTime >= buffer.gpuStartTime { $0.renderMetrics.gpuMS = (buffer.gpuEndTime-buffer.gpuStartTime)*1000 } }
            if logRender { diagnostic.gpu(renderID:renderID,epoch:diagnosticEpoch,frameID:diagnosticFrameID,status:String(buffer.status.rawValue),error:buffer.error?.localizedDescription,gpuMS:max(0,buffer.gpuEndTime-buffer.gpuStartTime)*1000) }
            semaphore.signal()
        }
        #if !targetEnvironment(simulator)
        let sourceTime = snapshot?.frame.timestamp
        drawable.addPresentedHandler { presented in
            guard let sourceTime,presented.presentedTime > 0 else { return }
            if logRender { diagnostic.presented(renderID:renderID,epoch:diagnosticEpoch,frameID:diagnosticFrameID,time:presented.presentedTime,sourceTime:sourceTime) }
            shared.update { $0.renderMetrics.presentAgeMS = (presented.presentedTime-sourceTime)*1000 }
        }
        #endif
        command.present(drawable); committed = true; command.commit()
    }
    private func buffer(_ vertices: [WorldVertex]) -> MTLBuffer? {
        guard !vertices.isEmpty else { return nil }
        return vertices.withUnsafeBytes { bytes in guard let base = bytes.baseAddress else { return nil }; return device?.makeBuffer(bytes:base,length:bytes.count,options:.storageModeShared) }
    }
    private func updateMeshBuffers(_ state: SharedSnapshot) {
        if meshEpoch != state.epoch { meshes.removeAll(); meshEpoch = state.epoch }
        for id in Array(meshes.keys) where state.meshes[id] == nil { meshes.removeValue(forKey:id) }
        // Limit main-thread upload work to one changed anchor per render. Old revisions are removed immediately.
        for id in Array(meshes.keys) where meshes[id]?.revision != state.meshes[id]?.revision { meshes.removeValue(forKey:id) }
        guard let mesh = state.meshes.values.sorted(by:{ $0.callbackTime > $1.callbackTime }).first(where:{ meshes[$0.id] == nil }) else { return }
        var floors: [WorldVertex] = [],lines: [WorldVertex] = []
        // Bound display detail only. CPU analysis and exported mesh preserve original geometry.
        let step = max(1,mesh.classifications.count/6000)
        for face in stride(from:0,to:mesh.classifications.count,by:step) {
            let points = (0..<3).map { mesh.transform.world(mesh.vertices[Int(mesh.indices[face*3+$0])]) }
            let c = classColor(mesh.classifications[face])
            for (a,b) in [(0,1),(1,2),(2,0)] { lines.append(WorldVertex(points[a],c)); lines.append(WorldVertex(points[b],c)) }
            if mesh.classifications[face] == 2 { for p in points { floors.append(WorldVertex(p,SIMD4(0.1,0.65,1,0.20))) } }
        }
        meshes[mesh.id] = .init(revision:mesh.revision,triangles:buffer(floors),triangleCount:floors.count,lines:buffer(lines),lineCount:lines.count)
    }
    private func classColor(_ c: UInt8) -> SIMD4<Float> {
        switch c {
        case 1: SIMD4(0.8,0.8,0.95,0.45)
        case 2: SIMD4(0.1,0.65,1,0.7)
        case 3: SIMD4(0.75,0.4,1,0.5)
        case 4: SIMD4(1,0.6,0.1,0.7)
        case 5: SIMD4(0.95,0.3,0.5,0.7)
        case 6: SIMD4(0.2,1,1,0.7)
        case 7: SIMD4(0.6,1,0.4,0.7)
        default: SIMD4(0.55,0.55,0.55,0.3)
        }
    }
    private func updateBlockingBuffers(_ model: BlockingVolumeModel?,grid: LocalGrid) {
        guard let model else {
            blockingBuffer = nil; blockingCount = 0; blockingLines = nil; blockingLineCount = 0; return
        }
        var triangles: [WorldVertex] = [],lines: [WorldVertex] = []
        let heights = Dictionary(uniqueKeysWithValues:model.columns.map { ($0.cellIndex,$0.ceiling) })
        for column in model.columns {
            let i = column.cellIndex,center = grid.center(i),half = grid.cellSize/2
            let x = i%grid.columns,z = i/grid.columns
            let points: [V3] = [Float(0),column.ceiling].flatMap { height in
                [center.y-half,center.y+half].flatMap { forward in
                    [center.x-half,center.x+half].map { right in grid.basis.world(x:right,h:height,z:forward) }
                }
            }
            func face(_ indices: [Int]) {
                for v in [0,1,2,2,1,3] { triangles.append(WorldVertex(points[indices[v]],SIMD4(1,0.04,0.02,0.12))) }
                for (a,b) in [(0,1),(1,3),(3,2),(2,0)] {
                    lines.append(WorldVertex(points[indices[a]],SIMD4(1,0.12,0.07,0.65)))
                    lines.append(WorldVertex(points[indices[b]],SIMD4(1,0.12,0.07,0.65)))
                }
            }
            face([4,5,6,7]) // Diagnostic ceiling; no claim that a physical surface exists here.
            for (dx,dz,indices) in [(-1,0,[0,2,4,6]),(1,0,[1,3,5,7]),(0,-1,[0,1,4,5]),(0,1,[2,3,6,7])] {
                let nx = x+dx,nz = z+dz
                if nx >= 0,nx < grid.columns,nz >= 0,nz < grid.rows,
                   let neighbor = heights[nz*grid.columns+nx],neighbor >= column.ceiling { continue }
                face(indices)
            }
        }
        blockingBuffer = buffer(triangles); blockingCount = triangles.count
        blockingLines = buffer(lines); blockingLineCount = lines.count
    }
    private func updatePathBuffer(_ presentation: PathPresentation?, projection: RouteProjection?) {
        guard presentation != nil || projection != nil else {
            pathBuffer = nil; pathCount = 0; pathApproachCount = 0; pathTargetCount = 0; pathKey = ""; return
        }
        // A proof suffix can expire between analysis frames. Include ALL geometry, not
        // only the first point/frame ID, so the cached buffer cannot retain an expired tail.
        let key = "\(presentation?.path.epoch ?? projection?.epoch ?? 0):\(presentation?.path.parameterVersion ?? projection?.parameterVersion ?? 0):\(presentation?.path.id ?? 0):\(presentation?.path.validatedFrameID ?? 0):\(presentation?.path.points.hashValue ?? 0):\(String(describing: presentation?.approach.first)):\(presentation?.historical ?? false):\(projection?.frameID ?? 0)"
        guard key != pathKey else { return }; pathKey = key
        var meshes = presentation.map { PathDrawing.meshes($0) } ?? []
        if let projection { meshes.append(PathDrawing.projectionMesh(projection, observed: presentation)) }
        var vertices: [WorldVertex] = []; pathApproachCount = 0; pathTargetCount = 0
        for mesh in meshes {
            let color: SIMD4<Float>
            switch mesh.role {
            case .unknownApproach: color = SIMD4(0.1,0.85,1,0.7); pathApproachCount += mesh.vertices.count
            case .prediction: color = SIMD4(0.65,0.75,1,0.6)
            case .history: color = SIMD4(1,0.52,0.08,0.85)
            case .observed: color = SIMD4(1,0.96,0.18,1)
            case .target: color = (presentation?.historical == true && presentation?.path.worldLocked != true) ? SIMD4(1,0.52,0.08,0.9) : SIMD4(1,0.96,0.18,1); pathTargetCount += mesh.vertices.count
            }
            vertices += mesh.vertices.map { WorldVertex($0,color) }
        }
        pathBuffer = buffer(vertices); pathCount = vertices.count
    }
    private func updateSurfaceBuffers(_ presentation: SurfacePresentation?) {
        guard let presentation,let model = presentation.result.surfaceModel else {
            surfaceBuffer = nil; surfaceCount = 0; surfaceKey = ""; return
        }
        let result = presentation.result
        let key = "\(result.epoch)-\(result.parameterVersion)-\(result.frameID)-\(presentation.historical)"
        guard key != surfaceKey else { return }; surfaceKey = key
        let vertices = model.triangles.flatMap { triangle -> [WorldVertex] in
            let color: SIMD4<Float> = triangle.surface == .ground
                ? SIMD4(0.1,0.45,1,presentation.historical ? 0.22 : 0.50)
                : SIMD4(1,0.08,0.04,presentation.historical ? 0.22 : 0.75)
            let points = presentation.historical ? [triangle.a,triangle.b,triangle.b,triangle.c,triangle.c,triangle.a]
                                                 : [triangle.a,triangle.b,triangle.c]
            return points.map { WorldVertex($0,color) }
        }
        surfaceBuffer = buffer(vertices); surfaceCount = vertices.count
    }
    private func updateAnalysisBuffers(_ result: AnalysisResult?,epoch: UInt64) {
        guard let result,let grid = result.grid else { analysisKey = ""; blockingBuffer = nil; blockingCount = 0; blockingLines = nil; blockingLineCount = 0; gridBuffer = nil; channelBuffer = nil; gridCount = 0; channelCount = 0; return }
        let key = "\(epoch)-\(result.parameterVersion)-\(result.frameID)"
        guard key != analysisKey else { return }; analysisKey = key
        updateBlockingBuffers(result.surfaceModel?.blockingVolume,grid:grid)
        var triangles: [WorldVertex] = [],lines: [WorldVertex] = []
        for i in grid.cells.indices {
            let center = grid.center(i),h = grid.cellSize*0.46,cell = grid.cells[i]
            let color: SIMD4<Float>
            switch cell.state {
            case .unknown: color = SIMD4(0.6,0.6,0.65,0.18)
            case .obstacle: color = SIMD4(1,0.2,0.1,0.55)
            case .candidate: color = SIMD4(0.1,0.85,0.7,0.3)
            }
            let corners = [(-h,-h),(h,-h),(-h,h),(h,h)].map { grid.basis.world(x:center.x+$0.0,h:0.015,z:center.y+$0.1) }
            for c in [0,1,2,2,1,3] { triangles.append(WorldVertex(corners[c],color)) }
        }
        for segment in result.segments {
            for n in 1..<segment.cellIndices.count {
                for i in [segment.cellIndices[n-1],segment.cellIndices[n]] {
                    let c = grid.center(i); lines.append(WorldVertex(grid.basis.world(x:c.x,h:0.04,z:c.y),SIMD4(1,0.85,0.05,1)))
                }
            }
        }
        gridBuffer = buffer(triangles); gridCount = triangles.count; channelBuffer = buffer(lines); channelCount = lines.count
    }
}
