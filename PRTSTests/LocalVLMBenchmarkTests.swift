#if canImport(PRTSVLMBench)
import Foundation
import PRTSVLMBench
import Testing
@testable import PRTS

/// On-device local VLM speed/memory benchmark. Only compiled when the llama.cpp benchmark
/// library is linked (see docs/design/LOCAL_VLM_FEASIBILITY.md). Each model lives in its own
/// Documents/vlm/models/<name>/ folder (language model + a file with "mmproj" in its name);
/// photos and prompts are copied to Documents/vlm beforehand, and JSON reports are written back there.
@MainActor
struct LocalVLMBenchmarkTests {
    /// The shipped prompt on Documents/vlm/photos/1280; the first photo runs once more to warm up.
    @Test func photos() throws {
        try eachModel("photos") { model, mmproj in
            let images = try photos(in: dir.appendingPathComponent("photos/1280"))
            return try bench(model: model, mmproj: mmproj, images: [images[0]] + images,
                             system: PhotoChatProtocol.system, prompt: PhotoChatProtocol.prompt, nCtx: 4096)
        }
    }

    /// Same, letting the model think before answering.
    @Test func photosThinking() throws {
        try eachModel("photos-thinking") { model, mmproj in
            let images = try photos(in: dir.appendingPathComponent("photos/1280"))
            return try bench(model: model, mmproj: mmproj, images: [images[0]] + images,
                             system: PhotoChatProtocol.system, prompt: PhotoChatProtocol.prompt,
                             maxTokens: 1024, nCtx: 4096, thinking: true)
        }
    }

    /// Prompt comparison: every variant in Documents/vlm/prompts.json on the photos in vlm/clean.
    @Test func prompts() throws {
        let variants = try loadVariants()
        try eachModel("prompts") { model, mmproj in
            let images = try photos(in: dir.appendingPathComponent("clean"))
            var reports: [String] = []
            for variant in variants {
                let json = try bench(model: model, mmproj: mmproj, images: images, system: variant.system, prompt: variant.user)
                reports.append("{\"name\":\"\(variant.name)\",\"report\":\(json)}")
            }
            return "[\(reports.joined(separator: ","))]"
        }
    }

    /// Same variants against every cloud provider that has a key saved in Settings.
    @Test func promptsCloud() async throws {
        let variants = try loadVariants()
        let images = try photos(in: dir.appendingPathComponent("clean"))
        var rows: [[String: Any]] = []
        for provider in PhotoChatProvider.allCases {
        guard let key = try? PhotoCredentialStore.read(account: provider.keyAccount), provider.service() != nil else { continue }
        for variant in variants {
            for image in images {
                let start = Date()
                let answer: String
                do {
                    answer = try await PhotoChatClient().describe(
                        jpeg: try Data(contentsOf: URL(fileURLWithPath: image)), text: variant.user, key: key,
                        service: provider.service(), system: variant.system.isEmpty ? nil : variant.system)
                } catch { answer = "ERROR: \(error)" }
                rows.append(["provider": provider.rawValue, "name": variant.name, "image": (image as NSString).lastPathComponent,
                             "total_ms": Int(Date().timeIntervalSince(start) * 1000), "answer": answer])
            }
        }
        }
        let data = try JSONSerialization.data(withJSONObject: ["runs": rows])
        try data.write(to: dir.appendingPathComponent("prompts-cloud.json"))
    }

    private var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("vlm")
    }

    private struct Variant: Decodable { let name: String; let system: String; let user: String }

    private func loadVariants() throws -> [Variant] {
        try JSONDecoder().decode([Variant].self, from: Data(contentsOf: dir.appendingPathComponent("prompts.json")))
    }

    private func photos(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".jpg") }.sorted().map { folder.appendingPathComponent($0).path }
    }

    /// Runs body for every model folder and writes "<report>-<model>.json".
    private func eachModel(_ report: String, _ body: (String, String) throws -> String) throws {
        let root = dir.appendingPathComponent("models")
        for name in try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() {
            let folder = root.appendingPathComponent(name)
            let files = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".gguf") }
            let mmproj = try #require(files.first { $0.contains("mmproj") })
            let model = try #require(files.first { !$0.contains("mmproj") })
            let json = try body(folder.appendingPathComponent(model).path, folder.appendingPathComponent(mmproj).path)
            try json.write(to: dir.appendingPathComponent("\(report)-\(name).json"), atomically: true, encoding: .utf8)
        }
    }

    private func bench(model: String, mmproj: String, images: [String], system: String, prompt: String,
                       maxTokens: Int32 = 128, nCtx: Int32 = 2048, thinking: Bool = false) throws -> String {
        let cImages = images.map { strdup($0) }
        defer { cImages.forEach { free($0) } }
        let pointers = cImages.map { UnsafePointer<CChar>($0) }
        let json = pointers.withUnsafeBufferPointer { buffer in
            prts_vlm_bench(model, mmproj, buffer.baseAddress, Int32(images.count), system, prompt, maxTokens, nCtx, thinking ? 1 : 0)
        }
        let report = String(cString: try #require(json))
        free(json)
        return report
    }
}
#endif
