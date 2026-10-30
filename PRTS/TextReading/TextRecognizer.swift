import CoreImage
import Vision

/// Apple's on-device text recognition: the fallback when the bundled model fails.
nonisolated enum TextRecognizer {
    /// Reads the whole photo. Used when the bundled model fails.
    static func read(_ image: CIImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(ciImage: image).perform([request])
        let lines = (request.results ?? []).compactMap { line in
            line.topCandidates(1).first.map { (box: line.boundingBox, text: $0.string) }
        }
        return joined(ordered(lines))
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
