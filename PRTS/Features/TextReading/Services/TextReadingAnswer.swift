import Foundation

/// Turns the streamed copy into what is spoken: "你面前的路标上写着：" with the first line, then
/// each further line or sentence as soon as it is complete, so speech starts before the model ends.
nonisolated struct TextReadingAnswer {
    /// "你面前的路标上写着".
    let lead: String
    private var buffer = ""
    private var closed = false
    private var noText = false
    private(set) var spokeText = false

    init(lead: String) { self.lead = lead }

    mutating func append(_ piece: String) -> [String] {
        guard !closed else { return [] }
        buffer += piece
        // A stray tag means the model started making up another turn; nothing after it is text.
        if let tag = buffer.firstIndex(of: "<") {
            buffer = String(buffer[..<tag])
            closed = true
        }
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
        let rest = buffer
        buffer = ""
        closed = true
        return say(rest)
    }

    private mutating func say(_ part: String) -> [String] {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !noText else { return [] }
        if spokeText { return [text] }
        // "无" first means there is no text at all; the model is not asked to go on after it.
        guard text.trimmingCharacters(in: .punctuationCharacters) != TextReadingPrompt.none else {
            noText = true
            return []
        }
        spokeText = true
        return ["\(lead)：\(text)"]
    }

    /// First line names the surface. A first line without one of the four words is already text.
    static func split(_ answer: String) -> (Surface, String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = text.prefix { $0 != "\n" }
        guard let surface = Surface(word: String(head)) else { return (.object, text) }
        return (surface, String(text.dropFirst(head.count)))
    }

    enum Surface: String, CaseIterable {
        case roadSign = "路标"
        case sign = "牌子"
        case paper = "纸张"
        case object = "物体"

        /// The first of the four words in the answer; anything else counts as an object.
        init(answer: String) { self = Surface(word: answer) ?? .object }

        init?(word: String) {
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
