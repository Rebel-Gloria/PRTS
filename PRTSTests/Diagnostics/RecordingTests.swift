#if PRTS_DEV_CAPTURE
import CoreVideo
import Foundation
import SpatialCore
import Testing
@testable import PRTS

/// Synthetic pixels and an injected encoder exercise storage without camera or Metal inference.
@Suite(.serialized)
struct RecordingTests {
    private func recorder(
        _ root: URL,
        encoder: @escaping RecordingRecorder.ImageEncoder = { _, url in
            try Data("synthetic HEIC stand-in".utf8).write(to: url)
        },
        availableBytes: @escaping @Sendable (URL) throws -> Int = { _ in Int.max }
    ) -> RecordingRecorder {
        RecordingRecorder(
            diagnostics: DiagnosticRecorder(
                journal: DiagnosticJournal(
                    root: root.appendingPathComponent("Automatic"),
                    metadata: [:],
                    enabled: false
                )
            ),
            store: RecordingStore(root: root),
            encodeImage: encoder,
            availableBytes: availableBytes
        )
    }

    // Starting a recording forces the journal to sync to disk first; on a loaded simulator host
    // that has taken more than 10 s (1 of 270 runs), so allow 30 s.
    private func waitIdle(_ recorder: RecordingRecorder) async throws {
        for _ in 0..<3000 {
            if !recorder.status().busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Encoder did not drain")
    }

    private func stop(_ recorder: RecordingRecorder, reason: String = "test") async {
        await withCheckedContinuation { done in recorder.stop(reason: reason) { done.resume() } }
    }

    private func working(_ root: URL) throws -> URL {
        try #require(
            FileManager.default.contentsOfDirectory(
                at: RecordingStore(root: root).working,
                includingPropertiesForKeys: nil
            ).first
        )
    }
    private func packet(_ id: UInt64, _ time: Double) throws -> RecordingRecorder.Packet {
        var pixel: CVPixelBuffer?
        #expect(
            CVPixelBufferCreate(
                nil,
                64,
                48,
                kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                &pixel
            ) == kCVReturnSuccess
        )
        let image = try #require(pixel)
        CVPixelBufferLockBaseAddress(image, [])
        if let base = CVPixelBufferGetBaseAddress(image) {
            memset(base, 100, CVPixelBufferGetBytesPerRow(image) * 48)
        }
        CVPixelBufferUnlockBaseAddress(image, [])
        let result = AnalysisResult(
            epoch: 1,
            frameID: id,
            timestamp: time,
            parameters: .init(),
            status: "synthetic",
            source: "synthetic_test"
        )
        var packet = RecordingRecorder.Packet(
            image: image,
            timestamp: time,
            epoch: 1,
            capture: nil,
            result: result,
            path: .init(reason: "synthetic"),
            source: "synthetic_test"
        )
        packet.observation = DepthObservation(
            width: 2,
            height: 2,
            depth: [1, .nan, .infinity, 2],
            confidence: [2, 0, 0, 1],
            intrinsics: .init(fx: 2, fy: 2, cx: 1, cy: 1, width: 2, height: 2),
            pose: .init(),
            timestamp: time,
            frameID: id,
            epoch: 1
        )
        return packet
    }
    @Test func modeIsOffAndDisabledStartWritesNothing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let capture = recorder(root)
        #expect(!capture.status().mode)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        await stop(capture)
        #expect(capture.status().phase == .idle)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func pairedEvidenceAndImagesKeepSensorIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = recorder(root)
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        let timestamp = ProcessInfo.processInfo.systemUptime
        capture.submit(try packet(1, timestamp))
        try await waitIdle(capture)
        // A duplicate or non-finite source timestamp must never create another sample.
        capture.submit(try packet(1, timestamp))
        capture.submit(try packet(2, .infinity))
        capture.submit(try packet(2, .nan))
        #expect(capture.status().saved == 1)
        let folder = try working(root)
        let line = try String(
            contentsOf: folder.appendingPathComponent("samples.jsonl"),
            encoding: .utf8
        )
        let row = try #require(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        #expect(row["epoch"] as? Int == 1)
        #expect(row["frameID"] as? Int == 1)
        #expect(row["timestamp"] as? Double == timestamp)
        let image = try #require(row["image"] as? [String: Any])
        #expect(image["file"] as? String == "1-1.heic")
        #expect(image["width"] as? Int == 64)
        #expect(image["height"] as? Int == 48)
        let depth = try #require(row["depth"] as? [String: Any])
        let file = try #require(depth["file"] as? String)
        let raw =
            try (Data(contentsOf: folder.appendingPathComponent(file)) as NSData)
            .decompressed(using: .zlib) as Data
        let n = Int(raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian })
        let values = (0..<4).map { i in
            Float(
                bitPattern: raw.withUnsafeBytes {
                    $0.loadUnaligned(fromByteOffset: 4 + n + i * 4, as: UInt32.self).littleEndian
                }
            )
        }
        #expect(values[0] == 1 && values[1].isNaN && values[2].isInfinite && values[3] == 2)
        await stop(capture)
        #expect(capture.status().phase == .saved)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let saved = try #require(RecordingStore(root: root).list().first)
        #expect(saved.url.deletingLastPathComponent().lastPathComponent == "Recordings")
        #expect(try Data(contentsOf: saved.url).prefix(2) == Data([0x50, 0x4b]))
    }

    @Test func boundedEncoderDrainsBeforeZipAndRejectsLateSamples() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let capture = recorder(
            root,
            encoder: { _, url in
                Task { await entered.signal() }
                release.wait()
                try Data("synthetic".utf8).write(to: url)
            }
        )
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        await entered.wait()
        capture.submit(try packet(2, ProcessInfo.processInfo.systemUptime))
        #expect(capture.status().dropped == 1)
        capture.setMode(false)
        #expect(capture.status().phase == .compressing)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(3, ProcessInfo.processInfo.systemUptime))
        release.signal()
        await stop(capture)
        #expect(capture.status().saved == 1)
        #expect(capture.status().phase == .saved)
        capture.submit(try packet(4, ProcessInfo.processInfo.systemUptime))
        #expect(capture.status().saved == 1)
        #expect(!capture.status().mode)
    }

    @Test func oldCompletionCannotReplaceANewRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = TestSignal()
        let oldFinished = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let capture = recorder(
            root,
            encoder: { _, url in
                if url.lastPathComponent == "1-1.heic" {
                    Task { await entered.signal() }
                    release.wait()
                }
                try Data("synthetic".utf8).write(to: url)
            }
        )
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        await entered.wait()
        capture.stop(reason: "first") { Task { await oldFinished.signal() } }
        capture.start(epoch: 1, meshes: [])
        #expect(capture.status().phase == .recording)
        capture.submit(try packet(2, ProcessInfo.processInfo.systemUptime))
        #expect(capture.status().dropped == 1)
        release.signal()
        await oldFinished.wait()
        await withCheckedContinuation { done in
            capture.finishPendingArchives { done.resume() }
        }
        #expect(capture.status().phase == .recording)
        #expect(capture.status().saved == 0)
        #expect(capture.status().archiveRevision == 1)
        capture.submit(try packet(3, ProcessInfo.processInfo.systemUptime))
        try await waitIdle(capture)
        await stop(capture)
        #expect(capture.status().saved == 1)
        #expect(try RecordingStore(root: root).list().count == 2)
    }

    @Test func repeatedStartDoesNotResetAndNextRunHasFreshCounters() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = recorder(root)
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        try await waitIdle(capture)
        capture.start(epoch: 1, meshes: [])
        #expect(capture.status().saved == 1)
        await stop(capture)
        capture.start(epoch: 1, meshes: [])
        #expect(capture.status().phase == .recording)
        #expect(capture.status().saved == 0)
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        try await waitIdle(capture)
        await stop(capture)
        #expect(capture.status().saved == 1)
        #expect(try RecordingStore(root: root).list().count == 2)
    }

    @Test func lowDiskStopsAndDisarmsWithReason() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = recorder(root, availableBytes: { _ in 256 * 1024 * 1024 - 1 })
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        capture.submit(try packet(1, ProcessInfo.processInfo.systemUptime))
        try await waitIdle(capture)
        await stop(capture)
        #expect(!capture.status().mode)
        #expect(capture.status().phase == .failed)
        #expect(capture.status().text == "可用空间低于256 MiB")
        #expect(capture.status().saved == 0)
    }

    @Test func uncalibratedRelativeDepthStaysLossless() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = recorder(root)
        capture.setMode(true)
        capture.start(epoch: 1, meshes: [])
        var input = try packet(1, ProcessInfo.processInfo.systemUptime)
        input.observation = nil
        input.relative = [1, Float(bitPattern: 0x7fc00001), .infinity, 0]
        input.model = .init(
            width: 2,
            height: 2,
            calibration: nil,
            provisionalFit: nil,
            scaleDecision: .init(),
            scaleSamples: [],
            groundReference: .init(mode: "invalid", reason: "synthetic"),
            timings: [:],
            status: "uncalibrated"
        )
        capture.submit(input)
        try await waitIdle(capture)
        let folder = try working(root)
        let raw =
            try
            (Data(contentsOf: folder.appendingPathComponent("1-1.relative.f32.deflate"))
            as NSData).decompressed(using: .zlib) as Data
        #expect(raw.count == 16)
        #expect(
            raw.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
            } == 0x7fc00001
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: folder.appendingPathComponent("1-1.depth.bin.deflate").path
            )
        )
        await stop(capture)
    }

    @Test func initialMeshAndDiagnosticBoundaryAreIndependentOfAutomaticRun() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let automatic = DiagnosticJournal(
            root: root.appendingPathComponent("Automatic"),
            metadata: [:]
        )
        let diagnostics = DiagnosticRecorder(journal: automatic)
        let capture = RecordingRecorder(diagnostics: diagnostics, store: RecordingStore(root: root))
        diagnostics.event("before", details: "test", epoch: 1)
        capture.setMode(true)
        capture.start(
            epoch: 1,
            meshes: [
                MeshSnapshot(
                    id: "existing",
                    epoch: 1,
                    revision: 7,
                    callbackTime: 1,
                    transform: .init(),
                    vertices: [.zero, V3(1, 0, 0), V3(0, 0, 1)],
                    indices: [0, 1, 2],
                    classifications: [2],
                    floorPriors: []
                )
            ]
        )
        diagnostics.event("inside", details: "test", epoch: 1)
        // Detaching exercises the same admission boundary as stop and leaves the journal inspectable.
        let journal = try #require(diagnostics.recordingJournal.detach())
        diagnostics.event("after", details: "test", epoch: 1)
        await withCheckedContinuation { done in journal.flush { done.resume() } }
        let events = try String(
            contentsOf: journal.directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(events.contains("inside"))
        #expect(!events.contains("before"))
        #expect(!events.contains("after"))
        let mesh = try String(
            contentsOf: journal.directory.appendingPathComponent("mesh.jsonl"),
            encoding: .utf8
        )
        #expect(mesh.contains("existing"))
        #expect(mesh.contains("attachment"))
        #expect(journal.status().droppedTotal == 0)
        await stop(capture)
        await withCheckedContinuation { done in automatic.flush { done.resume() } }
        let autoEvents = try String(
            contentsOf: automatic.directory.appendingPathComponent("events.jsonl"),
            encoding: .utf8
        )
        #expect(
            autoEvents.contains("before") && autoEvents.contains("inside")
                && autoEvents.contains("after")
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: automatic.directory.appendingPathComponent("samples.jsonl").path
            )
        )
    }

    @Test func listNewestFirstAndDelete() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecordingStore(root: root)
        #expect(try store.list().isEmpty)
        for time in [100.0, 200.0] {
            let directory = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try Data("{}".utf8).write(to: directory.appendingPathComponent("manifest.json"))
            _ = try await Task.detached {
                try store.pack(
                    directory: directory,
                    startedAt: Date(timeIntervalSince1970: time),
                    duration: 2
                )
            }.value
            #expect(!FileManager.default.fileExists(atPath: directory.path))
        }
        let recordings = try store.list()
        #expect(recordings.map(\.startedAt.timeIntervalSince1970) == [200, 100])
        #expect(recordings.allSatisfy { $0.duration == 2 && $0.bytes > 0 })
        try store.delete(recordings[0])
        #expect(try store.list().count == 1)
    }
}
#endif
