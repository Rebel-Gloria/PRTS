import Foundation
import UIKit
import Testing
@testable import PRTS

/// Runs the bundled offline model through the app's own describe path on real photos.
/// Device only: the photos are the ones the local VLM benchmark copied to Documents/vlm/photos/1280.
@MainActor @Suite(.serialized)
struct PhotoLocalModelTests {
    nonisolated static let photos = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
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

/// The bundled model reading text, through the same two questions as the app. Device only. Kept in
/// the serialized suite: a photo description between the two questions would change the photo.
extension PhotoLocalModelTests {
    private func photo(_ lines: [String], background: UIColor, card: UIColor, ink: UIColor) throws -> Data {
        let size = CGSize(width: 1280, height: 960)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            background.setFill(); context.fill(CGRect(origin: .zero, size: size))
            card.setFill(); context.fill(CGRect(x: 240, y: 160, width: 800, height: 120 + CGFloat(lines.count) * 130))
            for (row, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 300, y: 220 + CGFloat(row) * 130),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: ink])
            }
        }
        return try #require(image.jpegData(compressionQuality: 0.85))
    }

    private func read(_ jpeg: Data) async throws -> (TextReadingPrompt.Surface, String) {
        let start = Date()
        let surface = try await TextReadingPrompt.surface(of: jpeg)
        let text = try await TextReadingPrompt.copy { _ in }
        print("PRTS_OCR \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(surface.rawValue) | \(text)")
        return (surface, text)
    }

    @Test(.enabled(if: Bundle.main.url(forResource: "mmproj-model-f16", withExtension: "gguf", subdirectory: "LocalVLM") != nil))
    func readsARoadSignAndAShopSign() async throws {
        let road = try await read(photo(["人民路", "地铁站 200米"], background: .systemTeal, card: UIColor(red: 0.08, green: 0.43, blue: 0.24, alpha: 1), ink: .white))
        #expect(road.0 == .roadSign)
        #expect(road.1.contains("人民路") && road.1.contains("地铁站"))
        let shop = try await read(photo(["幸福便利店", "24小时营业"], background: .lightGray, card: UIColor(red: 0.8, green: 0.1, blue: 0.12, alpha: 1), ink: .white))
        #expect(shop.0 == .sign)
        #expect(shop.1.contains("幸福便利店"))
    }

    @Test(.enabled(if: Bundle.main.url(forResource: "mmproj-model-f16", withExtension: "gguf", subdirectory: "LocalVLM") != nil))
    func saysNoneWithoutText() async throws {
        let blank = try await read(photo([], background: .brown, card: .darkGray, ink: .white))
        #expect(blank.1.trimmingCharacters(in: .punctuationCharacters) == TextReadingPrompt.none)
    }
}

/// The remote readers with real keys, through the app's own request code. Runs only when the
/// keys are passed in (TEST_RUNNER_PRTS_QWEN_KEY / TEST_RUNNER_PRTS_DEEPSEEK_KEY on xcodebuild);
/// they are never stored in the repo.
@MainActor
struct RemoteTextReadingTests {
    nonisolated static let env = ProcessInfo.processInfo.environment

    private func roadSign() throws -> Data {
        let size = CGSize(width: 1280, height: 960)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.systemTeal.setFill(); context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.08, green: 0.43, blue: 0.24, alpha: 1).setFill(); context.fill(CGRect(x: 240, y: 160, width: 800, height: 380))
            for (row, line) in ["人民路", "地铁站 200米"].enumerated() {
                (line as NSString).draw(at: CGPoint(x: 300, y: 220 + CGFloat(row) * 130),
                                        withAttributes: [.font: UIFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: UIColor.white])
            }
        }
        return try #require(image.jpegData(compressionQuality: 0.85))
    }

    private func check(_ service: PhotoChatService, key: String) async throws {
        let start = Date()
        let (surface, text) = try await TextReadingPrompt.remote(jpeg: try roadSign(), key: key, service: service)
        print("PRTS_REMOTE_OCR \(service.model) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(surface.rawValue) | \(text)")
        #expect(surface == .roadSign)
        #expect(text.contains("人民路") && text.contains("地铁站"))
    }

    @Test(.enabled(if: env["PRTS_QWEN_KEY"] != nil))
    func qwenReadsWithItsOCRModel() async throws { try await check(.qwen, key: Self.env["PRTS_QWEN_KEY"]!) }

    @Test(.enabled(if: env["PRTS_DEEPSEEK_KEY"] != nil))
    func deepseekReadsInOneRequest() async throws { try await check(.deepseek, key: Self.env["PRTS_DEEPSEEK_KEY"]!) }
}
