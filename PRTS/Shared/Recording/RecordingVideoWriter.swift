#if PRTS_DEV
import AVFoundation
import Foundation

/// Owned by RecordingStore's disk queue. Source timestamps and dimensions are never resampled.
nonisolated final class RecordingVideoWriter: @unchecked Sendable {
    let file: String
    let width: Int
    let height: Int
    let origin: Double
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastTimestamp: Double = -.infinity

    init(directory: URL, image: CVPixelBuffer, timestamp: Double) throws {
        file = "rgb-\(UUID().uuidString).mp4"
        width = CVPixelBufferGetWidth(image)
        height = CVPixelBufferGetHeight(image)
        origin = timestamp
        writer = try AVAssetWriter(outputURL: directory.appendingPathComponent(file), fileType: .mp4)
        writer.movieFragmentInterval = CMTime(seconds: 1, preferredTimescale: 60_000)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 1_000_000,
                AVVideoMaxKeyFrameIntervalDurationKey: 1,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: CVPixelBufferGetPixelFormatType(image),
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw RecordingError.video("unsupported native format") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecordingError.video("startWriting")
        }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CVPixelBuffer, timestamp: Double) throws -> Bool {
        guard timestamp.isFinite, timestamp > lastTimestamp else { return false }
        guard writer.status == .writing else {
            throw writer.error ?? RecordingError.video("writer is not writing")
        }
        guard input.isReadyForMoreMediaData else { return false }
        let time = CMTime(seconds: timestamp - origin, preferredTimescale: 60_000)
        guard adaptor.append(image, withPresentationTime: time) else {
            throw writer.error ?? RecordingError.video("append")
        }
        lastTimestamp = timestamp
        return true
    }

    func finish(completion: @escaping @Sendable (String?) -> Void) {
        guard writer.status == .writing else {
            completion(writer.error?.localizedDescription ?? "writer did not finish")
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            completion(writer.status == .completed ? nil : (writer.error?.localizedDescription ?? "finishWriting"))
        }
    }
}
#endif
