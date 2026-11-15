import Foundation

/// The coordinator provides a streaming ZIP representation; never loads an archive into memory.
nonisolated enum RecordingArchive {
    static let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecordingExports", isDirectory: true)

    static func create(from directories: [URL]) throws -> URL {
        let files = FileManager.default
        var sourceBytes: Int64 = 0
        for directory in directories {
            if let entries = files.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]
            ) {
                for case let file as URL in entries {
                    let values = try file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                    if values.isRegularFile == true { sourceBytes += Int64(values.fileSize ?? 0) }
                }
            }
        }
        let available = try files.temporaryDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        .volumeAvailableCapacityForImportantUsage
        // Staging, coordinated ZIP and the exported copy can coexist. Preserve capture headroom.
        if let available, available < sourceBytes * 3 + 256 * 1024 * 1024 {
            throw RecordingError.exportSpace
        }
        let id =
            ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            + "-" + UUID().uuidString.prefix(8)
        let staging = root.appendingPathComponent(id, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        for source in directories {
            guard try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                continue
            }
            try files.copyItem(
                at: source,
                to: staging.appendingPathComponent(source.lastPathComponent)
            )
        }
        let output = root.appendingPathComponent("PRTS-\(id).zip")
        var coordinationError: NSError?
        var copyError: Error?
        var copied = false
        NSFileCoordinator().coordinate(
            readingItemAt: staging,
            options: .forUploading,
            error: &coordinationError
        ) { archive in
            do {
                try files.copyItem(at: archive, to: output)
                copied = true
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        guard copied else { throw RecordingError.writeFailed }
        return output
    }
}
