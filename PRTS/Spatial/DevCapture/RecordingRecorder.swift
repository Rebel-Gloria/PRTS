#if PRTS_DEV_CAPTURE
import ARKit
import CryptoKit
import Foundation
import SpatialCore

/// One admitted image at a time bounds retained camera buffers without blocking analysis.
nonisolated final class RecordingRecorder: @unchecked Sendable {
    enum Phase: Equatable, Sendable { case idle, recording, compressing, saved, failed }
    struct Status: Sendable {
        var mode = false
        var phase = Phase.idle
        var startedAt: Date?
        var text = ""
        var saved = 0
        var dropped = 0
        var busy = false
        var archiveRevision = 0
    }
    struct ImageReference: Encodable {
        let file: String
        let bytes: Int
        let sha256: String
        let width: Int, height: Int
    }
    typealias ImageEncoder = @Sendable (CVPixelBuffer, URL) throws -> Void
    private let lock = NSLock()
    private var state = Status()
    private let queue = DispatchQueue(label: "prts.recording", qos: .utility)
    private let diagnostics: DiagnosticRecorder
    private let store: RecordingStore
    private let encodeImage: ImageEncoder
    private let availableBytes: @Sendable (URL) throws -> Int
    private let packingQueue = DispatchQueue(label: "prts.recording.pack", qos: .utility)
    private let finishing = DispatchGroup()
    private var generation = UUID()
    private var active: Run?
    private var encoderBusy = false

    nonisolated private final class Run: @unchecked Sendable {
        let id = UUID()
        let journal: DiagnosticJournal
        let startedAt: Date
        let startedUptime: Double
        let epoch: UInt64
        // Counters and failure state use the recorder lock; file access uses the encoding queue.
        var saved = 0
        var dropped = 0
        var lastTimestamp = -Double.infinity
        var failureReason: String?
        var stopReason = ""
        var index: FileHandle?
        var bytes = 0

        init(journal: DiagnosticJournal, startedAt: Date, startedUptime: Double, epoch: UInt64) {
            self.journal = journal
            self.startedAt = startedAt
            self.startedUptime = startedUptime
            self.epoch = epoch
        }
    }

    init(
        diagnostics: DiagnosticRecorder,
        store: RecordingStore = .application,
        encodeImage: ImageEncoder? = nil,
        availableBytes: @escaping @Sendable (URL) throws -> Int = {
            try $0.resourceValues(forKeys: [.volumeAvailableCapacityKey])
                .volumeAvailableCapacity ?? 0
        }
    ) {
        self.diagnostics = diagnostics
        self.store = store
        if let encodeImage {
            self.encodeImage = encodeImage
        } else {
            let encoder = RecordingImageEncoder()
            self.encodeImage = { try encoder.encode($0, to: $1) }
        }
        self.availableBytes = availableBytes
    }

    func status() -> Status { lock.withLock { state } }
    private func update(_ body: (inout Status) -> Void) { lock.withLock { body(&state) } }

    func setMode(_ enabled: Bool) {
        update { $0.mode = enabled }
        if !enabled { stop(reason: "录制模式已关闭") }
    }

    /// Called on the mesh queue while the session queue is held, before new mesh mutations.
    func start(epoch: UInt64, meshes: [MeshSnapshot]) {
        lock.lock()
        defer { lock.unlock() }
        guard state.mode, active == nil else { return }
        let start = Date()
        let startedUptime = ProcessInfo.processInfo.systemUptime
        var limits = DiagnosticLimits()
        limits.runBytes = nil
        limits.totalBytes = nil
        // Admit the complete cached mesh before live deltas; SharedStore bounds it to 32 MiB.
        limits.maximumPending = max(limits.maximumPending, meshes.count + limits.reservedEvents + 1)
        limits.maximumPendingBytes = max(
            limits.maximumPendingBytes,
            meshes.reduce(0) { $0 + $1.byteCount * 2 + $1.floorPriors.count * 256 + 4096 }
                + limits.reservedEventBytes
        )
        // A second journal preserves the automatic image-free run and makes each recording
        // independently replayable, including anchors that predate the recording boundary.
        var metadata = diagnostics.recordingMetadata
        metadata["absentSensors"] = "Includes explicit camera images. No audio, GPS or raw IMU."
        let recording = DiagnosticJournal(
            root: store.working,
            metadata: metadata,
            limits: limits,
            onError: ErrorReporter(source: .storage).record
        )
        let seed = DiagnosticRecorder(journal: recording)
        for mesh in meshes {
            seed.mesh(
                mesh,
                id: mesh.id,
                epoch: mesh.epoch,
                revision: mesh.revision,
                callbackTime: mesh.callbackTime,
                action: "updated"
            )
        }
        let run = Run(
            journal: recording,
            startedAt: start,
            startedUptime: startedUptime,
            epoch: epoch
        )
        active = run
        generation = run.id
        seed.event("recording_started", details: "Explicit camera image recording", epoch: epoch)
        diagnostics.recordingJournal.attach(recording, startedAt: startedUptime)
        state = Status(
            mode: true,
            phase: .recording,
            startedAt: start,
            text: "录制中",
            busy: encoderBusy,
            archiveRevision: state.archiveRevision
        )
        queue.async { [self] in
            Self.flush(recording)
            do { try writeManifest(recording.directory, start: start, duration: nil) } catch {
                ErrorLog.application.record(error, source: .storage)
                stop(run, reason: error.localizedDescription, failure: true)
            }
        }
    }

    private static func flush(_ journal: DiagnosticJournal) {
        let done = DispatchSemaphore(value: 0)
        journal.flush { done.signal() }
        done.wait()
    }

    func stop(reason: String, completion: @escaping @Sendable () -> Void = {}) {
        lock.lock()
        guard let run = active else {
            finishing.notify(queue: queue, execute: completion)
            lock.unlock()
            return
        }
        finishLocked(run, reason: reason, completion: completion)
        lock.unlock()
    }

    func finishPendingArchives(completion: @escaping @Sendable () -> Void) {
        lock.withLock { finishing.notify(queue: queue, execute: completion) }
    }

    private func stop(_ run: Run, reason: String, failure: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if failure {
            run.failureReason = reason
            if generation == run.id { state.mode = false }
        }
        guard active === run else { return }
        finishLocked(run, reason: reason, completion: {})
    }

    /// Called with the admission lock held; only this boundary detaches a recording journal.
    private func finishLocked(
        _ run: Run,
        reason: String,
        completion: @escaping @Sendable () -> Void
    ) {
        finishing.enter()
        let duration = ProcessInfo.processInfo.systemUptime - run.startedUptime
        run.stopReason = reason
        state.phase = .compressing
        state.text = "正在压缩"
        _ = diagnostics.recordingJournal.detach()
        active = nil
        DiagnosticRecorder(journal: run.journal).event(
            "recording_stopped",
            details: reason,
            epoch: run.epoch
        )
        // Each stopped run owns its files and assertion. A new guidance run can record while
        // the previous archive is packing, without accepting an old completion as its status.
        Task { @MainActor [self] in
            let background = RecordingBackgroundTask()
            queue.async { [self] in
                let preparation: Result<Void, Error>
                do {
                    try run.index?.synchronize()
                    try run.index?.close()
                    run.index = nil
                    Self.flush(run.journal)
                    if let error = run.journal.status().error { throw fail(error) }
                    try finalizeMetadata(run, duration: duration)
                    preparation = .success(())
                } catch { preparation = .failure(error) }
                packingQueue.async { [self] in
                    let result: Result<URL, Error>
                    do {
                        try preparation.get()
                        result = .success(
                            try store.pack(
                                directory: run.journal.directory,
                                startedAt: run.startedAt,
                                duration: duration
                            )
                        )
                    } catch {
                        ErrorLog.application.record(error, source: .storage)
                        result = .failure(error)
                    }
                    lock.withLock {
                        if case .success = result { state.archiveRevision += 1 }
                        guard generation == run.id, state.phase == .compressing else { return }
                        switch result {
                        case .success:
                            state.phase = run.failureReason == nil ? .saved : .failed
                            state.text = run.failureReason ?? "已保存"
                        case .failure(let error):
                            state.phase = .failed
                            state.text = "录制失败：\(error.localizedDescription)"
                        }
                    }
                    finishing.leave()
                    completion()
                    Task { @MainActor in background.end() }
                }
            }
        }
    }

    private func writeManifest(_ directory: URL, start: Date, duration: Double?) throws {
        let url = directory.appendingPathComponent("manifest.json")
        var manifest =
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        manifest["privacy"] =
            "Explicit opt-in camera HEIC images and spatial evidence. No audio/GPS/upload."
        manifest["containsRGB"] = true
        manifest["recording"] =
            [
                "startedAt": start.timeIntervalSince1970,
                "duration": duration.map { $0 as Any } ?? NSNull(),
                "imageCodec": "HEIC", "imageQuality": 0.9,
                "coordinates": "Unrotated full sensor resolution; no crop, resize or overlays",
            ] as [String: Any]
        try JSONSerialization.data(
            withJSONObject: manifest,
            options: [.prettyPrinted, .sortedKeys]
        )
        .write(to: url, options: .atomic)
    }

    private func finalizeMetadata(_ run: Run, duration: Double) throws {
        let directory = run.journal.directory
        try writeManifest(directory, start: run.startedAt, duration: duration)
        let (saved, dropped, failure, reason) = lock.withLock {
            (run.saved, run.dropped, run.failureReason, run.stopReason)
        }
        try JSONSerialization.data(withJSONObject: [
            "phase": failure == nil ? "completed" : "failed", "savedSamples": saved,
            "droppedSamples": dropped,
            "indexBytes": run.bytes, "stopReason": failure ?? reason,
        ]).write(to: directory.appendingPathComponent("recording-status.json"), options: .atomic)
        // Empty streams are valid and keep the recording directory self-describing.
        for name in DiagnosticStream.allCases.map({ $0.rawValue + ".jsonl" }) + ["samples.jsonl"] {
            let file = directory.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                try Data().write(to: file)
            }
        }
    }

    private func fail(_ message: String) -> NSError {
        NSError(domain: "PRTSRecording", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    struct ModelOutput: Encodable, Sendable {
        let model = "DepthAnythingV2SmallF16"
        let units = "relative_inverse_depth_not_meters"
        let layout = "camera_aligned_model_output_not_heatmap"
        let width: Int, height: Int
        let calibration: InverseDepthCalibration?
        let provisionalFit: InverseDepthCalibration?
        let scaleDecision: MetricScaleDecision
        let scaleSamples: [ScaleSample]
        let groundReference: NativeGroundSelection
        let timings: [String: Double]
        let status: String
    }
    struct Feature: Encodable, Sendable {
        let id: UInt64
        let world: V3
    }
    struct MeshReference: Encodable, Sendable {
        let id: String
        let revision: UInt64
        let callbackTime: Double
    }
    struct Packet: @unchecked Sendable {
        let image: CVPixelBuffer
        let timestamp: Double
        let epoch: UInt64
        let capture: CaptureDiagnostic?
        let result: AnalysisResult
        let path: PathUpdate
        let source: String
        var observation: DepthObservation? = nil
        var relative: [Float]? = nil
        var model: ModelOutput? = nil
        var planes: [NativePlaneObservation] = []
        var features: [Feature] = []
        var featureCount = 0
        var featureStep = 1
        var meshes: [MeshReference] = []
        var pathOptions = PathOptions()
    }
    func submit(
        frame: FrameSnapshot,
        result: AnalysisResult,
        path: PathUpdate,
        observation: DepthObservation?,
        prediction: MonocularFrame?,
        meshes: [String: MeshSnapshot],
        pathOptions: PathOptions
    ) {
        guard status().phase == .recording else { return }
        var packet = Packet(
            image: frame.frame.capturedImage,
            timestamp: frame.frame.timestamp,
            epoch: frame.epoch,
            capture: CaptureDiagnostic(frame),
            result: result,
            path: path,
            source: result.source
        )
        packet.observation = observation
        packet.pathOptions = pathOptions
        packet.planes = prediction?.planes ?? MonocularDepthProvider.planes(frame)
        packet.meshes = meshes.values.map {
            MeshReference(id: $0.id, revision: $0.revision, callbackTime: $0.callbackTime)
        }.sorted { $0.id < $1.id }
        if let cloud = frame.frame.rawFeaturePoints {
            packet.featureCount = cloud.points.count
            packet.featureStep = max(1, (cloud.points.count + 511) / 512)
            packet.features = stride(from: 0, to: cloud.points.count, by: packet.featureStep).map {
                Feature(id: cloud.identifiers[$0], world: cloud.points[$0])
            }
        }
        if let p = prediction {
            packet.relative = p.relative
            packet.model = ModelOutput(
                width: p.width,
                height: p.height,
                calibration: p.calibration,
                provisionalFit: p.provisionalFit,
                scaleDecision: p.scaleDecision,
                scaleSamples: p.samples,
                groundReference: p.groundReference,
                timings: p.timings,
                status: p.status
            )
        }
        submit(packet)
    }
    func submit(_ packet: Packet) {
        lock.lock()
        guard let run = active, packet.timestamp.isFinite,
            packet.timestamp >= run.startedUptime, packet.timestamp > run.lastTimestamp,
            packet.epoch == run.epoch
        else {
            lock.unlock()
            return
        }
        guard !encoderBusy else {
            run.dropped += 1
            state.dropped = run.dropped
            lock.unlock()
            return
        }
        encoderBusy = true
        state.busy = true
        run.lastTimestamp = packet.timestamp
        // Admission and queueing are atomic with stop; accepted frames drain before packaging.
        queue.async { [self] in
            defer {
                lock.withLock {
                    encoderBusy = false
                    state.busy = false
                }
            }
            do {
                guard try availableBytes(run.journal.directory) >= 256 * 1024 * 1024 else {
                    throw fail("可用空间低于256 MiB")
                }
                try append(packet, run: run)
            } catch {
                ErrorLog.application.record(error, source: .storage)
                stop(run, reason: error.localizedDescription, failure: true)
            }
        }
        lock.unlock()
    }

    private func append(_ packet: Packet, run: Run) throws {
        let directory = run.journal.directory
        if run.index == nil {
            run.index = try AppendFile.open(at: directory.appendingPathComponent("samples.jsonl"))
        }
        guard let index = run.index else { throw fail("无法建立帧索引") }
        struct Evidence: Encodable {
            let capture: CaptureDiagnostic?
            let analysis: AnalysisResult
            let path: PathUpdate
            let pathOptions: PathOptions
            let model: ModelOutput?
            let nativePlanes: [NativePlaneObservation]
            let sparseFeatures: [Feature]
            let totalFeatureCount: Int, featureSamplingStep: Int
            let meshReferences: [MeshReference]
            let source: String
        }
        struct Attachment: Encodable {
            let file: String, codec: String, sha256: String
            let compressedBytes: Int, uncompressedBytes: Int
        }
        struct Sample: Encodable {
            let epoch: UInt64, frameID: UInt64
            let timestamp: Double
            let image: ImageReference
            let evidence: Attachment
            let depth: Attachment?
            let relative: Attachment?
        }
        let stem = "\(packet.epoch)-\(packet.result.frameID)"
        var attachments: [(Attachment, Data)] = []
        func pack(_ raw: Data, _ suffix: String) throws -> Attachment {
            let encoded = try (raw as NSData).compressed(using: .zlib) as Data
            let ref = Attachment(
                file: stem + suffix,
                codec: "deflate-raw",
                sha256: SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(),
                compressedBytes: encoded.count,
                uncompressedBytes: raw.count
            )
            attachments.append((ref, encoded))
            return ref
        }
        let evidence = Evidence(
            capture: packet.capture,
            analysis: packet.result,
            path: packet.path,
            pathOptions: packet.pathOptions,
            model: packet.model,
            nativePlanes: packet.planes,
            sparseFeatures: packet.features,
            totalFeatureCount: packet.featureCount,
            featureSamplingStep: packet.featureStep,
            meshReferences: packet.meshes,
            source: packet.source
        )
        let evidenceRef = try pack(DiagnosticJSON.encode(evidence), ".evidence.json.deflate")
        let depthRef = try packet.observation.map {
            try pack(
                DepthFrameCodec.encode(
                    $0,
                    parameters: packet.result.parameters,
                    parameterVersion: packet.result.parameterVersion,
                    priors: packet.result.floorPriors,
                    directionStable: packet.result.sourceDirectionStable ?? false,
                    source: packet.source
                ),
                ".depth.bin.deflate"
            )
        }
        let relativeRef = try packet.relative.map { values -> Attachment in
            var raw = Data(capacity: values.count * 4)
            for value in values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { raw.append(contentsOf: $0) }
            }
            return try pack(raw, ".relative.f32.deflate")
        }
        let imageURL = directory.appendingPathComponent(stem + ".heic")
        try encodeImage(packet.image, imageURL)
        let imageData = try Data(contentsOf: imageURL)
        let imageRef = ImageReference(
            file: imageURL.lastPathComponent,
            bytes: imageData.count,
            sha256: SHA256.hash(data: imageData).map { String(format: "%02x", $0) }.joined(),
            width: CVPixelBufferGetWidth(packet.image),
            height: CVPixelBufferGetHeight(packet.image)
        )
        let data = try DiagnosticJSON.encode(
            Sample(
                epoch: packet.epoch,
                frameID: packet.result.frameID,
                timestamp: packet.timestamp,
                image: imageRef,
                evidence: evidenceRef,
                depth: depthRef,
                relative: relativeRef
            )
        )
        for (ref, raw) in attachments {
            try raw.write(to: directory.appendingPathComponent(ref.file), options: .atomic)
        }
        try index.write(contentsOf: data)
        try index.write(contentsOf: Data([10]))
        run.bytes += data.count + 1
        lock.withLock {
            run.saved += 1
            if generation == run.id { state.saved = run.saved }
        }
    }
}
#endif
