import Foundation
import CryptoKit

public enum DiagnosticStream: String, Codable, Sendable, CaseIterable {
    case events, capture, analysis, render, mesh, heartbeat, prediction, path
}
public struct DiagnosticPacket: Sendable {
    public var json: Data
    public var binary: Data?
    public init(json: Data,binary: Data? = nil) { self.json = json; self.binary = binary }
}
public enum DiagnosticJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity:"+inf",negativeInfinity:"-inf",nan:"nan")
        return try encoder.encode(value)
    }
}
public struct DiagnosticLimits: Codable, Sendable {
    public var maximumPending = 64
    public var reservedEvents = 8
    public var reservedEventBytes = 64*1024
    public var maximumPendingBytes = 16*1024*1024
    public var runBytes = 512*1024*1024
    public var totalBytes = 2*1024*1024*1024
    public var segmentBytes = 32*1024*1024
    public init() {}
}
public struct DiagnosticStatus: Codable, Sendable {
    public var runID: String = ""
    public var bytesWritten = 0
    public var pending = 0
    public var pendingBytes = 0
    public var attempted: [String:Int] = [:]
    public var written: [String:Int] = [:]
    public var dropped: [String:Int] = [:]
    public var failed: [String:Int] = [:]
    public var error: String?
    public var limitReached = false
    public var lastCheckpointUptime: Double = 0
    public var lastLifecycle = "launch"
    public var maximumPendingObserved = 0
    public var maximumPendingBytesObserved = 0
    public var lastQueueWaitMS: Double = 0
    public var lastEncodeMS: Double = 0
    public var lastCompressionMS: Double = 0
    public var lastWriteMS: Double = 0
    public var droppedTotal: Int { dropped.values.reduce(0,+) }
    public init() {}
}
public struct DiagnosticRun: Sendable, Identifiable {
    public let id: String
    public let bytes: Int
    public init(id: String,bytes: Int) { self.id = id; self.bytes = bytes }
}
private struct BinaryReference: Encodable {
    let file: String,codec: String,sha256: String
    let offset: UInt64
    let compressedBytes: Int,uncompressedBytes: Int
}

/// One journal per app launch; all I/O/compression runs on its serial utility queue.
/// No camera buffers are retained. Admission is bounded before producers materialize JSON or binary data.
public final class DiagnosticJournal: @unchecked Sendable {
    public let root: URL
    public let directory: URL
    public let limits: DiagnosticLimits
    private let queue = DispatchQueue(label:"probe.diagnostic.disk",qos:.utility)
    private let lock = NSLock()
    private var state = DiagnosticStatus()
    private var handles: [String:FileHandle] = [:] // queue only
    private var ready = false
    private var previousBytes = 0
    private var segment = 0
    private var segmentSize = 0
    private var sequence: UInt64 = 0
    private var lastSync: Double = 0
    private var checkpointScheduled = false

