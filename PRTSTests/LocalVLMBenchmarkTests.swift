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

    private func run(quant: String) throws {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("vlm")
        let model = dir.appendingPathComponent("MiniCPM-V-4.6-\(quant).gguf").path
        let mmproj = dir.appendingPathComponent("mmproj-MiniCPM-V-4.6-F16.gguf").path
        guard FileManager.default.fileExists(atPath: model) else { return }
        var images = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".jpg") }.sorted().map { dir.appendingPathComponent($0).path }
        if let first = images.first { images.append(first) } // warm repeat of the first photo
        let cImages = images.map { strdup($0) }
        defer { cImages.forEach { free($0) } }
        let pointers = cImages.map { UnsafePointer<CChar>($0) }
        let json = pointers.withUnsafeBufferPointer { buffer in
            prts_vlm_bench(model, mmproj, buffer.baseAddress, Int32(images.count), PhotoChatProtocol.prompt, 128, 2048)
        }
        let report = String(cString: try #require(json))
        free(json)
        try report.write(to: dir.appendingPathComponent("result-\(quant).json"), atomically: true, encoding: .utf8)
        #expect(!report.contains("\"error\""))
    }
}
#endif
