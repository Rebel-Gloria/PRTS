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

    /// The cloud models keep a format, so they get both questions in one request: what the text is
    /// on in the first line, the copy below it.
    static let remoteSystem = """
    你帮盲人读出手机镜头前的文字。用户举着手机对着前方。
    按下面的格式回答，不要说别的：
    第一行只写一个词，说字写在什么上面：路标、牌子、纸张、物体，四选一。路名牌和方向指示是路标；店铺招牌和告示是牌子；纸和书是纸张；瓶子、包装、屏幕和其他东西是物体。
    从第二行起照抄文字：一字不差，保持原来的语言，不翻译、不总结、不描述画面；按阅读顺序，从上到下、从左到右；看不清的字直接跳过，不要猜。
    照片里没有能看清的文字时，只回答一个字：无。不写分类，不加括号说明。
    """
    static let remotePrompt = "读出照片里的文字。"

    /// For a dedicated OCR model, which copies text but does not keep the two-part format.
    static let ocrSystem = "你帮盲人读出手机镜头前的文字。照抄照片里的文字：一字不差，保持原来的语言，不翻译、不总结、不描述画面；按阅读顺序，从上到下、从左到右；看不清的字直接跳过，不要猜。照片里没有能看清的文字时，只回答一个字：无。"

    /// The cloud provider chosen for photo descriptions. With an OCR model (Qwen) its chat model
    /// says what the text is on while the OCR model copies it, both at once; otherwise one request
    /// asks for both.
    static func remote(jpeg: Data, key: String, service: PhotoChatService) async throws -> (Surface, String) {
        guard let ocrModel = service.ocrModel else {
            return split(try await PhotoChatClient().describe(jpeg: jpeg, text: remotePrompt, key: key, service: service, system: remoteSystem))
        }
        let ocr = PhotoChatService(endpoint: service.endpoint, model: ocrModel, thinking: .standard)
        // The chat model (qwen3.8-flash) judges the surface. qwen-plus is cheaper but cannot see
        // images; qwen3-vl-plus is a little faster but costs more.
        async let surface = PhotoChatClient().describe(jpeg: jpeg, text: surfaceQuestion, key: key, service: service, system: nil)
        async let text = PhotoChatClient().describe(jpeg: jpeg, text: remotePrompt, key: key, service: ocr, system: ocrSystem)
        return (Surface(answer: try await surface), try await text)
    }

    /// First line names the surface. A first line without one of the four words is already text.
    static func split(_ answer: String) -> (Surface, String) {
        let text = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = text.prefix { $0 != "\n" }
        guard let surface = Surface(word: String(head)) else { return (.object, text) }
        return (surface, String(text.dropFirst(head.count)))
    }

    enum Surface: String, CaseIterable {
        case roadSign = "路标", sign = "牌子", paper = "纸张", object = "物体"

        /// The first of the four words in the answer; anything else counts as an object.
        init(answer: String) { self = Surface(word: answer) ?? .object }

        init?(word: String) {
            guard let first = Self.allCases
                .compactMap({ surface in word.range(of: surface.rawValue).map { (surface, $0.lowerBound) } })
                .min(by: { $0.1 < $1.1 }) else { return nil }
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

/// Who reads the text. Settings → under the three-finger switch.
nonisolated enum TextReadingService: String, CaseIterable, Identifiable {
    case vision, onDevice, remote

    var id: String { rawValue }
    static let selectionKey = "ocr.service"

    /// The bundled model by default: it knows what the text is on, and needs no network.
    static func current(_ defaults: UserDefaults = .standard) -> TextReadingService {
        defaults.string(forKey: selectionKey).flatMap(TextReadingService.init(rawValue:)) ?? .onDevice
    }

    var localizationKey: String { "settings.ocr.service.\(rawValue)" }
}
