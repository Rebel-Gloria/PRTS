import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The bundled model takes one image per question, so consecutive frames share one picture.
nonisolated enum LiveCaptionCollage {
    static let columns = 2

    static func jpeg(frames: [Data]) throws -> Data {
        let images = frames.compactMap { data -> CGImage? in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        guard let first = images.first else { throw PhotoChatError.emptyInput }
        let cell = (width: first.width / columns, height: first.height / columns)
        let rows = (images.count + columns - 1) / columns
        guard
            let context = CGContext(
                data: nil,
                width: cell.width * columns,
                height: cell.height * rows,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        else { throw PhotoChatError.emptyInput }
        for (index, image) in images.enumerated() {
            context.draw(
                image,
                in: CGRect(
                    x: index % columns * cell.width,
                    y: (rows - 1 - index / columns) * cell.height,
                    width: cell.width,
                    height: cell.height
                )
            )
        }
        let output = NSMutableData()
        guard let result = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { throw PhotoChatError.emptyInput }
        CGImageDestinationAddImage(
            destination,
            result,
            [kCGImageDestinationLossyCompressionQuality: LiveCaptionPolicy.imageQuality]
                as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw PhotoChatError.emptyInput }
        return output as Data
    }
}
