import Foundation
import CoreML
import CoreImage
import ImageIO
import SpatialCore

/// Same portable inference implementation is exercised by scripts/smoke_coreml.swift.
/// No camera/session ownership and no image persistence.
final class CoreMLDepthModel {
    private var model: MLModel?
    private let modelURL: URL?
    private let computeUnits: MLComputeUnits
    private lazy var context = CIContext(options:[.cacheIntermediates:false])
    init(modelURL: URL? = nil,computeUnits: MLComputeUnits = .all) { self.modelURL = modelURL; self.computeUnits = computeUnits }
    private func load() throws -> MLModel {
        if let model { return model }
        guard let url = modelURL ?? Bundle.main.url(forResource:"DepthAnythingV2SmallF16",withExtension:"mlmodelc") else {
            throw NSError(domain:"Monocular",code:1,userInfo:[NSLocalizedDescriptionKey:"Apple Core ML 模型资源缺失"])
        }
        let config = MLModelConfiguration(); config.computeUnits = computeUnits
        let result = try MLModel(contentsOf:url,configuration:config); model = result; return result
    }
    func infer(imageBuffer: CVPixelBuffer,orientation: ImageOrientation) throws -> (width: Int,height: Int,relative: [Float],timings: [String:Double]) {
        let start = ProcessInfo.processInfo.systemUptime
        let model = try load()
        let loaded = ProcessInfo.processInfo.systemUptime
        guard let input = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { throw failure("模型输入不是预期的 image") }
        let mw = input.pixelsWide,mh = input.pixelsHigh
        let (buffer,mapping) = try prepareInput(imageBuffer:imageBuffer,orientation:orientation,width:mw,height:mh)
        let prepared = ProcessInfo.processInfo.systemUptime
        let output = try model.prediction(from:MLDictionaryFeatureProvider(dictionary:["image":MLFeatureValue(pixelBuffer:buffer)]))
        let predicted = ProcessInfo.processInfo.systemUptime
        guard let pixels = output.featureValue(for:"depth")?.imageBufferValue else { throw failure("模型未输出 depth 图像") }
        let ow = CVPixelBufferGetWidth(pixels),oh = CVPixelBufferGetHeight(pixels),format = CVPixelBufferGetPixelFormatType(pixels)
        guard ow == mw,oh == mh,[kCVPixelFormatType_OneComponent16Half,kCVPixelFormatType_OneComponent32Float,kCVPixelFormatType_DepthFloat32].contains(format),
              CVPixelBufferLockBaseAddress(pixels,.readOnly) == kCVReturnSuccess else { throw failure("模型输出格式或尺寸不支持") }
        defer { CVPixelBufferUnlockBaseAddress(pixels,.readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw failure("模型输出无法读取") }
        let w = 256,h = max(1,Int((Float(w)*Float(CVPixelBufferGetHeight(imageBuffer))/Float(CVPixelBufferGetWidth(imageBuffer))).rounded()))
        var raw = [Float](repeating:.nan,count:w*h)
        func value(_ x: Int,_ y: Int) -> Float {
            let row = base.advanced(by:y*CVPixelBufferGetBytesPerRow(pixels))
            return format == kCVPixelFormatType_OneComponent16Half ? Float(row.load(fromByteOffset:x*2,as:Float16.self)) : row.load(fromByteOffset:x*4,as:Float.self)
        }
        for y in 0..<h { for x in 0..<w {
            let p = mapping.modelPixel(u:(Float(x)+0.5)*Float(CVPixelBufferGetWidth(imageBuffer))/Float(w)-0.5,v:(Float(y)+0.5)*Float(CVPixelBufferGetHeight(imageBuffer))/Float(h)-0.5)
            let xx = max(0,min(ow-1,Int(p.x.rounded()))),yy = max(0,min(oh-1,Int(p.y.rounded())))
            raw[y*w+x] = value(xx,yy)
        }}
        return (w,h,raw,["modelLoad":(loaded-start)*1000,"modelPreprocess":(prepared-loaded)*1000,
            "coreMLPrediction":(predicted-prepared)*1000,"modelOutputRemap":(ProcessInfo.processInfo.systemUptime-predicted)*1000])
    }
    func prepareInput(imageBuffer: CVPixelBuffer,orientation: ImageOrientation,width: Int,height: Int) throws -> (CVPixelBuffer,ModelImageMapping) {
        let mw = width,mh = height
        let mapping = ModelImageMapping(width:CVPixelBufferGetWidth(imageBuffer),height:CVPixelBufferGetHeight(imageBuffer),modelWidth:mw,modelHeight:mh,orientation:orientation)
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(nil,mw,mh,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&buffer) == kCVReturnSuccess,let buffer else { throw failure("模型输入分配失败") }
        let cgOrientation: CGImagePropertyOrientation
        switch orientation { case .landscapeRight: cgOrientation = .up; case .portrait: cgOrientation = .right; case .landscapeLeft: cgOrientation = .down; case .portraitUpsideDown: cgOrientation = .left }
        let image = CIImage(cvPixelBuffer:imageBuffer).oriented(cgOrientation)
        let fit = mapping.fit
        let scaled = image.transformed(by:CGAffineTransform(scaleX:CGFloat(fit.width)/image.extent.width,y:CGFloat(fit.height)/image.extent.height))
            .transformed(by:CGAffineTransform(translationX:CGFloat(fit.x),y:CGFloat(fit.y)))
        let background = CIImage(color:CIColor(red:0.485,green:0.456,blue:0.406)).cropped(to:CGRect(x:0,y:0,width:mw,height:mh))
        context.render(scaled.composited(over:background),to:buffer,bounds:CGRect(x:0,y:0,width:mw,height:mh),colorSpace:CGColorSpace(name:CGColorSpace.sRGB))
        return (buffer,mapping)
    }
    private func failure(_ description: String) -> NSError { NSError(domain:"Monocular",code:2,userInfo:[NSLocalizedDescriptionKey:description]) }
}
