#if PRTS_DEV
import AVFoundation
import CoreImage
import Foundation
import SpatialCore

/// Copies original interaction images before any model-specific resizing. Encoding stays off
/// the capture and UI queues, with a bounded number of retained camera buffers.
nonisolated enum DevInteractionRecording {
    @TaskLocal static var interactionID: String?
    @TaskLocal static var recordingGeneration: UInt64?
    private static let queue = DispatchQueue(label: "PRTS.recording.images", qos: .utility)
    private static let admission = NSLock()
    private nonisolated(unsafe) static var pendingImages = 0
    private nonisolated(unsafe) static var suppressionGeneration: UInt64?
    private nonisolated(unsafe) static var suppressedInteractions: Set<String> = []

    static func noteSuppressedAfterClear(feature: String, id: String, generation: UInt64) {
        let current = RecordingStore.shared.admissionGeneration
        guard generation != current else { return }
        let shouldRecord = admission.withLock {
            if suppressionGeneration != current {
                suppressionGeneration = current
                suppressedInteractions.removeAll()
            }
            guard suppressedInteractions.count < 128 else { return false }
            return suppressedInteractions.insert(feature + ":" + id).inserted
        }
        if shouldRecord {
            RecordingStore.shared.event(
                "active_interaction_recording_suppressed_after_clear",
                details: ["feature": feature],
                generation: current
            )
        }
    }

    static func original(
        pixelBuffer: CVPixelBuffer,
        orientation: ImageOrientation,
        feature: String,
        metadata: [String: String] = [:]
    ) {
        original(
            image: PhotoImageEncoder.image(pixelBuffer: pixelBuffer, orientation: orientation),
            feature: feature,
            metadata: metadata
        )
    }

    static func original(
        image: CIImage,
        feature: String,
        metadata: [String: String] = [:]
    ) {
        let generation = recordingGeneration ?? RecordingStore.shared.admissionGeneration
        guard generation == RecordingStore.shared.admissionGeneration else { return }
        let accepted = admission.withLock {
            guard pendingImages < 4 else { return false }
            pendingImages += 1
            return true
        }
        guard accepted else {
            RecordingStore.shared.noteGap("original_image", generation: generation)
            RecordingStore.shared.event(
                "original_image_dropped",
                details: ["feature": feature],
                generation: generation
            )
            return
        }
        var details = metadata
        details["feature"] = feature
        details["interactionID"] = interactionID ?? "unavailable"
        details["width"] = String(Int(image.extent.width))
        details["height"] = String(Int(image.extent.height))
        details["capturedUptime"] = String(ProcessInfo.processInfo.systemUptime)
        let recordedDetails = details
        queue.async {
            defer { admission.withLock { pendingImages -= 1 } }
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                let data = PhotoImageEncoder.context.pngRepresentation(
                    of: image,
                    format: .RGBA8,
                    colorSpace: colorSpace
                )
            else {
                RecordingStore.shared.noteGap("original_image", generation: generation)
                RecordingStore.shared.event(
                    "original_image_failed", details: recordedDetails, generation: generation
                )
                return
            }
            RecordingStore.shared.attachment(
                data: data,
                kind: "original_image",
                fileExtension: "png",
                metadata: recordedDetails,
                generation: generation
            )
        }
    }

    /// Drains original image encodes and partial microphone batches before a store snapshot.
    static func flush(completion: @escaping @Sendable () -> Void) {
        queue.async { DevAudioRecording.flushAll(completion: completion) }
    }

    static func failure(
        _ error: Error, feature: String, id: String, generation: UInt64? = nil
    ) {
        let value = error as NSError
        RecordingStore.shared.event(
            error is CancellationError ? "interaction_cancelled" : "interaction_failed",
            details: [
                "feature": feature, "interactionID": id,
                "domain": value.domain, "code": String(value.code),
            ],
            generation: generation ?? recordingGeneration
        )
    }
}

