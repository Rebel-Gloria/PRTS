import Foundation
import SpatialCore
import Testing
#if PRTS_DEV
import AVFoundation
#endif

@testable import PRTS

@Suite(.serialized)
struct RecordingStoreTests {
    private func flush(_ store: RecordingStore) async {
        await withCheckedContinuation { done in store.flush { done.resume() } }
    }

    @Test func disabledStoreNeverCreatesFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecordingStore(root: root, enabled: false)
        store.event("test")
        store.attachment(data: Data([1, 2, 3]), kind: "original", fileExtension: "bin")
        await flush(store)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func buildPolicyCannotBeEnabledInRelease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root, enabled: true)
        store.event("test")
        await flush(store)
        #if PRTS_DEV
        #expect(store.isEnabled)
        #expect(FileManager.default.fileExists(atPath: root.path))
        #else
        #expect(!store.isEnabled)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #endif
    }

    #if PRTS_DEV
    @Test func clearRejectsLateOriginalsAndAutomaticallyResumes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("Recordings")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecordingStore(root: root)
        let oldGeneration = store.admissionGeneration
        store.event("before_clear")
        await flush(store)
        let clearResult: Result<Void, Error> = await withCheckedContinuation { done in
            store.clear { done.resume(returning: $0) }
        }
        try clearResult.get()
        store.attachment(data: Data([4, 5]), kind: "late_original", fileExtension: "bin",
                         generation: oldGeneration)
        store.event("after_clear")
        await flush(store)
        let directories = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(directories.count == 1)
        let events = try String(contentsOf: #require(directories.first).appendingPathComponent("events.jsonl"), encoding: .utf8)
        #expect(events.contains("clear_completed"))
        #expect(events.contains("after_clear"))
        #expect(!events.contains("before_clear"))
        #expect(!events.contains("late_original"))
    }

    @Test func attachmentPreservesEveryByteAndReportsWriteFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        let raw = Data((0..<4096).map { UInt8($0 % 256) })
        store.attachment(data: raw, kind: "synthetic", fileExtension: "bin")
        await flush(store)
        let directory = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let lines = try String(contentsOf: directory.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let objects = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        let reference = try #require(objects.compactMap { $0?["attachment"] as? [String: Any] }.first)
        let file = try #require(reference["file"] as? String)
        let data = try Data(contentsOf: directory.appendingPathComponent(file))
        let decoded = try (data.dropFirst(8) as NSData).decompressed(using: .zlib) as Data
        #expect(decoded == raw)
        store.submit(.events) { throw RecordingError.writeFailed }
        await flush(store)
        #expect(store.status().error != nil)
        #expect(store.status().failed["events"] == 1)
    }

    @Test func videoKeepsNativeDimensionsAndSourceTimestamps() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var pixelBuffer: CVPixelBuffer?
        #expect(CVPixelBufferCreate(nil, 128, 96, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixelBuffer) == kCVReturnSuccess)
        let image = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 80, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        let store = RecordingStore(root: root)
        store.videoFrame(pixelBuffer: image, timestamp: 42, metadata: ["source": "synthetic"])
        await flush(store)
        await withCheckedContinuation { done in store.suspend { done.resume() } }
        let directory = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
        let line = try String(contentsOf: directory.appendingPathComponent("video.jsonl"), encoding: .utf8)
        let record = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let payload = try #require(record["payload"] as? [String: Any])
        #expect(payload["timestamp"] as? Double == 42)
        #expect(payload["pts"] as? Double == 0)
        let asset = AVURLAsset(url: directory.appendingPathComponent(try #require(payload["file"] as? String)))
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 128 && size.height == 96)
        #expect(store.status().error == nil)
    }
    #endif
}