    public init(root: URL,metadata: [String:String],limits: DiagnosticLimits = .init()) {
        self.root = root; self.limits = limits
        let date = ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        let id = date+"-"+UUID().uuidString
        directory = root.appendingPathComponent(id,isDirectory:true); state.runID = id
        let launchedAt = ISO8601DateFormatter().string(from:Date()),uptime = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            do {
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                previousBytes = Self.size(of:root)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                var dir = directory; try dir.setResourceValues(values)
                let manifest: [String:Any] = ["schemaVersion":1,"runID":id,"launchedAt":launchedAt,"launchUptime":uptime,
                    "metadata":metadata,"limits":try JSONSerialization.jsonObject(with:DiagnosticJSON.encode(limits)),
                    "privacy":"No capturedImage/RGB/video/audio/GPS. Depth, confidence, poses and mesh are spatially sensitive; local storage only.",
                    "source":metadata["source"] ?? metadata["environment"] ?? "unknown",
                    "rawFramePolicy":"All completed analysis frames at configured analysis Hz, not every camera frame. Bounded admission; drops and limits in status.json.",
                    "binaryFormat":"8-byte little-endian compressed/uncompressed uint32 lengths, then raw DEFLATE. JSON attachment offset points to that header. SHA256 covers uncompressed bytes.",
                    "termination":"No final event does not prove a crash. iOS can suspend/kill without callback. Tail writes may be incomplete.",
                    "sensorSkew":"ARKit does not expose an independent sceneDepth hardware timestamp"]
                let data = try JSONSerialization.data(withJSONObject:manifest,options:[.prettyPrinted,.sortedKeys])
                try data.write(to:directory.appendingPathComponent("manifest.json"),options:.atomic)
                update { $0.bytesWritten += data.count }
                ready = true
                try checkpoint(force:true)
            } catch { fail(error,stream:.events) }
        }
    }
    public func status() -> DiagnosticStatus { lock.lock(); defer { lock.unlock() }; return state }
    private func update(_ action: (inout DiagnosticStatus) -> Void) { lock.lock(); action(&state); lock.unlock() }
    @discardableResult public func submit(_ stream: DiagnosticStream,estimatedBytes: Int = 4096,
                                         make: @escaping @Sendable () throws -> DiagnosticPacket) -> Bool {
        let cost = max(1,estimatedBytes),priority = stream == .events
        // Count slots alone do not protect lifecycle events when mesh payloads fill the byte budget.
        let reservedBytes = min(max(0,limits.reservedEventBytes),max(0,limits.maximumPendingBytes/8))
        let byteBudget = limits.maximumPendingBytes-(priority ? 0 : reservedBytes)
        lock.lock()
        state.attempted[stream.rawValue,default:0] += 1
        guard !state.limitReached,state.error == nil,
              state.pending < max(1,limits.maximumPending-(priority ? 0 : limits.reservedEvents)),
              cost <= byteBudget-state.pendingBytes else {
            state.dropped[stream.rawValue,default:0] += 1; lock.unlock(); return false
        }
        state.pending += 1; state.pendingBytes += cost
        state.maximumPendingObserved = max(state.maximumPendingObserved,state.pending)
        state.maximumPendingBytesObserved = max(state.maximumPendingBytesObserved,state.pendingBytes)
        lock.unlock()
        let queuedAt = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            defer {
                update { $0.pending -= 1; $0.pendingBytes -= cost }
                do { try checkpoint(force:status().error != nil || status().limitReached) } catch { fail(error,stream:stream) }
            }
            guard ready,!status().limitReached,status().error == nil else {
                update { $0.dropped[stream.rawValue,default:0] += 1 }; return
            }
            do {
                let began = ProcessInfo.processInfo.systemUptime
                let packet = try make()
                let encodeMS = (ProcessInfo.processInfo.systemUptime-began)*1000
                let queueWaitMS = (began-queuedAt)*1000
                update { $0.lastQueueWaitMS = queueWaitMS; $0.lastEncodeMS = encodeMS }
                guard packet.json.count+(packet.binary?.count ?? 0) <= 64*1024*1024 else {
                    update { $0.dropped[stream.rawValue,default:0] += 1 }; return
                }
                try write(packet,to:stream,queueWaitMS:queueWaitMS,encodeMS:encodeMS)
            } catch { fail(error,stream:stream) }
        }
        return true
    }
    private func fail(_ error: Error,stream: DiagnosticStream) {
        update { $0.failed[stream.rawValue,default:0] += 1; $0.error = error.localizedDescription }
    }
    private func handle(_ name: String) throws -> FileHandle {
        if let existing = handles[name] { return existing }
        let h = try AppendFile.open(at:directory.appendingPathComponent(name)); handles[name] = h; return h
    }
    private func write(_ packet: DiagnosticPacket,to stream: DiagnosticStream,queueWaitMS: Double,encodeMS: Double) throws {
        let started = ProcessInfo.processInfo.systemUptime
        var compressed: Data?,reference: BinaryReference?
        if let binary = packet.binary {
            compressed = try (binary as NSData).compressed(using:.zlib) as Data
            if let compressed {
                if segmentSize > 0,segmentSize+compressed.count+8 > limits.segmentBytes {
                    let name = String(format:"data-%05d.bin",segment)
                    try handles[name]?.synchronize(); try handles[name]?.close(); handles.removeValue(forKey:name)
                    segment += 1; segmentSize = 0
                }
                reference = .init(file:String(format:"data-%05d.bin",segment),codec:"deflate-raw",sha256:SHA256.hash(data:binary).map { String(format:"%02x",$0) }.joined(),
                                  offset:UInt64(segmentSize),compressedBytes:compressed.count,uncompressedBytes:binary.count)
            }
        }
        let compressionMS = (ProcessInfo.processInfo.systemUptime-started)*1000
        update { $0.lastCompressionMS = compressionMS }
        sequence &+= 1
        var line = Data("{\"sequence\":\(sequence),\"writtenUptime\":\(ProcessInfo.processInfo.systemUptime),\"payload\":".utf8)
        line.append(packet.json)
        line.append(Data(",\"diagnosticTiming\":{\"queueWaitMS\":\(queueWaitMS),\"encodeMS\":\(encodeMS),\"compressionMS\":\(compressionMS)}".utf8))
        if let reference { line.append(Data(",\"attachment\":".utf8)); line.append(try DiagnosticJSON.encode(reference)) }
        line.append(Data("}\n".utf8))
        let bytes = line.count+(compressed.map { $0.count+8 } ?? 0)
        let used = status().bytesWritten
        guard bytes <= limits.runBytes-used,bytes <= limits.totalBytes-previousBytes-used else {
            update { $0.limitReached = true; $0.dropped[stream.rawValue,default:0] += 1 }
            try checkpoint(force:true); return
        }
        let writeStart = ProcessInfo.processInfo.systemUptime
        if let reference,let compressed {
            var c = UInt32(reference.compressedBytes).littleEndian,u = UInt32(reference.uncompressedBytes).littleEndian
            var header = withUnsafeBytes(of:&c) { Data($0) }; header.append(withUnsafeBytes(of:&u) { Data($0) })
            let h = try handle(reference.file); try h.write(contentsOf:header); try h.write(contentsOf:compressed)
            segmentSize += compressed.count+8
            update { $0.bytesWritten += compressed.count+8 }
        }
        try handle(stream.rawValue+".jsonl").write(contentsOf:line)
        update { $0.bytesWritten += line.count; $0.written[stream.rawValue,default:0] += 1; $0.lastWriteMS = (ProcessInfo.processInfo.systemUptime-writeStart)*1000 }
    }
    private func checkpoint(force: Bool) throws {
        guard ready else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now-lastSync >= 1 else { return }
        for h in handles.values { try h.synchronize() }
        lastSync = now; update { $0.lastCheckpointUptime = now }
        try DiagnosticJSON.encode(status()).write(to:directory.appendingPathComponent("status.json"),options:.atomic)
    }
    public func noteLifecycle(_ value: String) { update { $0.lastLifecycle = value } }
    public func requestCheckpoint() {
        lock.lock()
        guard !checkpointScheduled else { lock.unlock(); return }
        checkpointScheduled = true; lock.unlock()
        queue.async { [self] in
            defer { lock.lock(); checkpointScheduled = false; lock.unlock() }
            do { try checkpoint(force:false) } catch { fail(error,stream:.events) }
        }
    }
    public func flush(lifecycle: String? = nil,completion: @escaping @Sendable () -> Void = {}) {
        if let lifecycle { update { $0.lastLifecycle = lifecycle } }
        queue.async { [self] in
            do { try checkpoint(force:true) } catch { fail(error,stream:.events) }
            completion()
        }
    }
    public func listRuns(completion: @escaping @Sendable ([DiagnosticRun]) -> Void) {
        queue.async { [self] in
            let dirs = (try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.isDirectoryKey])) ?? []
            let runs = dirs.filter { FileManager.default.fileExists(atPath:$0.appendingPathComponent("manifest.json").path) }
                .sorted { $0.lastPathComponent > $1.lastPathComponent }.prefix(30)
                .map { DiagnosticRun(id:$0.lastPathComponent,bytes:Self.size(of:$0)) }
            completion(runs)
        }
    }
    public func export(runID: String? = nil,to exportRoot: URL,completion: @escaping @Sendable (Result<URL,Error>) -> Void) {
        queue.async { [self] in
            do {
                try checkpoint(force:true)
                let id = runID ?? directory.lastPathComponent
                guard !id.isEmpty,!id.contains("/"),!id.contains("\\"),id != ".",id != ".." else { throw CocoaError(.fileReadInvalidFileName) }
                let source = root.appendingPathComponent(id,isDirectory:true)
                guard FileManager.default.fileExists(atPath:source.appendingPathComponent("manifest.json").path) else { throw CocoaError(.fileNoSuchFile) }
                let free = (try? exportRoot.deletingLastPathComponent().resourceValues(forKeys:[.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? Int.max
                guard free > Self.size(of:source)+64*1024*1024 else { throw CocoaError(.fileWriteOutOfSpace) }
                try FileManager.default.createDirectory(at:exportRoot,withIntermediateDirectories:true)
                let destination = exportRoot.appendingPathComponent(id+"-export-"+UUID().uuidString.prefix(6),isDirectory:true)
                try FileManager.default.copyItem(at:source,to:destination)
                completion(.success(destination))
            } catch { completion(.failure(error)) }
        }
    }
    public static func size(of directory: URL) -> Int {
        let e = FileManager.default.enumerator(at:directory,includingPropertiesForKeys:[.fileSizeKey,.isRegularFileKey])
        var total = 0
        while let url = e?.nextObject() as? URL {
            guard let v = try? url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey]) else { continue }
            if v.isRegularFile == true { total += v.fileSize ?? 0 }
        }
        return total
    }
}
