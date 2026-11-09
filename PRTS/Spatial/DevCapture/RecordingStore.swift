#if PRTS_DEV_CAPTURE
import Foundation

nonisolated struct SavedRecording: Identifiable, Sendable {
    let url: URL
    let startedAt: Date
    let duration: TimeInterval
    let bytes: Int
    var id: URL { url }
}

/// Only complete archives enter Recordings; the filename also carries list metadata.
nonisolated struct RecordingStore: Sendable {
    let root: URL
    var recordings: URL { root.appendingPathComponent("Recordings", isDirectory: true) }
    var working: URL { root.appendingPathComponent("RecordingWork", isDirectory: true) }

    static var application: Self {
        Self(
            root: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DevDiagnostics", isDirectory: true)
        )
    }

    func pack(directory: URL, startedAt: Date, duration: TimeInterval) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: recordings, withIntermediateDirectories: true)
        var recordingDirectory = recordings
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try recordingDirectory.setResourceValues(values)
        let name = "\(startedAt.timeIntervalSince1970)_\(duration)_\(UUID().uuidString).zip"
        let destination = recordings.appendingPathComponent(name)
        var staging = recordings.appendingPathComponent(name + ".partial")
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(
            readingItemAt: directory,
            options: .forUploading,
            error: &coordinationError
        ) { archive in
            do {
                try manager.moveItem(at: archive, to: staging)
            } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
        try staging.setResourceValues(values)
        try manager.moveItem(at: staging, to: destination)
        try manager.removeItem(at: directory)
        return destination
    }

    func list() throws -> [SavedRecording] {
        guard FileManager.default.fileExists(atPath: recordings.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: [.fileSizeKey]
        ).filter { $0.pathExtension == "zip" }.compactMap { url in
            let fields = url.deletingPathExtension().lastPathComponent.split(separator: "_")
            guard fields.count == 3, let time = Double(fields[0]), let duration = Double(fields[1])
            else { return nil }
            return SavedRecording(
                url: url,
                startedAt: Date(timeIntervalSince1970: time),
                duration: duration,
                bytes: try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            )
        }.sorted { $0.startedAt > $1.startedAt }
    }

    func delete(_ recording: SavedRecording) throws {
        try FileManager.default.removeItem(at: recording.url)
    }
}
#endif
