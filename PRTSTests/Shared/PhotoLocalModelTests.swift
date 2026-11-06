import Foundation
import LocalVLM
import Testing
import UIKit

@testable import PRTS

/// The app caches its model for later requests; the test suite has a shorter, explicit lifetime.
/// Release native GPU buffers before XCTest exits and the backend destroys its global device.
nonisolated private struct LocalModelLifetime: SuiteTrait, TestScoping {
    var isRecursive: Bool { false }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        do {
            try await function()
        } catch {
            await PhotoLocalModel.shared.unload()
            throw error
        }
        await PhotoLocalModel.shared.unload()
    }
}

/// Runs the bundled offline model through the app's own describe path on real photos.
/// Device only: the photos are the ones the local VLM benchmark copied to Documents/vlm/photos/1280.
@MainActor @Suite(.serialized, LocalModelLifetime())
struct PhotoLocalModelTests {
    nonisolated static let photos = FileManager.default.urls(
        for: .documentDirectory,
        in: .userDomainMask
    )[0]
    .appendingPathComponent("vlm/photos/1280")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: photos.path)))
    func describesBundledPhotosOffline() async throws {
        let selectionKey = IntelligenceFeature.description.selectionKey
        let selection = UserDefaults.standard.object(forKey: selectionKey)
        UserDefaults.standard.set(PhotoChatProvider.onDevice.rawValue, forKey: selectionKey)
        defer { UserDefaults.standard.set(selection, forKey: selectionKey) }
        let services = PhotoDescriptionServices()
        let configuration = try services.configuration(.description)
        #expect(configuration.provider == .onDevice)
        let files = try FileManager.default.contentsOfDirectory(
            at: Self.photos,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "jpg" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(!files.isEmpty)
        for file in files {
            let start = Date()
            let answer = try await services.describe(
                try Data(contentsOf: file),
                nil,
                PhotoDescriptionRequest(configuration: configuration, key: "")
            )
            print(
                "PRTS_LOCAL_VLM \(file.lastPathComponent) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(answer)"
            )
            #expect(!answer.isEmpty)
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: photos.path)))
    func cancellationStopsGeneration() async throws {
        let file = try #require(
            try FileManager.default.contentsOfDirectory(
                at: Self.photos,
                includingPropertiesForKeys: nil
            )
            .first { $0.pathExtension == "jpg" }
        )
        let jpeg = try Data(contentsOf: file)
        let selectionKey = IntelligenceFeature.description.selectionKey
        let selection = UserDefaults.standard.object(forKey: selectionKey)
        UserDefaults.standard.set(PhotoChatProvider.onDevice.rawValue, forKey: selectionKey)
        defer { UserDefaults.standard.set(selection, forKey: selectionKey) }
        let services = PhotoDescriptionServices()
        let request = PhotoDescriptionRequest(
            configuration: try services.configuration(.description),
            key: ""
        )
        let task = Task { try await services.describe(jpeg, nil, request) }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// The bundled model reading text, through the same two questions as the app. Device only. Kept in
/// the serialized suite: a photo description between the two questions would change the photo.
extension PhotoLocalModelTests {
    @Test(
        .enabled(
            if: Bundle.main.url(
                forResource: "mmproj-model-f16",
                withExtension: "gguf",
                subdirectory: "LocalVLM"
            ) != nil
        )
    )
    func outputLimitAndUnloadDoNotPreventTheNextPhoto() async throws {
        let jpeg = try photo(["人民路"], background: .gray, card: .blue, ink: .white)
        let model = PhotoLocalModel.shared
        do {
            _ = try await model.describe(
                jpeg: jpeg,
                prompt: SceneDescriptionPrompt.request,
                system: PhotoPrompts.system,
                maxTokens: 1
            )
            Issue.record("A token-limited answer must not succeed")
        } catch LocalVLM.Failure.outputLimit {}
        do {
            _ = try await model.ask("继续描述", maxTokens: 0)
            Issue.record("A continuation without an output budget must not succeed")
        } catch LocalVLM.Failure.outputLimit {}
        let answer = try await model.describe(
            jpeg: jpeg,
            prompt: SceneDescriptionPrompt.request,
            system: PhotoPrompts.system
        )
        #expect(!answer.isEmpty)
        await model.unload()
        await model.unload()
        let reloaded = try await model.describe(
            jpeg: jpeg,
            prompt: SceneDescriptionPrompt.request,
            system: PhotoPrompts.system
        )
        #expect(reloaded == answer)
    }

