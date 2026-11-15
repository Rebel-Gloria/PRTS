import CryptoKit
import Foundation
import SpatialCore
#if PRTS_DEV
import AVFoundation
#endif

/// One recording owner for spatial inputs, interactions and media. Release never opens this store.
nonisolated final class RecordingStore: @unchecked Sendable {
    static let shared = RecordingStore()
    static var compiledIn: Bool {
        #if PRTS_DEV
        true
        #else
        false
        #endif
    }
    let isEnabled: Bool
    let root: URL
    private let queue = DispatchQueue(label: "prts.recording.disk", qos: .utility)
    private let exportQueue = DispatchQueue(label: "prts.recording.export", qos: .utility)
    private let lock = NSLock()
    private var state = DiagnosticStatus()
    private var generation: UInt64 = 0
    private var boundaryUptime: Double = 0
    private var clearing = false
    private var maintenance = false
    private var videoPending = 0
    // The following state belongs to queue. Sealed directories are immutable during export.
    private var directory: URL?
    private var handles: [String: FileHandle] = [:]
    private var sequence: UInt64 = 0
    private var segment = 0
    private var segmentBytes = 0
    private var openedAt = Date()
    private let launchID = UUID().uuidString
    private var lastCheckpoint: Double = 0
    private var lastCapacityCheck: Double = 0
    #if PRTS_DEV
    private var video: RecordingVideoWriter?
    private var videoSource: String?
    private let finalizations = DispatchGroup()
    private var videoFailures: [URL: String] = [:]
    #endif

    init(root: URL? = nil, enabled: Bool = RecordingStore.compiledIn) {
        self.root = root ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        isEnabled = enabled && Self.compiledIn
        if isEnabled { event("recording_started", details: ["reason": "app_launch"]) }
    }

    func status() -> DiagnosticStatus { lock.withLock { state } }
    var admissionGeneration: UInt64 { lock.withLock { generation } }
    var recordingBoundaryUptime: Double { lock.withLock { boundaryUptime } }

    private func admit(_ kind: String, bytes: Int, videoFrame: Bool = false) -> UInt64? {
        guard isEnabled else { return nil }
        return lock.withLock {
            state.attempted[kind, default: 0] += 1
            guard !clearing, state.error == nil, state.pending < 128,
                state.pendingBytes + bytes <= 64 * 1024 * 1024,
                !videoFrame || videoPending < 3
            else {
                state.dropped[kind, default: 0] += 1
                return nil
            }
            state.pending += 1
            state.pendingBytes += bytes
            if videoFrame { videoPending += 1 }
            return generation
        }
    }

    private func complete(_ bytes: Int, videoFrame: Bool = false) {
        lock.withLock {
            state.pending -= 1
            state.pendingBytes -= bytes
            if videoFrame { videoPending -= 1 }
        }
    }

    private func valid(_ token: UInt64) -> Bool {
        lock.withLock { token == generation && !clearing && state.error == nil }
    }

    private func fail(_ error: Error, kind: String) {
        lock.withLock {
            state.error = error.localizedDescription
            state.failed[kind, default: 0] += 1
        }
        // Never recursively send recording failures to a logger that records to this store.
        try? checkpoint()
    }

    func event(_ name: String, details: [String: String] = [:], generation: UInt64? = nil) {
        nonisolated struct Event: Encodable, Sendable {
            let name: String
            let details: [String: String]
            let uptime: Double
            let wallTime: String
        }
        let value = Event(
            name: name, details: details,
            uptime: ProcessInfo.processInfo.systemUptime,
            wallTime: ISO8601DateFormatter().string(from: Date())
        )
        let cost = details.reduce(name.utf8.count + 4096) { $0 + $1.key.utf8.count + $1.value.utf8.count }
        submit(.events, estimatedBytes: cost, generation: generation) { .init(json: try DiagnosticJSON.encode(value)) }
    }

    func noteGap(_ kind: String, generation expected: UInt64? = nil) {
        guard isEnabled else { return }
        lock.withLock {
            guard expected == nil || expected == generation else { return }
            state.dropped[kind, default: 0] += 1
        }
    }

    func submit(
        _ stream: DiagnosticStream,
        estimatedBytes: Int = 4096,
        generation expectedGeneration: UInt64? = nil,
        make: @escaping @Sendable () throws -> DiagnosticPacket
    ) {
        let cost = max(estimatedBytes, 4096)
        guard let token = admit(stream.rawValue, bytes: cost) else { return }
        let received = ProcessInfo.processInfo.systemUptime
        let wallTime = Date().timeIntervalSince1970
        queue.async { [self] in
            defer { complete(cost) }
            guard valid(token), expectedGeneration == nil || expectedGeneration == token else { return }
            do {
                try prepare()
                try write(try make(), stream: stream.rawValue, received: received, wallTime: wallTime)
            } catch { fail(error, kind: stream.rawValue) }
        }
    }

    /// Non-video originals and exact model payloads are losslessly compressed, never resized.
    func attachment(
        data: Data, kind: String, fileExtension: String,
        metadata: [String: String] = [:], generation expectedGeneration: UInt64? = nil
    ) {
        nonisolated struct Header: Encodable, Sendable {
            let kind: String, fileExtension: String, metadata: [String: String]
        }
        let header = Header(kind: kind, fileExtension: fileExtension, metadata: metadata)
        submit(.events, estimatedBytes: data.count + 4096, generation: expectedGeneration) {
            .init(json: try DiagnosticJSON.encode(header), binary: data)
        }
    }

    #if PRTS_DEV
    private final class Image: @unchecked Sendable {
        let buffer: CVPixelBuffer
        init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
    }

    func videoFrame(
        pixelBuffer: CVPixelBuffer, timestamp: Double, metadata: [String: String] = [:]
    ) {
        let cost = CVPixelBufferGetDataSize(pixelBuffer) + 4096
        guard timestamp.isFinite, let token = admit("video", bytes: cost, videoFrame: true) else {
            return
        }
        let image = Image(pixelBuffer)
        queue.async { [self] in
            defer { complete(cost, videoFrame: true) }
            guard valid(token) else { return }
            do {
                try prepare()
                if let video, timestamp - video.origin >= 30 || timestamp < video.origin
                    || video.width != CVPixelBufferGetWidth(image.buffer)
                    || video.height != CVPixelBufferGetHeight(image.buffer)
                    || videoSource != metadata["source"]
                {
                    finishVideo(video)
                    self.video = nil
                }
                if video == nil, let directory {
                    video = try RecordingVideoWriter(directory: directory, image: image.buffer, timestamp: timestamp)
                    videoSource = metadata["source"]
                }
                guard let video else { throw RecordingError.writeFailed }
                guard try video.append(image.buffer, timestamp: timestamp) else {
                    lock.withLock { state.dropped["video", default: 0] += 1 }
                    return
                }
                let value: [String: Any] = [
                    "kind": "video_frame", "file": video.file, "timestamp": timestamp,
                    "pts": timestamp - video.origin, "width": video.width, "height": video.height,
                    "metadata": metadata,
                ]
                try write(.init(json: JSONSerialization.data(withJSONObject: value)),
                          stream: "video", received: ProcessInfo.processInfo.systemUptime,
                          wallTime: Date().timeIntervalSince1970)
            } catch { fail(error, kind: "video") }
        }
    }

    private func finishVideo(_ writer: RecordingVideoWriter) {
        let destination = directory
        finalizations.enter()
        writer.finish { [self] error in
            queue.async { [self] in
                if let error {
                    if let destination { videoFailures[destination] = error }
                    fail(RecordingError.video(error), kind: "video_finalize")
                }
                finalizations.leave()
            }
        }
    }

    func endVideoSegment(source: String) {
        queue.async { [self] in
            guard videoSource == source, let video else { return }
            finishVideo(video)
            self.video = nil
            videoSource = nil
        }
        event("video_source_stopped", details: ["source": source])
    }
    #endif

    private func prepare() throws {
        let files = FileManager.default
        if directory == nil {
            let id = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                + "-" + UUID().uuidString
            let next = root.appendingPathComponent(id, isDirectory: true)
            try files.createDirectory(at: next, withIntermediateDirectories: true)
            var excluded = root
            var resources = URLResourceValues()
            resources.isExcludedFromBackup = true
            try excluded.setResourceValues(resources)
            directory = next
            openedAt = Date()
            sequence = 0
            segment = 0
            segmentBytes = 0
            lock.withLock { state.runID = id }
            try checkpoint()
        }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastCapacityCheck >= 1 {
            lastCapacityCheck = now
            let capacity = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage
            if let capacity, capacity < 256 * 1024 * 1024 {
                throw RecordingError.insufficientSpace
            }
        }
    }

    private func handle(_ name: String) throws -> FileHandle {
        if let handle = handles[name] { return handle }
        guard let directory else { throw RecordingError.noData }
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecordingError.writeFailed
        }
        let handle = try FileHandle(forWritingTo: url)
        handles[name] = handle
        return handle
    }

    private func write(
        _ packet: DiagnosticPacket, stream: String, received: Double, wallTime: Double
    ) throws {
        var object: [String: Any] = ["payload": try JSONSerialization.jsonObject(with: packet.json)]
        sequence &+= 1
        object["sequence"] = sequence
        object["recordedUptime"] = received
        object["writtenUptime"] = ProcessInfo.processInfo.systemUptime
        object["recordedWallTime"] = wallTime
        if let binary = packet.binary {
            let compressed = try (binary as NSData).compressed(using: .zlib) as Data
            if segmentBytes > 0, segmentBytes + compressed.count + 8 > 32 * 1024 * 1024 {
                segment += 1
                segmentBytes = 0
            }
            let name = String(format: "data-%05d.bin", segment)
            let output = try handle(name)
            let offset = try output.offset()
            var compressedLength = UInt32(compressed.count).littleEndian
            var rawLength = UInt32(binary.count).littleEndian
            var header = withUnsafeBytes(of: &compressedLength) { Data($0) }
            withUnsafeBytes(of: &rawLength) { header.append(contentsOf: $0) }
            try output.write(contentsOf: header)
            try output.write(contentsOf: compressed)
            segmentBytes += header.count + compressed.count
            object["attachment"] = [
                "file": name, "offset": offset, "codec": "deflate-raw",
                "compressedBytes": compressed.count, "uncompressedBytes": binary.count,
                "sha256": SHA256.hash(data: binary).map { String(format: "%02x", $0) }.joined(),
            ]
            lock.withLock { state.bytesWritten += header.count + compressed.count }
        }
        var line = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        line.append(10)
        try handle(stream + ".jsonl").write(contentsOf: line)
        lock.withLock {
            state.bytesWritten += line.count
            state.written[stream, default: 0] += 1
        }
        if ProcessInfo.processInfo.systemUptime - lastCheckpoint >= 2 { try checkpoint() }
    }

    private func checkpoint(
        at target: URL? = nil, endTime: Date? = nil,
        startTime: Date? = nil, segmentStatus: DiagnosticStatus? = nil
    ) throws {
        guard let destination = target ?? directory else { return }
        let status = segmentStatus ?? status()
        let manifest: [String: Any] = [
            "schemaVersion": 2, "format": "prts-recording", "launchID": launchID,
            "buildConfiguration": "Dev", "createdAt": (startTime ?? openedAt).timeIntervalSince1970,
            "updatedAt": Date().timeIntervalSince1970,
            "endedAt": endTime.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "finalized": endTime != nil,
            "complete": endTime != nil && status.error == nil && status.droppedTotal == 0,
            "status": try JSONSerialization.jsonObject(with: DiagnosticJSON.encode(status)),
            "video": ["codec": "h264", "targetBitsPerSecond": 1_000_000,
                      "resolution": "native", "timing": "source monotonic timestamps"],
            "coordinateConvention": "ARKit gravity world; meters; camera forward -Z",
            "replayBoundary": "Application sensor inputs and outputs; not private ARKit SLAM internals. RGB is lossy. Gaps and unfinished tails must be reported.",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "commit": Bundle.main.object(forInfoDictionaryKey: "PRTSCommit") as? String ?? "unavailable",
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: destination.appendingPathComponent("manifest.json"), options: .atomic)
        if target == nil { lastCheckpoint = ProcessInfo.processInfo.systemUptime }
    }

    func noteLifecycle(_ name: String) {
        lock.withLock { state.lastLifecycle = name }
        event("lifecycle", details: ["phase": name])
    }

    func requestCheckpoint() { flush() }

    func flush(lifecycle: String? = nil, completion: @escaping @Sendable () -> Void = {}) {
        if let lifecycle { noteLifecycle(lifecycle) }
        guard isEnabled else { completion(); return }
        queue.async { [self] in
            do {
                for handle in handles.values { try handle.synchronize() }
                try checkpoint()
            } catch { fail(error, kind: "flush") }
            completion()
        }
    }

    /// Closes a segment without changing camera intent. Subsequent inputs open a new segment.
    private func seal(completion: @escaping @Sendable () -> Void) {
        let previous = directory
        let previousOpenedAt = openedAt
        let endedAt = Date()
        do {
            for handle in handles.values { try handle.synchronize(); try handle.close() }
        } catch { fail(error, kind: "close") }
        handles.removeAll()
        let sealedStatus = status()
        #if PRTS_DEV
        let previousVideo = video
        video = nil
        if let previousVideo { finishVideo(previousVideo) }
        #endif
        directory = nil
        let finished: @Sendable (String?) -> Void = { [self] failure in
            queue.async { [self] in
                if let failure { fail(RecordingError.video(failure), kind: "video_finalize") }
                do {
                    if let previous {
                        var segmentStatus = sealedStatus
                        segmentStatus.runID = previous.lastPathComponent
                        #if PRTS_DEV
                        if let videoFailure = videoFailures.removeValue(forKey: previous) {
                            segmentStatus.error = videoFailure
                            segmentStatus.failed["video_finalize", default: 0] += 1
                        }
                        #endif
                        try checkpoint(at: previous, endTime: endedAt, startTime: previousOpenedAt,
                                       segmentStatus: segmentStatus)
                    }
                } catch { fail(error, kind: "seal") }
                completion()
            }
        }
        #if PRTS_DEV
        finalizations.notify(queue: queue) { finished(nil) }
        #else
        finished(nil)
        #endif
    }

    func suspend(completion: @escaping @Sendable () -> Void = {}) {
        guard isEnabled else { completion(); return }
        event("recording_segment_stopped", details: ["reason": "system_background"])
        queue.async { [self] in seal(completion: completion) }
    }

    func export(completion: @escaping @Sendable (Result<URL, Error>) -> Void) {
        guard isEnabled else { completion(.failure(RecordingError.disabled)); return }
        guard lock.withLock({
            if maintenance { return false }
            maintenance = true
            return true
        }) else { completion(.failure(RecordingError.busy)); return }
        event("export_requested")
        queue.async { [self] in
            // Enumerate before rotating so new data cannot enter the immutable export set.
            let included = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey]
            )) ?? []
            seal { [self] in
                exportQueue.async { [self] in
                    defer { lock.withLock { maintenance = false } }
                    do {
                        guard !included.isEmpty else { throw RecordingError.noData }
                        let url = try RecordingArchive.create(from: included)
                        completion(.success(url))
                    } catch { completion(.failure(error)) }
                }
            }
        }
    }

    func clear(completion: @escaping @Sendable (Result<Void, Error>) -> Void) {
        guard isEnabled else { completion(.failure(RecordingError.disabled)); return }
        guard lock.withLock({
            if maintenance { return false }
            maintenance = true
            clearing = true
            generation &+= 1
            boundaryUptime = ProcessInfo.processInfo.systemUptime
            return true
        }) else { completion(.failure(RecordingError.busy)); return }
        queue.async { [self] in
            seal { [self] in
                do {
                    let files = FileManager.default
                    let documents = root.deletingLastPathComponent()
                    let targets = [root, RecordingArchive.root] + ["DevDiagnostics", "Sessions", "Diagnostics"].map {
                        documents.appendingPathComponent($0, isDirectory: true)
                    }
                    for target in targets {
                        if files.fileExists(atPath: target.path) { try files.removeItem(at: target) }
                    }
                    lock.withLock {
                        let pending = state.pending
                        let pendingBytes = state.pendingBytes
                        state = DiagnosticStatus()
                        state.pending = pending
                        state.pendingBytes = pendingBytes
                        clearing = false
                        maintenance = false
                    }
                    event("recording_started", details: ["reason": "clear_completed"])
                    completion(.success(()))
                } catch {
                    lock.withLock { clearing = false; maintenance = false }
                    fail(error, kind: "clear")
                    completion(.failure(error))
                }
            }
        }
    }
}

nonisolated enum RecordingError: LocalizedError {
    case disabled, busy, noData, insufficientSpace, exportSpace, writeFailed, video(String)
    var errorDescription: String? {
        let key: String
        switch self {
        case .disabled: key = "recording.error.disabled"
        case .busy: key = "recording.error.busy"
        case .noData: key = "recording.error.noData"
        case .insufficientSpace: key = "recording.error.space"
        case .exportSpace: key = "recording.error.exportSpace"
        case .writeFailed: key = "recording.error.write"
        case .video: key = "recording.error.video"
        }
        return AppLocalization.interfaceString(key)
    }
}
