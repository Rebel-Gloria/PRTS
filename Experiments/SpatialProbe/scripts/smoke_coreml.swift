import Foundation
import CoreML
import CoreVideo
import SpatialCore

/// Synthetic pixels only; checks the same production preprocessing/inference path, not accuracy.
@main enum CoreMLSmoke {
    static func main() throws {
        let compiled = try MLModel.compileModel(at:URL(fileURLWithPath:CommandLine.arguments[1]))
        defer { try? FileManager.default.removeItem(at:compiled) }
        let network = CoreMLDepthModel(modelURL:compiled,computeUnits:.cpuOnly)
        var image: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,640,480,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey:[:]] as CFDictionary,&image) == kCVReturnSuccess)
        let input = image!
        CVPixelBufferLockBaseAddress(input,[])
        for y in 0..<480 { for x in 0..<640 {
            let p = CVPixelBufferGetBaseAddress(input)!.advanced(by:y*CVPixelBufferGetBytesPerRow(input)+x*4).assumingMemoryBound(to:UInt8.self)
            let c: [UInt8] = y < 240 ? (x < 320 ? [0,0,255,255] : [0,255,0,255]) : (x < 320 ? [255,0,0,255] : [255,255,255,255])
            for i in 0..<4 { p[i] = c[i] }
        }}
        CVPixelBufferUnlockBaseAddress(input,[])
        var observations: [[String:Any]] = []
        for orientation in ImageOrientation.allCases {
            let (buffer,mapping) = try network.prepareInput(imageBuffer:input,orientation:orientation,width:518,height:392)
            CVPixelBufferLockBaseAddress(buffer,.readOnly)
            for v: Float in [60,420] { for u: Float in [80,560] {
                let uv = mapping.modelPixel(u:u,v:v),x = Int(uv.x.rounded()),y = Int(uv.y.rounded())
                let p = CVPixelBufferGetBaseAddress(buffer)!.advanced(by:y*CVPixelBufferGetBytesPerRow(buffer)+x*4).assumingMemoryBound(to:UInt8.self)
                let expected: [UInt8] = v < 240 ? (u < 320 ? [0,0,255] : [0,255,0]) : (u < 320 ? [255,0,0] : [255,255,255])
                for i in 0..<3 { precondition(abs(Int(p[i])-Int(expected[i])) < 12,"preprocessing orientation/pixel mapping mismatch") }
            }}
            CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
            let start = ProcessInfo.processInfo.systemUptime
            let o = try network.infer(imageBuffer:input,orientation:orientation)
            precondition(o.width == 256 && o.height == 192 && o.relative.count == 49152)
            precondition(o.relative.allSatisfy(\.isFinite))
            observations.append(["orientation":orientation.rawValue,"width":o.width,"height":o.height,"finite":o.relative.filter(\.isFinite).count,
                "minimum":o.relative.min()!,"maximum":o.relative.max()!,"milliseconds":(ProcessInfo.processInfo.systemUptime-start)*1000])
        }
        let result: [String:Any] = ["source":"synthetic_color_quadrants_not_sensor_evidence","compute":"mac_cpu_only","preprocessing":"all_four_orientations_full_view_passed","inference":observations]
        print(String(data:try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]),encoding:.utf8)!)
    }
}
