import Foundation
import SpatialCore
import Testing

@testable import PRTS

#if PRTS_DEV
import AVFoundation
#endif

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

    @Test func nextLaunchRemovesOnlyTemporaryExports() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let exports = base.appendingPathComponent("RecordingExports")
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("original.bin")
        try Data([1, 2]).write(to: original)
        try Data([3, 4]).write(to: exports.appendingPathComponent("previous.zip"))
        try RecordingArchive.removePreviousExports(at: exports)
        #expect(!FileManager.default.fileExists(atPath: exports.path))
        #expect(try Data(contentsOf: original) == Data([1, 2]))
        try RecordingArchive.removePreviousExports(at: exports)
    }

    #if PRTS_DEV
    @Test func clearAttemptsRemainingDirectoriesAfterAnError() throws {
        let files = FileManager.default
        let base = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: base) }
        let parent = base.appendingPathComponent("locked")
        let exports = parent.appendingPathComponent("RecordingExports")
        let recordings = base.appendingPathComponent("Recordings")
        try files.createDirectory(at: exports, withIntermediateDirectories: true)
        try files.createDirectory(at: recordings, withIntermediateDirectories: true)
        try files.setAttributes([.posixPermissions: 0o555], ofItemAtPath: parent.path)
        defer { try? files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }
        #expect(throws: (any Error).self) {
            try RecordingStore.removeRecordingDirectories([exports, recordings])
        }
        #expect(files.fileExists(atPath: exports.path))
        #expect(!files.fileExists(atPath: recordings.path))
    }

    private actor StopBarrier {
        private var entered = false
        private var arrival: CheckedContinuation<Void, Never>?
        private var release: CheckedContinuation<Void, Never>?
        func stop() async {
            await withCheckedContinuation { done in
                entered = true
                release = done
                arrival?.resume()
                arrival = nil
            }
        }
        func waitForStop() async {
            if entered { return }
            await withCheckedContinuation { arrival = $0 }
        }
        func finish() {
            release?.resume()
            release = nil
        }
    }

    @Test func clearBlocksProducersUntilShutdownFinishes() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = RecordingStore(root: base.appendingPathComponent("Recordings"))
        store.event("before_reset")
        await flush(store)
        let previous = store.status().runID
        let barrier = StopBarrier()
        let reset = Task {
            await withCheckedContinuation { done in
                store.clear(afterStopping: { await barrier.stop() }) {
                    done.resume(returning: $0)
                }
            }
        }
        await barrier.waitForStop()
        store.event("late_spatial_result")
        await flush(store)
        #expect(
            FileManager.default.fileExists(atPath: store.root.appendingPathComponent(previous).path)
        )
        await barrier.finish()
        try await reset.value.get()
        store.event("new_runtime")
        await flush(store)
        let directory = store.root.appendingPathComponent(store.status().runID)
        let events = try String(
            contentsOf: directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(!events.contains("before_reset"))
        #expect(!events.contains("late_spatial_result"))
        #expect(events.contains("new_runtime"))
    }

    @Test func exportSealsOneSnapshotAndKeepsRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        store.noteGap("video")
        store.event("before_export")
        await flush(store)
        let firstID = store.status().runID
        let result: Result<URL, Error> = await withCheckedContinuation { done in
            store.export { done.resume(returning: $0) }
        }
        let archive = try result.get()
        defer { try? FileManager.default.removeItem(at: archive) }
        #expect(try Data(contentsOf: archive).prefix(2) == Data([0x50, 0x4b]))
        store.event("after_export")
        await flush(store)
        #expect(store.status().runID != firstID)
        let data = try Data(
            contentsOf: root.appendingPathComponent(firstID).appendingPathComponent("manifest.json")
        )
        let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(manifest["finalized"] as? Bool == true)
        #expect(manifest["complete"] as? Bool == false)
        #expect(manifest["segmentDropped"] as? [String: Int] == ["video": 1])
        let status = try #require(manifest["status"] as? [String: Any])
        #expect(status["runID"] as? String == firstID)
        #expect(manifest["recordCounts"] as? [String: Int] == ["events": 3])
        #expect(manifest["lastSequence"] as? Int == 3)
        await withCheckedContinuation { done in store.suspend { done.resume() } }
        let secondData = try Data(
            contentsOf: root.appendingPathComponent(store.status().runID).appendingPathComponent(
                "manifest.json"
            )
        )
        let second = try #require(JSONSerialization.jsonObject(with: secondData) as? [String: Any])
        #expect(second["recordCounts"] as? [String: Int] == ["events": 2])
        #expect(second["lastSequence"] as? Int == 2)
        #expect(second["complete"] as? Bool == true)
        #expect(second["segmentDropped"] as? [String: Int] == [:])
        #expect(store.status().dropped["video"] == 1)
    }

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
        store.attachment(
            data: Data([4, 5]),
            kind: "late_original",
            fileExtension: "bin",
            generation: oldGeneration
        )
        store.event("after_clear")
        await flush(store)
        let directories = try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        #expect(directories.count == 1)
        let events = try String(
            contentsOf: #require(directories.first).appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
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
        let directory = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let lines = try String(
            contentsOf: directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        .split(separator: "\n")
        let objects = try lines.map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
        let references = objects.compactMap { $0?["attachment"] as? [String: Any] }
        let reference = try #require(references.first)
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
        #expect(
            CVPixelBufferCreate(
                nil,
                128,
                96,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixelBuffer
            ) == kCVReturnSuccess
        )
        let image = try #require(pixelBuffer)
        CVPixelBufferLockBaseAddress(image, [])
        memset(CVPixelBufferGetBaseAddress(image), 80, CVPixelBufferGetDataSize(image))
        CVPixelBufferUnlockBaseAddress(image, [])
        let store = RecordingStore(root: root)
        store.videoFrame(pixelBuffer: image, timestamp: 42, metadata: ["source": "synthetic"])
        await flush(store)
        await withCheckedContinuation { done in store.suspend { done.resume() } }
        let directory = try #require(
            FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first
        )
        let line = try String(
            contentsOf: directory.appendingPathComponent("video.jsonl"),
            encoding: .utf8
        )
        let record = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        let payload = try #require(record["payload"] as? [String: Any])
        #expect(payload["timestamp"] as? Double == 42)
        #expect(payload["pts"] as? Double == 0)
        let asset = AVURLAsset(
            url: directory.appendingPathComponent(try #require(payload["file"] as? String))
        )
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        #expect(size.width == 128 && size.height == 96)
        #expect(store.status().error == nil)
    }
    #endif
}
