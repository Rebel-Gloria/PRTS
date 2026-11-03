import Foundation
import Vision

/// All passes share the synchronous Vision executor, including passes still stopping.
nonisolated final class LiveCaptionFeatureGenerator: Sendable {
    static let shared = LiveCaptionFeatureGenerator()
    private let queue = DispatchQueue(label: "PRTS.LiveCaption.Vision", qos: .userInitiated)

    func generate(
        _ jpeg: Data,
        extract: @escaping @Sendable (Data) throws -> VNFeaturePrintObservation
    ) async throws -> VNFeaturePrintObservation {
        let cancellation = LiveCaptionFeatureCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { done in
                queue.async {
                    done.resume(
                        with: Result {
                            try cancellation.check()
                            return try extract(jpeg)
                        }
                    )
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    nonisolated static func extract(_ jpeg: Data) throws -> VNFeaturePrintObservation {
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(data: jpeg).perform([request])
        guard let feature = request.results?.first else { throw NoFeaturePrint() }
        return feature
    }

    struct NoFeaturePrint: Error {}
}

actor LiveCaptionImageComparison {
    // Initial product requirement value; device measurements will tune this threshold.
    static let changeThreshold: Float = 0.4
    private var previous: VNFeaturePrintObservation?
    private let extract: @Sendable (Data) throws -> VNFeaturePrintObservation

    init(
        extract: @escaping @Sendable (Data) throws -> VNFeaturePrintObservation =
            LiveCaptionFeatureGenerator.extract
    ) {
        self.extract = extract
    }

    func accept(_ jpeg: Data) async throws -> Bool {
        let current = try await LiveCaptionFeatureGenerator.shared.generate(jpeg, extract: extract)
        try Task.checkCancellation()
        if let previous {
            var distance: Float = 0
            try current.computeDistance(&distance, to: previous)
            if distance < Self.changeThreshold { return false }
        }
        previous = current
        return true
    }
}

nonisolated private final class LiveCaptionFeatureCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }

    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
