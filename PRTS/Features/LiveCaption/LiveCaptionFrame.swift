import CoreImage
import Foundation

nonisolated struct LiveCaptionFrame {
    let sampledAt: TimeInterval
    let jpeg: Data
    let grayscale: [UInt8]
    // Sampling runs four times a second; a context is costly to create.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    static func capture(image: CIImage, sampledAt: TimeInterval) throws -> Self {
        let jpeg = try PhotoImageEncoder.jpeg(
            image: image,
            longestSide: PhotoImagePurpose.liveCaption.longestSide(highResolution: false)
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

    static func select(_ frames: [Self]) -> [Self] {
        guard frames.count >= 4 else { return [] }
        // The first frame anchors the motion accumulated within this window.
        var candidates: [(index: Int, cumulative: Double)] = [(0, 0)]
        var cumulative = 0.0
        for index in 1..<frames.count {
            let amount = motion(frames[index - 1].grayscale, frames[index].grayscale)
            cumulative += amount
            if amount > 0 { candidates.append((index, cumulative)) }
        }
        guard candidates.count >= 4 else { return [] }
        var selected: [Int] = []
        for step in 0..<4 {
            let target = cumulative * Double(step) / 3
            let nearest = candidates.indices.min {
                abs(candidates[$0].cumulative - target) < abs(candidates[$1].cumulative - target)
            }!
            selected.append(candidates.remove(at: nearest).index)
        }
        return selected.sorted().map { frames[$0] }
    }
}
