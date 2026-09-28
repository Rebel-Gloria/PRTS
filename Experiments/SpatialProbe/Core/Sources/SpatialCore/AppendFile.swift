import Foundation

/// Caller serializes all access. Reopening a journal must never truncate earlier evidence.
public enum AppendFile {
    public static func open(at url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath:url.path) {
            guard FileManager.default.createFile(atPath:url.path,contents:nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forWritingTo:url)
        try handle.seekToEnd()
        return handle
    }
}
