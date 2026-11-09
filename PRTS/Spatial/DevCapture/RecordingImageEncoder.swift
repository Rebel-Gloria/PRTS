#if PRTS_DEV_CAPTURE
import CoreImage
import Foundation
import ImageIO

/// Reuse Core Image resources across frames; the recorder calls this on its encoding queue.
nonisolated final class RecordingImageEncoder: @unchecked Sendable {
    private lazy var context = CIContext(options: [.cacheIntermediates: false])

    func encode(_ pixel: CVPixelBuffer, to url: URL) throws {
        try context.writeHEIFRepresentation(
            of: CIImage(cvPixelBuffer: pixel),
            to: url,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [.init(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.9]
        )
    }
}
#endif
