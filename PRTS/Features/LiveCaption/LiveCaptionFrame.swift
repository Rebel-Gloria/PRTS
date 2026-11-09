import CoreImage
import Foundation

nonisolated struct LiveCaptionFrame {
    let sampledAt: TimeInterval
    let jpeg: Data
    let grayscale: [UInt8]
    // Sampling runs ten times a second; a context is costly to create.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func capture(image: CIImage, sampledAt: TimeInterval) throws -> Self {
        let jpeg = try PhotoImageEncoder.jpeg(
            image: image,
            longestSide: PhotoImagePurpose.liveCaption.longestSide(highResolution: false),
            quality: LiveCaptionPolicy.imageQuality
        )
        let thumbnail = image.transformed(
            by: CGAffineTransform(scaleX: 48 / image.extent.width, y: 64 / image.extent.height)
        )
        var grayscale = [UInt8](repeating: 0, count: 48 * 64)
        grayscale.withUnsafeMutableBytes { bytes in
            context.render(
                thumbnail,
                toBitmap: bytes.baseAddress!,
                rowBytes: 48,
                bounds: CGRect(x: 0, y: 0, width: 48, height: 64),
                format: .L8,
                colorSpace: CGColorSpaceCreateDeviceGray()
            )
        }
        return Self(sampledAt: sampledAt, jpeg: jpeg, grayscale: grayscale)
    }

    static func motion(_ previous: [UInt8], _ current: [UInt8]) -> Double {
        let difference = zip(previous, current).reduce(0) {
            $0 + abs(Int($1.0) - Int($1.1))
        }
        return Double(difference) / Double(current.count)
    }

    /// Spaces frames evenly along the accumulated motion, or along time in a still scene.
    static func select(_ frames: [Self], count: Int? = nil) -> [Self] {
        guard frames.count > 1 else { return frames }
        var positions = [0.0]
        for index in 1..<frames.count {
            positions.append(
                positions[index - 1] + motion(frames[index - 1].grayscale, frames[index].grayscale)
            )
        }
        let count = min(
            count ?? LiveCaptionPolicy.frameCount(motion: positions[positions.count - 1]),
            frames.count
        )
        guard count > 1 else { return Array(frames.prefix(count)) }
        if positions.last == 0 { positions = frames.indices.map(Double.init) }
        var candidates = Array(zip(frames.indices, positions))
        var selected: [Int] = []
        for step in 0..<count {
            let target = positions[positions.count - 1] * Double(step) / Double(count - 1)
            let nearest = candidates.indices.min {
                abs(candidates[$0].1 - target) < abs(candidates[$1].1 - target)
            }!
            selected.append(candidates.remove(at: nearest).0)
        }
        return selected.sorted().map { frames[$0] }
    }
}
