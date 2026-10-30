import Foundation
import LocalVLM

/// Reading text with the bundled MiniCPM-V 4.7: two questions about one photo, tuned on the Mac
/// harness (docs/features/text-reading.md). Asked in one go ("say what it is on, then copy it") the
/// small model ignored the format; asked one after the other it gets both right.
nonisolated enum TextReadingPrompt {
    static let system = """
    你帮盲人读出手机镜头前的文字。用户举着手机对着前方。
    回答要短，不描述画面，不解释。照抄文字时：
    1. 一字不差，保持原来的语言，不翻译、不总结。
    2. 按阅读顺序：从上到下，从左到右，标题也要抄。
    3. 看不清的字不要猜，直接跳过。
    4. 只输出文字本身，不加"上面写着"这类话。
    """

    /// First question: what the text is on. Rules sit in the question; in the system message the
    /// model mixed up road signs and shop signs.
    static let surfaceQuestion = "这些字写在什么上面？只回答一个词：路标、牌子、纸张、物体。路名牌和方向指示是路标；店铺招牌和告示是牌子；纸和书是纸张；瓶子、包装、屏幕和其他东西是物体。没有字就回答：无。"

    /// Second question, about the same photo. "照片里的" matters: "上面的文字" made it copy the question.
    static let copyQuestion = "照抄照片里的文字。照片里没有文字就只回答：无。"

    /// The model's word for "no text".
    static let none = "无"

    /// About a page of text.
    static let maxTokens = 400

    /// First question: looks at the photo (the slow part, about 1.3 s) and says what the text is on.
    static func surface(of jpeg: Data) async throws -> Surface {
        Surface(answer: try await PhotoLocalModel.shared.describe(jpeg: jpeg, prompt: surfaceQuestion, system: system, maxTokens: 8))
    }

    /// Second question about the photo `surface(of:)` just looked at; the copy streams into `onText`.
    static func copy(onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try await PhotoLocalModel.shared.ask(copyQuestion, maxTokens: maxTokens, onText: onText)
    }

    enum Surface: String, CaseIterable {
        case roadSign = "路标", sign = "牌子", paper = "纸张", object = "物体"

        /// The first of the four words in the answer; anything else counts as an object.
        init(answer: String) {
            self = Self.allCases
                .compactMap { surface in answer.range(of: surface.rawValue).map { (surface, $0.lowerBound) } }
                .min { $0.1 < $1.1 }?.0 ?? .object
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
        if let tag = buffer.firstIndex(of: "<") { buffer = String(buffer[..<tag]); closed = true }
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
        buffer = ""; closed = true
        return say(rest)
    }

    private mutating func say(_ part: String) -> [String] {
        let text = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !noText else { return [] }
        if spokeText { return [text] }
        // "无" first means there is no text at all; the model is not asked to go on after it.
        guard text.trimmingCharacters(in: .punctuationCharacters) != TextReadingPrompt.none else { noText = true; return [] }
        spokeText = true
        return ["\(lead)：\(text)"]
    }
}
