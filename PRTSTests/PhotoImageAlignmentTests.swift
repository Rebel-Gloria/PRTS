import CoreGraphics
import CoreVideo
import SpatialCore
import Testing
import UIKit
@testable import PRTS

@MainActor
struct PhotoImageAlignmentTests {
    @Test func quadrantColorsRotateWithoutMirroringOrCropping() throws {
        var storage: CVPixelBuffer?
        #expect(CVPixelBufferCreate(kCFAllocatorDefault, 160, 120, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &storage) == kCVReturnSuccess)
        let buffer = try #require(storage)
        let colors: [[UInt8]] = [[255, 0, 0], [0, 255, 0], [0, 0, 255], [255, 255, 0]]
        CVPixelBufferLockBaseAddress(buffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(buffer)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0..<120 {
            for x in 0..<160 {
                let color = colors[(y < 60 ? 0 : 2) + (x < 80 ? 0 : 1)]
                let offset = y * stride + x * 4
                base[offset] = color[2]; base[offset + 1] = color[1]
                base[offset + 2] = color[0]; base[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let rotations: [(ImageOrientation, [Int])] = [
            (.landscapeRight, [0, 1, 2, 3]),
            (.portrait, [2, 0, 3, 1]),
            (.landscapeLeft, [3, 2, 1, 0]),
            (.portraitUpsideDown, [1, 3, 0, 2])
        ]
        for (orientation, expected) in rotations {
            let jpeg = try PhotoImageEncoder.jpeg(pixelBuffer: buffer, orientation: orientation)
            let image = try #require(UIImage(data: jpeg)?.cgImage)
            for quadrant in 0..<4 {
                let x = image.width * (quadrant % 2 == 0 ? 1 : 3) / 4
                let y = image.height * (quadrant < 2 ? 1 : 3) / 4
                let color = try sample(image: image, x: x, y: y)
                for component in 0..<3 {
                    #expect(abs(Int(color[component]) - Int(colors[expected[quadrant]][component])) < 30)
                }
            }
        }
    }

    private func sample(image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        let pixel = try #require(image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)))
        var rgba = [UInt8](repeating: 0, count: 4)
        try rgba.withUnsafeMutableBytes { bytes in
            let context = try #require(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return rgba
    }
}
