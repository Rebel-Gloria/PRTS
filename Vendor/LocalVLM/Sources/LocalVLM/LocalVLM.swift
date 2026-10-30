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

    /// Greedy decoding, so the same photo and prompt give the same answer. `onText` gets the
    /// answer piece by piece while it is generated, on the model's queue.
    public func describe(jpeg: Data, prompt: String, system: String, maxTokens: Int = 160,
                         onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(onText: onText) { handle, cancel, textFn, user, answer in
            jpeg.withUnsafeBytes { bytes in
                prts_vlm_describe(handle, bytes.bindMemory(to: UInt8.self).baseAddress, jpeg.count,
                                  system, prompt, Int32(maxTokens), cancel, textFn, user, answer)
            }
        }
    }

    /// A follow-up question about the photo of the last `describe`; the photo is not looked at again.
    public func ask(_ prompt: String, maxTokens: Int = 160,
                    onText: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await run(onText: onText) { handle, cancel, textFn, user, answer in
            prts_vlm_continue(handle, prompt, Int32(maxTokens), cancel, textFn, user, answer)
        }
    }

    private typealias Call = (OpaquePointer?, UnsafeMutablePointer<Int32>, prts_vlm_text_fn?, UnsafeMutableRawPointer?,
                              UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> prts_vlm_status

    private func run(onText: (@Sendable (String) -> Void)?, _ call: @escaping Call) async throws -> String {
        let cancel = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cancel.initialize(to: 0)
        defer { cancel.deallocate() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result { try self.call(call, cancel: cancel, onText: onText) })
                }
            }
        } onCancel: {
            cancel.pointee = 1
        }
    }

    private func call(_ call: Call, cancel: UnsafeMutablePointer<Int32>, onText: (@Sendable (String) -> Void)?) throws -> String {
        if handle == nil {
            handle = prts_vlm_open(model.path, mmproj.path, 4096)
            guard handle != nil else { throw Failure.loadFailed }
        }
        var answer: UnsafeMutablePointer<CChar>?
        let sink = onText.map { Unmanaged.passRetained(TextSink($0)) }
        defer { sink?.release() }
        let textFn: prts_vlm_text_fn? = sink == nil ? nil : { user, text, count in
            let sink = Unmanaged<TextSink>.fromOpaque(user!).takeUnretainedValue()
            sink.send(String(decoding: UnsafeRawBufferPointer(start: text, count: count), as: UTF8.self))
        }
        switch call(handle, cancel, textFn, sink?.toOpaque(), &answer) {
        case PRTS_VLM_OK:
            defer { free(answer) }
            return String(cString: answer!).trimmingCharacters(in: .whitespacesAndNewlines)
        case PRTS_VLM_CANCELLED: throw CancellationError()
        case PRTS_VLM_BAD_IMAGE: throw Failure.badImage
        default: throw Failure.evalFailed
        }
    }
}

private final class TextSink {
    let send: @Sendable (String) -> Void
    init(_ send: @escaping @Sendable (String) -> Void) { self.send = send }
}
