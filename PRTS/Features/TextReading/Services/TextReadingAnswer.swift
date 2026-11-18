import Foundation

/// Turns the streamed copy into what is spoken: "你面前的路标上写着：" with the first line, then
/// each further line or sentence as soon as it is complete, so speech starts before the model ends.
nonisolated struct TextReadingAnswer {
    /// "你面前的路标上写着".
    let lead: String
    private var buffer = ""
    private var closed = false
    private let expectsModelEmptyMarker: Bool
    private(set) var spokeText = false

    init(lead: String, expectsModelEmptyMarker: Bool = false) {
        self.lead = lead
        self.expectsModelEmptyMarker = expectsModelEmptyMarker
    }

    // A streamed marker can still turn out to be the first line of a longer transcription.
    private var pendingEmptyMarker: Bool {
        guard expectsModelEmptyMarker, !spokeText else { return false }
        let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == TextReadingPrompt.none || text == TextReadingPrompt.none + "。"
    }

    mutating func append(_ piece: String) -> [String] {
        guard !closed else { return [] }
        buffer += piece
        if pendingEmptyMarker { return [] }
        var spoken: [String] = []
        while let end = buffer.firstIndex(where: { "\n。！？；!?".contains($0) }) {
            let next = buffer.index(after: end)
            spoken += say(String(buffer[..<next]))
            buffer = String(buffer[next...])
        }
        return spoken
    }

    /// Whatever is left once the model is done.
    mutating func finish() -> [String] {
        let rest = pendingEmptyMarker ? "" : buffer
        buffer = ""
        closed = true
        return say(rest)
    }

    private mutating func say(_ part: String) -> [String] {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        if spokeText { return [text] }
        spokeText = true
        return ["\(lead)：\(text)"]
    }

    enum Surface: String, CaseIterable {
        case roadSign = "路标"
        case sign = "牌子"
        case paper = "纸张"
        case object = "物体"

        /// The first of the four words in the answer; anything else counts as an object.
        init(answer: String) { self = Surface(word: answer) ?? .object }

        private init?(word: String) {
            guard
                let first = Self.allCases
                    .compactMap({ surface in
                        word.range(of: surface.rawValue).map { (surface, $0.lowerBound) }
                    })
                    .min(by: { $0.1 < $1.1 })
            else { return nil }
            self = first.0
        }

        var localizationKey: String {
            switch self {
            case .roadSign: "ocr.lead.roadSign"
            case .sign: "ocr.lead.sign"
            case .paper: "ocr.lead.paper"
            case .object: "ocr.lead.object"
            }
        }
    }
}
