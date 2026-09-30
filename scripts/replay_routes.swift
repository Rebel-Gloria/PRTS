// Offline Dev Capture replay. Reads local recorded analysis/depth; never starts sensors.
// Build after swift build --package-path Vendor/SpatialCore, linking SpatialCore.build/*.o.
import Foundation

@testable import SpatialCore

struct Reference: Decodable { let file: String }
struct Sample: Decodable {
    let evidence: Reference
    let depth: Reference?
}
struct RecordedCapture: Decodable { let intrinsics: CameraIntrinsics? }
struct Evidence: Decodable {
    let capture: RecordedCapture?
    let analysis: AnalysisResult
    let pathOptions: PathOptions
}
struct DepthHeader: Decodable {
    let width: Int, height: Int
    let intrinsics: CameraIntrinsics
    let pose: RigidPose
    let timestamp: Double
    let frameID: UInt64, epoch: UInt64
    let confidenceBytes: Int
}
struct ReplayRow: Encodable {
    let epoch: UInt64, frameID: UInt64
    let timestamp: Double
    let update: PathUpdate
    let fresh: Bool
    let supportedByCurrentGrid: Bool?
    let currentObstacleFree: Bool?
    let confirmedModelFree: Bool?
}
let decoder = JSONDecoder()
decoder.nonConformingFloatDecodingStrategy = .convertFromString(
    positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys]
func unpack(_ directory: URL, _ ref: Reference) throws -> Data {
    guard !ref.file.contains("/"), !ref.file.contains("\\"),
        ref.file != ".", ref.file != ".."
    else { throw CocoaError(.fileReadInvalidFileName) }
    let compressed = try Data(contentsOf: directory.appendingPathComponent(ref.file))
    return try (compressed as NSData).decompressed(using: .zlib) as Data
}
for path in CommandLine.arguments.dropFirst() {
    let directory = URL(fileURLWithPath: path)
    var predictor = PathPredictor()
    let text = try String(contentsOf: directory.appendingPathComponent("samples.jsonl"), encoding: .utf8)
    for line in text.split(separator: "\n") {
        let sample = try decoder.decode(Sample.self, from: Data(line.utf8))
        let evidence = try decoder.decode(Evidence.self, from: unpack(directory, sample.evidence))
        var observation: DepthObservation?
        if let ref = sample.depth {
            let raw = try unpack(directory, ref)
            let size = Int(raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
            let header = try decoder.decode(DepthHeader.self, from: raw.subdata(in: 4..<(4 + size)))
            let count = header.width * header.height
            let offset = 4 + size
            let depth = raw.withUnsafeBytes { bytes in
                (0..<count).map {
                    Float(
                        bitPattern: bytes.loadUnaligned(fromByteOffset: offset + $0 * 4, as: UInt32.self).littleEndian)
                }
            }
            let confidence =
                header.confidenceBytes > 0
                ? Array(raw[(offset + count * 4)..<(offset + count * 4 + header.confidenceBytes)]) : nil
            observation = .init(
                width: header.width, height: header.height, depth: depth, confidence: confidence,
                intrinsics: header.intrinsics, pose: header.pose, timestamp: header.timestamp, frameID: header.frameID,
                epoch: header.epoch)
        }
        let result = evidence.analysis
        let update = predictor.update(result: result, observation: observation, options: evidence.pathOptions,
            cameraView: evidence.capture?.intrinsics.map { RouteCameraView(intrinsics: $0) })
        let row = ReplayRow(
            epoch: result.epoch, frameID: result.frameID, timestamp: result.timestamp, update: update,
            fresh: update.path?.validatedFrameID == result.frameID,
            supportedByCurrentGrid: update.path.flatMap { path in
                RoutePlanningGrid(result: result, options: evidence.pathOptions)?.supports(path.points)
            },
            currentObstacleFree: update.path.map {
                !PathObstacleCheck.intersects($0, result: result, observation: observation)
            },
            confirmedModelFree: update.path.flatMap { path in
                update.confirmedObstacles.map { model in
                    zip(path.points,path.points.dropFirst()).allSatisfy { a,b in
                        !model.contains { $0.overlaps(from:a,to:b,radius:path.requiredWidth/2) }
                    }
                }
            })
        print(String(decoding: try encoder.encode(row), as: UTF8.self))
    }
}
