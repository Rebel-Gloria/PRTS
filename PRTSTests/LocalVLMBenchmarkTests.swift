#if canImport(PRTSVLMBench)
import Foundation
import PRTSVLMBench
import Testing
@testable import PRTS

/// On-device MiniCPM-V speed/memory benchmark. Only compiled when the llama.cpp benchmark
/// library is linked (see docs/design/LOCAL_VLM_FEASIBILITY.md); models and photos are
/// copied to Documents/vlm beforehand, and the JSON report is written back there.
@MainActor
struct LocalVLMBenchmarkTests {
    @Test func benchQ4() throws { try run(quant: "Q4_K_M") }
    @Test func benchQ5() throws { try run(quant: "Q5_K_M") }

    /// Prompt comparison: every variant in Documents/vlm/prompts.json on the photos in vlm/clean.
    @Test func promptsQ5() throws {
        let variants = try loadVariants()
        let images = try photos(in: dir.appendingPathComponent("clean"))
        var reports: [String] = []
        for variant in variants {
            let json = try bench(quant: "Q5_K_M", images: images, system: variant.system, prompt: variant.user)
            reports.append("{\"name\":\"\(variant.name)\",\"report\":\(json)}")
        }
        try "[\(reports.joined(separator: ","))]".write(to: dir.appendingPathComponent("prompts-Q5_K_M.json"), atomically: true, encoding: .utf8)
    }

    /// The shipped prompt on photos in Documents/vlm/photos (already scaled like PhotoImageEncoder), twice: cold then warm.
    @Test func photosQ5() throws {
        let images = try photos(in: dir.appendingPathComponent("photos"))
        let report = try bench(quant: "Q5_K_M", images: images + images, system: PhotoChatProtocol.system, prompt: PhotoChatProtocol.prompt)
        try report.write(to: dir.appendingPathComponent("photos-Q5_K_M.json"), atomically: true, encoding: .utf8)
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

    private func run(quant: String) throws {
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("MiniCPM-V-4.6-\(quant).gguf").path) else { return }
        var images = try photos(in: dir)
        if let first = images.first { images.append(first) } // warm repeat of the first photo
        let report = try bench(quant: quant, images: images, system: PhotoChatProtocol.system, prompt: PhotoChatProtocol.prompt)
        try report.write(to: dir.appendingPathComponent("result-\(quant).json"), atomically: true, encoding: .utf8)
        #expect(!report.contains("\"error\""))
    }

    private func bench(quant: String, images: [String], system: String, prompt: String) throws -> String {
        let model = dir.appendingPathComponent("MiniCPM-V-4.6-\(quant).gguf").path
        let mmproj = dir.appendingPathComponent("mmproj-MiniCPM-V-4.6-F16.gguf").path
        let cImages = images.map { strdup($0) }
        defer { cImages.forEach { free($0) } }
        let pointers = cImages.map { UnsafePointer<CChar>($0) }
        let json = pointers.withUnsafeBufferPointer { buffer in
            prts_vlm_bench(model, mmproj, buffer.baseAddress, Int32(images.count), system, prompt, 128, 2048)
        }
        let report = String(cString: try #require(json))
        free(json)
        return report
    }
}
#endif
