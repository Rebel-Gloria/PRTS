import Foundation
import Testing

@testable import PRTS

struct ErrorLogTests {
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func records(_ root: URL) throws -> [ErrorRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "jsonl" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        .flatMap { url in
            try Data(contentsOf: url).split(separator: 10).map {
                try decoder.decode(ErrorRecord.self, from: Data($0))
            }
        }
    }

    private func bytes(_ root: URL) throws -> Int {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey]
        )
        .reduce(0) { try $0 + ($1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    }

    @Test func productRotatesAcrossLaunchesAndKeepsTheLatestErrors() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for start in [0, 20] {
            let log = ErrorLog(
                directory: root,
                maximumBytes: 900,
                segmentBytes: 250,
                version: "test"
            )
            for code in start..<(start + 20) {
                log.record(NSError(domain: "test", code: code), source: .camera)
            }
            try await log.flush()
            #expect(try bytes(root) <= 900)
        }
        let kept = try records(root)
        #expect(kept.last?.code == 39)
        #expect(!kept.contains { $0.code == 0 })
        #expect(kept.map(\.code) == kept.map(\.code).sorted())
    }

    @Test func developerHistoryHasNoAggregateCapacityLimit() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        for start in [0, 20] {
            let log = ErrorLog(directory: root, segmentBytes: 250, version: "test")
            for code in start..<(start + 20) {
                log.record(NSError(domain: "test", code: code), source: .camera)
            }
            try await log.flush()
        }
        #expect(try records(root).map(\.code) == Array(0..<40))
        #expect(try bytes(root) > 900)
    }

    @Test func cancellationAndPrivateErrorDetailsAreNotPersisted() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = ErrorLog(directory: root, maximumBytes: 900, version: "test")
        log.record(CancellationError(), source: .camera)
        log.record(URLError(.cancelled), source: .photoDescription)
        log.record(
            NSError(
                domain: "test",
                code: 7,
                userInfo: [
                    NSLocalizedDescriptionKey: "SECRET_API_KEY",
                    "image": "PRIVATE_PHOTO", "answer": "PRIVATE_TEXT",
                ]
            ),
            source: .photoDescription
        )
        try await log.flush()
        let saved = try records(root)
        #expect(saved.count == 1)
        #expect(saved.first?.code == 7)
        for url in try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) {
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(!text.contains("SECRET") && !text.contains("PRIVATE"))
        }
    }

    @Test func migrationRemovesOnlyTheNamedLegacyDirectoriesOnce() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Sessions")
        let retained = root.appendingPathComponent("Models")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
        let errors = root.appendingPathComponent("Errors")
        let first = ErrorLog(directory: errors, maximumBytes: 900, legacyDirectories: [old])
        try await first.flush()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: retained.path))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let next = ErrorLog(directory: errors, maximumBytes: 900, legacyDirectories: [old])
        try await next.flush()
        #expect(FileManager.default.fileExists(atPath: old.path))
    }

    @Test func loggingFailureIsReturnedByFlushWithoutFailingTheCaller() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let occupied = root.appendingPathComponent("file")
        try Data([1]).write(to: occupied)
        let log = ErrorLog(directory: occupied)
        log.record(NSError(domain: "test", code: 1), source: .camera)
        await #expect(throws: (any Error).self) { try await log.flush() }
        #expect(try Data(contentsOf: occupied) == Data([1]))
    }
}
