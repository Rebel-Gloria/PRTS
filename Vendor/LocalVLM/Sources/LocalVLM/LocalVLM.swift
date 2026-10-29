import Foundation
import CPRTSLocalVLM

/// MiniCPM-V 4.7 running on the phone. The model loads on first use (about 3 s) and stays loaded,
/// so later photos take about 2 s. Calls run one at a time on a private queue.
public final class LocalVLM: @unchecked Sendable {
    public enum Failure: Error { case loadFailed, badImage, evalFailed }

    private let model: URL
    private let mmproj: URL
    private let queue = DispatchQueue(label: "LocalVLM", qos: .userInitiated)
    private var handle: OpaquePointer?  // touched only on `queue`

    public init(model: URL, mmproj: URL) {
        self.model = model
        self.mmproj = mmproj
    }

    /// Greedy decoding, so the same photo and prompt give the same answer.
    public func describe(jpeg: Data, prompt: String, system: String, maxTokens: Int = 160) async throws -> String {
        let cancel = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancel.initialize(to: 0)
        defer { cancel.deallocate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try self.run(jpeg: jpeg, prompt: prompt, system: system, maxTokens: maxTokens, cancel: cancel)
                    })
                }
            }
        } onCancel: {
            cancel.pointee = 1
        }
    }

    private func run(jpeg: Data, prompt: String, system: String, maxTokens: Int,
                     cancel: UnsafeMutablePointer<Int32>) throws -> String {
        if handle == nil {
            handle = prts_vlm_open(model.path, mmproj.path, 4096)
            guard handle != nil else { throw Failure.loadFailed }
        }
        var answer: UnsafeMutablePointer<CChar>?
        let status = jpeg.withUnsafeBytes { bytes in
            prts_vlm_describe(handle, bytes.bindMemory(to: UInt8.self).baseAddress, jpeg.count,
                              system, prompt, Int32(maxTokens), cancel, &answer)
        }
        switch status {
        case PRTS_VLM_OK:
            defer { free(answer) }
            return String(cString: answer!).trimmingCharacters(in: .whitespacesAndNewlines)
        case PRTS_VLM_CANCELLED: throw CancellationError()
        case PRTS_VLM_BAD_IMAGE: throw Failure.badImage
        default: throw Failure.evalFailed
        }
    }
}
