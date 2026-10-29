import Foundation
import Testing
@testable import PRTS

/// Runs the bundled offline model through the app's own describe path on real photos.
/// Device only: the photos are the ones the local VLM benchmark copied to Documents/vlm/photos/1280.
@MainActor @Suite(.serialized)
struct PhotoLocalModelTests {
    static let photos = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("vlm/photos/1280")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: photos.path)))
    func describesBundledPhotosOffline() async throws {
        UserDefaults.standard.set(PhotoChatProvider.onDevice.rawValue, forKey: PhotoChatProvider.selectionKey)
        defer { UserDefaults.standard.removeObject(forKey: PhotoChatProvider.selectionKey) }
        let services = PhotoDescriptionServices()
        #expect(services.onDevice())
        let files = try FileManager.default.contentsOfDirectory(at: Self.photos, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for file in files {
            let start = Date()
            let answer = try await services.describe(try Data(contentsOf: file), PhotoChatProtocol.prompt, "")
            print("PRTS_LOCAL_VLM \(file.lastPathComponent) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(answer)")
            #expect(!answer.isEmpty)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: photos.path)))
    func cancellationStopsGeneration() async throws {
        let file = try #require(try FileManager.default.contentsOfDirectory(at: Self.photos, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "jpg" })
        let jpeg = try Data(contentsOf: file)
        UserDefaults.standard.set(PhotoChatProvider.onDevice.rawValue, forKey: PhotoChatProvider.selectionKey)
        defer { UserDefaults.standard.removeObject(forKey: PhotoChatProvider.selectionKey) }
        let describe = PhotoDescriptionServices().describe
        let task = Task { try await describe(jpeg, PhotoChatProtocol.prompt, "") }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}
