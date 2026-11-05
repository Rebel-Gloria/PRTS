import Foundation

/// Only fixed source names and error domain/code enter the product log, never error userInfo.
nonisolated enum ErrorSource: String, Codable, Sendable {
    case camera, photoDescription, textReading, liveCaption, audio, rendering, storage
}

nonisolated struct ErrorRecord: Codable, Sendable {
    let time: Date
    let version: String
    let source: ErrorSource
    let domain: String
    let code: Int
}

/// One serial owner per directory. Disk retention and pending-memory limits are independent.
nonisolated final class ErrorLog: @unchecked Sendable {
    static let productionLimit = 1_000_000_000
    static let application: ErrorLog = {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #if PRTS_DEV_CAPTURE
        return ErrorLog(directory: documents.appendingPathComponent("DevDiagnostics/Errors"))
        #else
        return ErrorLog(
            directory: documents.appendingPathComponent("ErrorLogs"),
            maximumBytes: productionLimit,
            legacyDirectories: ["Sessions", "Diagnostics"].map {
                documents.appendingPathComponent($0, isDirectory: true)
            }
        )
        #endif
    }()

    private struct Segment {
        let url: URL
        var bytes: Int
    }

    let directory: URL
    private let maximumBytes: Int?
    private let segmentBytes: Int
    private let version: String
    private let queue = DispatchQueue(label: "PRTS.errorLog", qos: .utility)
    private let admission = NSLock()
    private var pending = 0
    // All remaining mutable state belongs to queue.
    private var segments: [Segment] = []
    private var bytes = 0
    private var handle: FileHandle?
    private var failure: Error?
    private let encoder = JSONEncoder()

    init(
        directory: URL,
        maximumBytes: Int? = nil,
        segmentBytes: Int = 4 * 1024 * 1024,
        legacyDirectories: [URL] = [],
        version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? ""
    ) {
        precondition(segmentBytes > 0 && (maximumBytes.map { $0 > 0 } ?? true))
        self.directory = directory
        self.maximumBytes = maximumBytes
        self.segmentBytes = segmentBytes
        self.version = version
        encoder.dateEncodingStrategy = .iso8601
        queue.async {
            do {
                try self.prepare(legacyDirectories: legacyDirectories)
            } catch {
                self.failure = error
            }
        }
    }

    func record(_ error: Error, source: ErrorSource) {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        let error = error as NSError
        let entry = ErrorRecord(
            time: Date(),
            version: version,
            source: source,
            domain: error.domain,
            code: error.code
        )
        let accepted = admission.withLock {
            guard pending < 64 else { return false }
            pending += 1
            return true
        }
        guard accepted else { return }
        queue.async {
            defer { self.admission.withLock { self.pending -= 1 } }
            guard self.failure == nil else { return }
            do {
                var data = try self.encoder.encode(entry)
                data.append(10)
                try self.append(data)
            } catch {
                // A logging failure never retries recursively or changes the feature's result.
                self.failure = error
            }
        }
    }

    func flush() async throws {
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.handle?.synchronize()
                    if let failure = self.failure { throw failure }
                    done.resume()
                } catch {
                    done.resume(throwing: error)
                }
            }
        }
    }

    private func prepare(legacyDirectories: [URL]) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var excluded = directory
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try excluded.setResourceValues(attributes)
        let marker = directory.appendingPathComponent(".legacy-v1-removed")
        if !legacyDirectories.isEmpty, !files.fileExists(atPath: marker.path) {
            for legacy in legacyDirectories where files.fileExists(atPath: legacy.path) {
                try files.removeItem(at: legacy)
            }
            try Data([1]).write(to: marker, options: .atomic)
        }
        for url in try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
        ) {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            bytes += size
            if url.pathExtension == "jsonl" { segments.append(Segment(url: url, bytes: size)) }
        }
        segments.sort { $0.url.lastPathComponent < $1.url.lastPathComponent }
        try makeRoom(for: 0)
    }

    private func makeRoom(for count: Int) throws {
        guard let maximumBytes else { return }
        guard count <= maximumBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        while bytes > maximumBytes - count {
            guard let first = segments.first else { throw CocoaError(.fileWriteOutOfSpace) }
            if segments.count == 1 {
                try handle?.close()
                handle = nil
            }
            try FileManager.default.removeItem(at: first.url)
            bytes -= first.bytes
            segments.removeFirst()
        }
    }

    private func append(_ data: Data) throws {
        if handle != nil, let current = segments.last, current.bytes + data.count > segmentBytes {
            try handle?.close()
            handle = nil
        }
        try makeRoom(for: data.count)
        if handle == nil {
            let name =
                String(format: "%020.6f", Date().timeIntervalSince1970)
                + "-" + UUID().uuidString + ".jsonl"
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            handle = try FileHandle(forWritingTo: url)
            segments.append(Segment(url: url, bytes: 0))
        }
        try handle!.write(contentsOf: data)
        segments[segments.count - 1].bytes += data.count
        bytes += data.count
    }
}