    @Test(
        .enabled(
            if: Bundle.main.url(
                forResource: "mmproj-model-f16",
                withExtension: "gguf",
                subdirectory: "LocalVLM"
            ) != nil
        )
    )
    func surfaceOverItsBudgetStillLetsTheCopyRun() async throws {
        let jpeg = try photo(["人民路"], background: .gray, card: .blue, ink: .white)
        _ = try await TextReadingBackend.surface(of: jpeg, maxTokens: 1)
        let text = try await TextReadingBackend.copy { _ in }
        #expect(text.contains("人民路"))
    }

    private func photo(_ lines: [String], background: UIColor, card: UIColor, ink: UIColor) throws
        -> Data
    {
        let size = CGSize(width: 1280, height: 960)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            background.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            card.setFill()
            context.fill(
                CGRect(x: 240, y: 160, width: 800, height: 120 + CGFloat(lines.count) * 130)
            )
            for (row, line) in lines.enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 300, y: 220 + CGFloat(row) * 130),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: ink,
                    ]
                )
            }
        }
        return try #require(image.jpegData(compressionQuality: 0.85))
    }

    private func read(_ jpeg: Data) async throws -> (TextReadingAnswer.Surface, String) {
        let start = Date()
        let surface = try await TextReadingBackend.surface(of: jpeg)
        let text = try await TextReadingBackend.copy { _ in }
        print(
            "PRTS_OCR \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(surface.rawValue) | \(text)"
        )
        return (surface, text)
    }

    @Test(
        .enabled(
            if: Bundle.main.url(
                forResource: "mmproj-model-f16",
                withExtension: "gguf",
                subdirectory: "LocalVLM"
            ) != nil
        )
    )
    func readsARoadSignAndAShopSign() async throws {
        let road = try await read(
            photo(
                ["人民路", "地铁站 200米"],
                background: .systemTeal,
                card: UIColor(red: 0.08, green: 0.43, blue: 0.24, alpha: 1),
                ink: .white
            )
        )
        #expect(road.0 == .roadSign)
        #expect(road.1.contains("人民路") && road.1.contains("地铁站"))
        let shop = try await read(
            photo(
                ["幸福便利店", "24小时营业"],
                background: .lightGray,
                card: UIColor(red: 0.8, green: 0.1, blue: 0.12, alpha: 1),
                ink: .white
            )
        )
        #expect(shop.0 == .sign)
        #expect(shop.1.contains("幸福便利店"))
    }

    @Test(
        .enabled(
            if: Bundle.main.url(
                forResource: "mmproj-model-f16",
                withExtension: "gguf",
                subdirectory: "LocalVLM"
            ) != nil
        )
    )
    func saysNoneWithoutText() async throws {
        let blank = try await read(photo([], background: .brown, card: .darkGray, ink: .white))
        #expect(blank.1.trimmingCharacters(in: .punctuationCharacters) == TextReadingPrompt.none)
    }

    @Test(
        .enabled(
            if: Bundle.main.url(
                forResource: "mmproj-model-f16",
                withExtension: "gguf",
                subdirectory: "LocalVLM"
            ) != nil
        )
    )
    func answersAQuestionOffline() async throws {
        let selectionKey = IntelligenceFeature.question.selectionKey
        let selection = UserDefaults.standard.object(forKey: selectionKey)
        UserDefaults.standard.set(PhotoChatProvider.onDevice.rawValue, forKey: selectionKey)
        defer { UserDefaults.standard.set(selection, forKey: selectionKey) }
        let jpeg = try photo(
            ["人民路", "地铁站 200米"],
            background: .systemTeal,
            card: UIColor(red: 0.08, green: 0.43, blue: 0.24, alpha: 1),
            ink: .white
        )
        let start = Date()
        let services = PhotoDescriptionServices()
        let request = PhotoDescriptionRequest(
            configuration: try services.configuration(.question),
            key: ""
        )
        let answer = try await services.describe(jpeg, "牌子上写的什么？", request)
        print(
            "PRTS_LOCAL_QUESTION \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(answer)"
        )
        #expect(answer.contains("人民路"))
        #expect(answer == PhotoPrompts.threeSentences(answer))
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
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.08, green: 0.43, blue: 0.24, alpha: 1).setFill()
            context.fill(CGRect(x: 240, y: 160, width: 800, height: 380))
            for (row, line) in ["人民路", "地铁站 200米"].enumerated() {
                (line as NSString).draw(
                    at: CGPoint(x: 300, y: 220 + CGFloat(row) * 130),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 88, weight: .bold),
                        .foregroundColor: UIColor.white,
                    ]
                )
            }
        }
        return try #require(image.jpegData(compressionQuality: 0.85))
    }

    private func check(_ service: PhotoChatService, key: String) async throws {
        let start = Date()
        let (surface, text) = try await TextReadingBackend.remote(
            jpeg: try roadSign(),
            key: key,
            service: service
        )
        print(
            "PRTS_REMOTE_OCR \(service.model) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(surface.rawValue) | \(text)"
        )
        #expect(surface == .roadSign)
        #expect(text.contains("人民路") && text.contains("地铁站"))
    }

    @Test(.enabled(if: env["PRTS_QWEN_KEY"] != nil))
    func qwenReadsInOneRequest() async throws {
        try await check(.qwen, key: Self.env["PRTS_QWEN_KEY"]!)
    }

    @Test(.enabled(if: env["PRTS_QWEN_KEY"] != nil))
    func qwenOmniReadsInOneRequest() async throws {
        try await check(.qwenOmni, key: Self.env["PRTS_QWEN_KEY"]!)
    }

    @Test(.enabled(if: env["PRTS_DEEPSEEK_KEY"] != nil))
    func deepseekReadsInOneRequest() async throws {
        try await check(.deepseek, key: Self.env["PRTS_DEEPSEEK_KEY"]!)
    }

    /// The real request shape: a full-length video of a block crossing the frame. An answer over
    /// the token budget throws here, which would mean thinking stayed on.
    @Test(.enabled(if: env["PRTS_QWEN_KEY"] != nil))
    func qwenCaptionsAVideoWithinItsTokenBudget() async throws {
        let key = Self.env["PRTS_QWEN_KEY"]!
        let size = CGSize(width: 720, height: 960)
        let video = try (0..<LiveCaptionPolicy.maximumVideoFrames).map { index in
            let image = UIGraphicsImageRenderer(size: size).image { context in
                UIColor.lightGray.setFill()
                context.fill(CGRect(origin: .zero, size: size))
                UIColor.black.setFill()
                context.fill(CGRect(x: index * 60, y: 320, width: 100, height: 320))
            }
            return try #require(image.jpegData(compressionQuality: 0.8))
        }
        for omni in [false, true] {
            UserDefaults.standard.set(omni, forKey: PhotoChatProvider.qwenOmniKey)
            defer { UserDefaults.standard.removeObject(forKey: PhotoChatProvider.qwenOmniKey) }
            let opening = try await LiveCaptionBackend.captionOpening(jpeg: video[0], key: key)
            #expect(!opening.isEmpty)
            let start = Date()
            let caption = try await LiveCaptionBackend.caption(
                video: video,
                previous: nil,
                key: key
            )
            print(
                "PRTS_CAPTION omni=\(omni) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(opening) | \(caption)"
            )
            #expect(!caption.isEmpty)
        }
    }

    /// A question with the question prompt, thinking off and on.
    private func ask(_ service: PhotoChatService, key: String) async throws {
        for thinking in [false, true] {
            let start = Date()
            let answer = try await PhotoChatClient().describe(
                jpeg: try roadSign(),
                text: "地铁站有多远？",
                key: key,
                service: service,
                system: PhotoPrompts.questionSystem,
                thinking: thinking
            )
            print(
                "PRTS_REMOTE_QUESTION \(service.model) thinking=\(thinking) \(String(format: "%.2f", Date().timeIntervalSince(start))) s: \(answer)"
            )
            #expect(answer.contains("200"))
        }
    }

    @Test(.enabled(if: env["PRTS_QWEN_KEY"] != nil))
    func qwenAnswersAQuestion() async throws {
        try await ask(.qwen, key: Self.env["PRTS_QWEN_KEY"]!)
        try await ask(.qwenOmni, key: Self.env["PRTS_QWEN_KEY"]!)
    }

    @Test(.enabled(if: env["PRTS_DEEPSEEK_KEY"] != nil))
    func deepseekAnswersAQuestion() async throws {
        try await ask(.deepseek, key: Self.env["PRTS_DEEPSEEK_KEY"]!)
    }
}
