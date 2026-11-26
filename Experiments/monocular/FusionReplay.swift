// Mac fixture values for the inputs read by MonocularDepthProvider, not an ARKit session.
// Its model, pixel mapping, sample collection, ground tracker and scale decision are product code.
import CoreImage
import CoreML
import Foundation
import ImageIO
import SpatialCore

class ARAnchor {}
final class ARPlaneAnchor: ARAnchor {
    enum Alignment { case horizontal, vertical }
    enum Classification { case floor, none, table, other }
    struct Geometry { let boundaryVertices: [V3] }
    let alignment = Alignment.horizontal
    let classification = Classification.floor
    let identifier = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let transform: RigidPose
    let geometry: Geometry
    init(boundary: [V3], height: Float) {
        transform = RigidPose(position: V3(0, height, 0))
        geometry = Geometry(boundaryVertices: boundary)
    }
}

extension RigidPose {
    init(_ syntheticPlanePose: Self) { self = syntheticPlanePose }
}

struct FeatureCloud {
    let points: [V3], identifiers: [UInt64]
}
struct FixtureFrame {
    let capturedImage: CVPixelBuffer
    let timestamp: Double
    let rawFeaturePoints: FeatureCloud?
    let anchors: [ARAnchor]
}
struct FrameSnapshot {
    let frame: FixtureFrame
    let epoch: UInt64 = 1, parameterVersion: UInt64 = 1
    let orientation: ImageOrientation = .landscapeRight
    let parameters = ProbeParameters()
    let id: UInt64, trackingNormal: Bool, pose: RigidPose, intrinsics: CameraIntrinsics
}

private struct Scene: Decodable {
    struct Feature: Decodable { let id: UInt64, world: V3, surface: Int }
    struct Frame: Decodable {
        let stem: String, time: Double, position: V3, yaw: Float, features: [Feature]
    }
    let width: Int, height: Int, fx: Float, fy: Float, cx: Float, cy: Float
    let floorBoundary: [V3], frames: [Frame]
}

private enum References: String {
    case combined, features, floor, none, withoutBox, noisy, interrupted, layered

    func cloud(_ frame: Scene.Frame, hidden: [Scene.Feature]) -> FeatureCloud? {
        guard self != .none, self != .floor else { return nil }
        let features =
            frame.features.filter { self != .withoutBox || $0.surface != 2 }
            + (self == .layered ? hidden : [])
        let points = features.map { feature in
            guard self == .noisy else { return feature.world }
            // A small static map error and an axial outlier for one in seven IDs (not RGB noise).
            let id = Float(feature.id)
            return feature.world
                + V3(0.015 * sin(id), 0.015 * cos(id), feature.id % 7 == 0 ? 0.4 : 0)
        }
        return FeatureCloud(points: points, identifiers: features.map(\.id))
    }
    var usesFloor: Bool {
        self == .combined || self == .floor || self == .noisy || self == .interrupted
    }
}

private struct Row: Encodable {
    let stem: String, time: Double, width: Int, height: Int
    let confirmed: Bool, decision: String, confirmations: Int
    let featureCount: Int, floorCount: Int, matchingFeatureIDs: Int, ground: String
}

@main private enum FusionReplay {
    static func fail(_ reason: String) -> NSError {
        NSError(domain: "FusionReplay", code: 1, userInfo: [NSLocalizedDescriptionKey: reason])
    }

    static func pixels(at url: URL, context: CIContext) throws -> CVPixelBuffer {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw fail("Cannot decode " + url.path) }
        var buffer: CVPixelBuffer?
        guard
            CVPixelBufferCreate(
                nil,
                image.width,
                image.height,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &buffer
            ) == kCVReturnSuccess, let buffer
        else { throw fail("Cannot allocate RGB input") }
        context.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

