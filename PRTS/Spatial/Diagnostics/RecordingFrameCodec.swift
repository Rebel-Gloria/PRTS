import ARKit
import Foundation
import SpatialCore

/// Lossless sensor packet: UInt32LE JSON byte length, UTF-8 header, then packed binary sections.
/// Row padding is omitted; sample bits, dimensions and all public feature points are preserved.
nonisolated enum RecordingFrameCodec {
    private struct Section: Codable {
        let name: String
        let offset: Int
        let bytes: Int
        let width: Int
        let height: Int
        let pixelFormat: UInt32
    }
    private struct Header: Encodable {
        let schemaVersion = 1
        let kind = "sensor_frame"
        let epoch: UInt64, frameID: UInt64
        let timestamp: Double
        let sections: [Section]
        let featureCount: Int
        let featureLayout = "UInt64LE identifier, Float32LE x,y,z; 20 bytes per point"
        let planes: [NativePlaneObservation]
    }

    static func encode(_ frame: FrameSnapshot) throws -> Data {
        var payload = Data()
        var sections: [Section] = []
        func append(_ buffer: CVPixelBuffer?, name: String, bytesPerPixel: Int) throws {
            guard let buffer else { return }
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
                throw RecordingError.writeFailed
            }
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw RecordingError.writeFailed
            }
            let width = CVPixelBufferGetWidth(buffer)
            let height = CVPixelBufferGetHeight(buffer)
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            let rowBytes = width * bytesPerPixel
            guard stride >= rowBytes else { throw RecordingError.writeFailed }
            sections.append(
                .init(
                    name: name,
                    offset: payload.count,
                    bytes: rowBytes * height,
                    width: width,
                    height: height,
                    pixelFormat: CVPixelBufferGetPixelFormatType(buffer)
                )
            )
            for row in 0..<height {
                payload.append(
                    base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self),
                    count: rowBytes
                )
            }
        }
        try append(frame.frame.sceneDepth?.depthMap, name: "depth", bytesPerPixel: 4)
        try append(frame.frame.sceneDepth?.confidenceMap, name: "confidence", bytesPerPixel: 1)
        try append(
            frame.frame.smoothedSceneDepth?.depthMap,
            name: "smoothed_depth",
            bytesPerPixel: 4
        )
        try append(
            frame.frame.smoothedSceneDepth?.confidenceMap,
            name: "smoothed_confidence",
            bytesPerPixel: 1
        )
        let points = frame.frame.rawFeaturePoints
        let count = points?.points.count ?? 0
        sections.append(
            .init(
                name: "feature_points",
                offset: payload.count,
                bytes: count * 20,
                width: count,
                height: 1,
                pixelFormat: 0
            )
        )
        if let points {
            for index in 0..<count {
                var identifier = points.identifiers[index].littleEndian
                withUnsafeBytes(of: &identifier) { payload.append(contentsOf: $0) }
                let point = points.points[index]
                for value in [point.x, point.y, point.z] {
                    var bits = value.bitPattern.littleEndian
                    withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
                }
            }
        }
        let header = Header(
            epoch: frame.epoch,
            frameID: frame.id,
            timestamp: frame.frame.timestamp,
            sections: sections,
            featureCount: count,
            planes: MonocularDepthProvider.planes(frame)
        )
        let json = try DiagnosticJSON.encode(header)
        var length = UInt32(json.count).littleEndian
        var data = withUnsafeBytes(of: &length) { Data($0) }
        data.append(json)
        data.append(payload)
        return data
    }
}
