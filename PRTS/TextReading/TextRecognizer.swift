import CoreImage
import Vision

/// Apple's on-device document outline, perspective correction and text recognition; no model is shipped.
nonisolated enum TextRecognizer {
    /// Normalized corners (top-left, top-right, bottom-right, bottom-left), origin top-left.
    static func documentCorners(in image: CIImage) throws -> [CGPoint]? {
        let request = VNDetectDocumentSegmentationRequest()
        try VNImageRequestHandler(ciImage: image).perform([request])
        guard let page = request.results?.first else { return nil }
        return [page.topLeft, page.topRight, page.bottomRight, page.bottomLeft].map { CGPoint(x: $0.x, y: 1 - $0.y) }
    }

    /// Reads the page inside corners (flattened first), or the whole image when there is no page.
    static func read(_ image: CIImage, corners: [CGPoint]?) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(ciImage: corners.map { flattened(image, corners: $0) } ?? image).perform([request])
        let lines = (request.results ?? []).compactMap { line in
            line.topCandidates(1).first.map { (box: line.boundingBox, text: $0.string) }
        }
        return joined(ordered(lines))
    }

    static func flattened(_ image: CIImage, corners: [CGPoint]) -> CIImage {
        let e = image.extent
        func point(_ p: CGPoint) -> CIVector { CIVector(x: e.minX + p.x * e.width, y: e.minY + (1 - p.y) * e.height) }
        return image.applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": point(corners[0]), "inputTopRight": point(corners[1]),
            "inputBottomRight": point(corners[2]), "inputBottomLeft": point(corners[3]),
        ])
    }

    /// Top-to-bottom rows, left-to-right within a row. Boxes are Vision's (origin bottom-left).
    static func ordered(_ lines: [(box: CGRect, text: String)]) -> [String] {
        var rows: [[(box: CGRect, text: String)]] = []
        for line in lines.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let first = rows.last?.first, abs(first.box.midY - line.box.midY) < min(first.box.height, line.box.height) / 2 {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.flatMap { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text) }
    }

    /// Chinese lines wrap mid-sentence, so they join directly; anything else gets a space.
    static func joined(_ lines: [String]) -> String {
        lines.reduce("") { text, line in
            guard let last = text.unicodeScalars.last, let first = line.unicodeScalars.first else { return text + line }
            return text + (isCJK(last) && isCJK(first) ? "" : " ") + line
        }
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(scalar.value) || (0x3000...0x303F).contains(scalar.value) || (0xFF00...0xFFEF).contains(scalar.value)
    }
}