    static func floats(_ values: [Float], to url: URL) throws {
        // Supported Apple hosts store Float32 in little-endian order.
        try values.withUnsafeBytes { try Data($0).write(to: url) }
    }

    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 4 else {
            throw fail("usage: fusion-replay image|REFERENCES INPUT OUTPUT")
        }
        let source = URL(fileURLWithPath: args[2])
        let output = URL(fileURLWithPath: args[3])
        let context = CIContext(options: [.cacheIntermediates: false])
        if args[1] == "image" {
            let result = try CoreMLDepthModel().infer(
                imageBuffer: pixels(at: source, context: context),
                orientation: .landscapeRight
            )
            try floats(result.relative, to: output)
            print(
                "relative inverse depth: \(result.width) × \(result.height); no metric references"
            )
            return
        }
        guard let mode = References(rawValue: args[1]) else { throw fail("Unknown reference mode") }
        let scene = try JSONDecoder().decode(
            Scene.self,
            from: Data(contentsOf: source.appendingPathComponent("manifest.json"))
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let camera = CameraIntrinsics(
            fx: scene.fx,
            fy: scene.fy,
            cx: scene.cx,
            cy: scene.cy,
            width: scene.width,
            height: scene.height
        )
        let provider = MonocularDepthProvider()
        let floor = ARPlaneAnchor(boundary: scene.floorBoundary, height: mode == .noisy ? 0.03 : 0)
        // Stress control: fixed world landmarks behind half the initially visible features.
        // Their IDs and positions don't follow the camera. They are not LiDAR measurements.
        var hidden: [Scene.Feature] = []
        if mode == .layered, let first = scene.frames.first {
            let lastID = scene.frames.flatMap(\.features).map(\.id).max() ?? 0
            for (i, f) in first.features.enumerated() where i.isMultiple(of: 2) {
                for (j, scale) in [Float(1.65), 1.68, 1.72, 1.75].enumerated() {
                    hidden.append(
                        .init(
                            id: lastID + 1 + UInt64(i * 4 + j),
                            world: first.position + (f.world - first.position) * scale,
                            surface: 0
                        )
                    )
                }
            }
        }
        var rows: [Row] = []
        for (i, frame) in scene.frames.enumerated() {
            let row = try autoreleasepool {
                let image = try pixels(
                    at: source.appendingPathComponent(frame.stem + ".png"),
                    context: context
                )
                guard CVPixelBufferGetWidth(image) == scene.width,
                    CVPixelBufferGetHeight(image) == scene.height
                else { throw fail("RGB/intrinsics size mismatch") }
                let sinY = sin(frame.yaw)
                let cosY = cos(frame.yaw)
                let pose = RigidPose(
                    right: V3(cosY, 0, -sinY),
                    back: V3(sinY, 0, cosY),
                    position: frame.position
                )
                let tracking = mode != .interrupted || !(5...6).contains(i)
                let native = FixtureFrame(
                    capturedImage: image,
                    timestamp: frame.time,
                    rawFeaturePoints: mode.cloud(frame, hidden: hidden),
                    anchors: mode.usesFloor ? [floor] : []
                )
                let result = try provider.predict(
                    .init(
                        frame: native,
                        id: UInt64(i + 1),
                        trackingNormal: tracking,
                        pose: pose,
                        intrinsics: camera
                    )
                )
                let w = result.width
                let h = result.height
                func file(_ ext: String) -> URL { output.appendingPathComponent(frame.stem + ext) }
                try floats(result.relative, to: file(".q.f32"))
                try floats(
                    result.observation?.depth ?? Array(repeating: .nan, count: w * h),
                    to: file(".m.f32")
                )
                var used = [UInt8](repeating: 0, count: w * h)
                for pixel in result.references.pixelIndices { used[pixel] = 1 }
                try Data(used).write(to: file(".used.u8"))
                let features = result.samples.filter { $0.featureID != nil }.count
                return Row(
                    stem: frame.stem,
                    time: frame.time,
                    width: w,
                    height: h,
                    confirmed: result.observation != nil,
                    decision: result.scaleDecision.reason,
                    confirmations: result.scaleDecision.confirmations,
                    featureCount: features,
                    floorCount: result.samples.count - features,
                    matchingFeatureIDs: result.scaleDecision.matchingFeatureIDs,
                    ground: result.groundReference.mode
                )
            }
            rows.append(row)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(rows).write(to: output.appendingPathComponent("frames.json"))
    }
}
