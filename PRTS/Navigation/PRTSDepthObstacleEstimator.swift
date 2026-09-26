import Foundation
import CoreVideo

struct PRTSDepthObstacleEstimator {
    var maxDistanceMeters: Float = 4.5
    var minimumValidSamples = 8

    func estimate(detections: [PRTSObjectDetection], depthMap: CVPixelBuffer?, imageSize: CGSize) -> [PRTSObstacleObservation] {
        guard let depthMap else { return [] }
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return [] }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let pixels = base.assumingMemoryBound(to: Float32.self)

        return detections.compactMap { detection in
            guard detection.blocking else { return nil }
            let x0 = max(0, Int(detection.box.minX * CGFloat(width)))
            let x1 = min(width - 1, Int(detection.box.maxX * CGFloat(width)))
            let y0 = max(0, Int(detection.box.minY * CGFloat(height)))
            let y1 = min(height - 1, Int(detection.box.maxY * CGFloat(height)))
            guard x1 >= x0, y1 >= y0 else { return nil }
            var samples: [Float] = []
            for y in stride(from: y0, through: y1, by: max(1, (y1 - y0) / 12)) {
                for x in stride(from: x0, through: x1, by: max(1, (x1 - x0) / 12)) {
                    let value = pixels[y * stride + x]
                    if value.isFinite, value > 0.05, value <= maxDistanceMeters { samples.append(value) }
                }
            }
            guard samples.count >= minimumValidSamples else { return nil }
            samples.sort()
            let distance = samples[max(0, Int(Float(samples.count - 1) * 0.05))]
            let center = Float(detection.box.midX - 0.5) * .pi / 3.0
            return PRTSObstacleObservation(label: detection.label, distanceMeters: distance, azimuthRadians: center, box: detection.box, score: detection.score)
        }
    }
}
