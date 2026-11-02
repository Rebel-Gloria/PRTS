import Foundation
import Vision

/// Vision work runs on this actor while the main actor handles input and speech.
actor LiveCaptionImageComparison {
    // Initial product requirement value; device measurements will tune this threshold.
    static let changeThreshold: Float = 0.4
    private var previous: VNFeaturePrintObservation?

    func accept(_ jpeg: Data) throws -> Bool {
        try Task.checkCancellation()
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        try VNImageRequestHandler(data: jpeg).perform([request])
        let current = request.results![0]
        if let previous {
            var distance: Float = 0
            try current.computeDistance(&distance, to: previous)
            if distance < Self.changeThreshold { return false }
        }
        previous = current
        return true
    }
}