/// Native microphone buffers are copied before the audio tap returns. Batches keep each
/// buffer's format, timing and byte layout, so replay need not resample or quantize audio.
nonisolated final class DevAudioRecording: @unchecked Sendable {
    private final class WeakRecording: @unchecked Sendable {
        weak var value: DevAudioRecording?
        init(_ value: DevAudioRecording) { self.value = value }
    }
    private static let registryLock = NSLock()
    private nonisolated(unsafe) static var registry: [WeakRecording] = []
    private let id: String
    private let interactionID: String
    private var generation: UInt64  // microphone queue only after initialization
    private let queue = DispatchQueue(label: "PRTS.recording.microphone", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    private var batches = Data()
    private var frames: UInt32 = 0
    private var sequence = 0

    init(id: String) {
        self.id = id
        interactionID = DevInteractionRecording.interactionID ?? "unavailable"
        generation = RecordingStore.shared.admissionGeneration
        Self.registryLock.withLock {
            Self.registry.removeAll { $0.value == nil }
            Self.registry.append(WeakRecording(self))
        }
        RecordingStore.shared.event(
            "microphone_recording_started",
            details: ["utteranceID": id, "interactionID": interactionID],
            generation: generation
        )
    }

    static func flushAll(completion: @escaping @Sendable () -> Void) {
        let recorders = registryLock.withLock { registry.compactMap(\.value) }
        let group = DispatchGroup()
        for recorder in recorders {
            group.enter()
            recorder.queue.async {
                recorder.flush()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }

    func append(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        let admittedGeneration = RecordingStore.shared.admissionGeneration
        let accepted = admission.withLock {
            guard pending < 16 else { return false }
            pending += 1
            return true
        }
        guard accepted else {
            RecordingStore.shared.noteGap("microphone_audio", generation: admittedGeneration)
            RecordingStore.shared.event(
                "microphone_buffer_dropped",
                details: ["utteranceID": id],
                generation: admittedGeneration
            )
            return
        }
        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        var payload = Data()
        var sizes: [Int] = []
        for source in buffers {
            sizes.append(Int(source.mDataByteSize))
            if let bytes = source.mData {
                payload.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(source.mDataByteSize))
            } else if source.mDataByteSize > 0 {
                admission.withLock { pending -= 1 }
                RecordingStore.shared.noteGap("microphone_audio", generation: admittedGeneration)
                return
            }
        }
        let description = buffer.format.streamDescription.pointee
        let header: [String: Any] = [
            "sampleRate": description.mSampleRate,
            "formatID": description.mFormatID,
            "formatFlags": description.mFormatFlags,
            "bytesPerFrame": description.mBytesPerFrame,
            "bitsPerChannel": description.mBitsPerChannel,
            "channels": description.mChannelsPerFrame,
            "frameLength": buffer.frameLength,
            "bufferByteCounts": sizes,
            "hostTime": time.hostTime,
            "sampleTime": time.sampleTime,
            "hostTimeValid": time.isHostTimeValid,
            "sampleTimeValid": time.isSampleTimeValid,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])
        else {
            admission.withLock { pending -= 1 }
            RecordingStore.shared.noteGap("microphone_audio", generation: admittedGeneration)
            return
        }
        var length = UInt32(json.count).littleEndian
        var packet = withUnsafeBytes(of: &length) { Data($0) }
        packet.append(json)
        packet.append(payload)
        let bytes = packet
        let frameCount = buffer.frameLength
        let rate = buffer.format.sampleRate
        queue.async {
            defer { self.admission.withLock { self.pending -= 1 } }
            if self.generation != admittedGeneration {
                // Old partial batches retain their admission generation and are rejected by
                // the store after deletion. The live utterance continues in the new run.
                self.flush()
                self.generation = admittedGeneration
                RecordingStore.shared.event(
                    "microphone_recording_continued_after_clear",
                    details: ["utteranceID": self.id],
                    generation: admittedGeneration
                )
            }
            self.batches.append(bytes)
            self.frames += frameCount
            if Double(self.frames) >= rate { self.flush() }
        }
    }

    func finish() {
        queue.async {
            self.flush()
            RecordingStore.shared.event(
                "microphone_recording_stopped",
                details: ["utteranceID": self.id],
                generation: self.generation
            )
        }
    }

    private func flush() {
        guard !batches.isEmpty else { return }
        RecordingStore.shared.attachment(
            data: batches,
            kind: "microphone_audio",
            fileExtension: "pcma",
            metadata: [
                "utteranceID": id, "sequence": String(sequence),
                "interactionID": interactionID,
                "encoding": "native_pcm_v1_uint32le_json_length_then_header_then_buffers",
            ],
            generation: generation
        )
        sequence += 1
        batches.removeAll(keepingCapacity: true)
        frames = 0
    }
}
#endif
