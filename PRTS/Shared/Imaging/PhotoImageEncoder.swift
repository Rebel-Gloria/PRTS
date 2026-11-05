import CoreImage
import CoreVideo
import ImageIO
import SpatialCore

nonisolated enum PhotoImagePurpose {
    case description, question, textReading, liveCaption

    static let highResolutionKey = "photoDescription.highResolution"

    func longestSide(highResolution: Bool) -> CGFloat {
        switch self {
        case .question, .textReading: highResolution ? 1920 : 1280
        case .description: 1280
        case .liveCaption: 960
        }
    }
}

/// Rotation precedes proportional downsampling to preserve the full camera view.
nonisolated enum PhotoImageEncoder {
    static func jpeg(
        pixelBuffer: CVPixelBuffer,
        orientation: ImageOrientation,
        longestSide: CGFloat
    ) throws -> Data {
        try jpeg(
            image: image(pixelBuffer: pixelBuffer, orientation: orientation),
            longestSide: longestSide
        )
    }

    static func image(pixelBuffer: CVPixelBuffer, orientation imageOrientation: ImageOrientation)
        -> CIImage
    {
        let orientation: CGImagePropertyOrientation
        switch imageOrientation {
        case .portrait: orientation = .right
        case .portraitUpsideDown: orientation = .left
        case .landscapeLeft: orientation = .down
        case .landscapeRight: orientation = .up
        }
        return CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
    }

    static func jpeg(image: CIImage, longestSide: CGFloat) throws -> Data {
        var image = image
        let scale = min(1, longestSide / max(image.extent.width, image.extent.height))
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let data = context.jpegRepresentation(
                of: image,
                colorSpace: colorSpace,
                options: [
                    kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8
                ]
            )
        else {
            throw PhotoChatError.emptyInput
        }
        return data
    }
}
