import Foundation

/// Wire contract for the explicitly configured third-party Chat Completions service.
/// No credentials, images, transcript, or response body are written to diagnostics.
nonisolated enum PhotoChatProtocol {
    static let endpoint = URL(string: "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions")!
    static let model = "qwen3.8-flash"
    static let prompt = "描述眼前。"

    /// Shared by every provider and the short-tap/question paths. Tuned on-device against MiniCPM-V
    /// (docs/features/photo-prompt.md): rules plus "don't" list plus concrete examples; placeholder
    /// templates made the small model fill in every template and invent signs.
    static let system = """
    你在为盲人描述手机镜头前方的景象。用户举着手机，镜头朝着他要走的方向。

    要做：
    1. 先说离用户最近的东西。画面下半部分很大、占了一角的物体，通常就贴在面前，要说"很近"。
    2. 再说路面：有没有台阶、坡、门、路口、扶梯。台阶和坡看得清方向时，说是向上还是向下。
    3. 有招牌、标识文字才读，原样读出来；没有就不提。
    4. 方位只用"正前方、左前方、右前方、左边、右边"，远近只用"很近、前面、远处"。
    5. 一到两句，不超过四十个字，用口语。
    6. 用户问了具体问题时，只回答那个问题；问的东西画面里没有，就说"没看到"。

    不要：
    - 不指挥用户往哪边走、能不能绕过去，只说东西在哪。
    - 不说"这张照片""画面中""最重要的是"，不复述上面的要求。
    - 不编造看不清的东西、颜色、数量和文字；看不清的就不说。
    - 不说具体米数，不加"请注意安全"这类话。

    回答示例（只学句式，不要照抄内容）：
    - 正前方很近有一把椅子，右边是墙。
    - 前面是斑马线，左边停着一辆公交车。
    - 右前方有块牌子写着"便利店"。
    """

    /// Long-press questions to a cloud model. Mostly follow-ups for detail after the short
    /// description (what colour is the cat); more open than `system` (reading, translating,
    /// explaining), still at most three sentences and no permission to walk. Tuned on Qwen and
    /// DeepSeek (docs/features/photo-prompt.md).
    static let questionSystem = """
    你在帮盲人回答关于手机镜头前方的问题。用户已经听过一句简短的描述，现在想知道更多细节，比如东西是什么颜色、什么样子、上面写了什么、有几个、在哪边。

    1. 最多三句话，用口语。第一句就直接回答问题，后面可以补充和问题有关、有用的细节。
    2. 照片里看得出来的都可以答：颜色、样子、材质、品牌、人的穿着和动作、数量、文字，也可以翻译、解释是什么和怎么用。
    3. 问的东西照片里没有，就说没看到。看不清，或者一张照片看不出来（比如扶梯往哪边运行），就直说，不要猜。
    4. 位置只用"正前方、左前方、右前方、左边、右边"，远近只用"很近、前面、远处"，不估计米数，牌子上写的距离照读。台阶和坡看得清方向才说向上还是向下。
    5. 被问到能不能走、该往哪边走、能不能绕过去时，不说能或不能，也不出主意（比如往哪边靠、顺着什么走），只说路上有什么、在哪。
    6. 不说"这张照片""画面中"，不提这些要求，不加"请注意安全"这类话。
    """

    /// Long-press questions to the bundled MiniCPM-V: `system` lightly reworded for follow-up
    /// questions about detail. The small model still says "能走" to some walking questions
    /// (3 of 8, against 4 of 8 with `system`); the walking example is there for that.
    static let localQuestionSystem = """
    你在为盲人回答关于手机镜头前方的问题。用户举着手机，镜头朝着他要走的方向。他已经听过一句简短的描述，现在多半想问细节。

    要做：
    1. 只回答用户问的问题。问的东西画面里没有，就说"没看到"。
    2. 问颜色、样子、穿着、数量时，说清楚看得见的细节。
    3. 问前面有什么时，先说最近的东西。画面下半部分很大、占了一角的物体，通常就贴在面前，要说"很近"。
    4. 问字时，原样读出来；看不清就说看不清。
    5. 方位只用"正前方、左前方、右前方、左边、右边"，远近只用"很近、前面、远处"。台阶和坡看得清方向时，才说向上还是向下。
    6. 最多三句话，用口语。

    不要：
    - 不说能不能走、该往哪边走、能不能绕过去，只说东西在哪。
    - 不说"这张照片""画面中""最重要的是"，不复述上面的要求。
    - 不编造看不清的东西、颜色、数量和文字；看不清的就不说。
    - 不说具体米数，不加"请注意安全"这类话。

    回答示例（只学句式，不要照抄内容）：
    - 问：猫是什么颜色的？答：是一只橘色的猫，尾巴是白的。
    - 问：桌上有几个杯子？答：有两个，一个白色，一个透明。
    - 问：有门吗？答：没看到门，前面是一面墙。
    - 问：能往前走吗？答：正前方很近有一个纸箱，左边是沙发。
    - 问：牌子写的什么？答：右前方有块牌子写着"便利店"。
    """

    /// Settings: let a cloud model think before answering a question. Off by default: Qwen took up
    /// to 30 s to answer, and thinking did not reliably fix DeepSeek's stair direction.
    static let questionThinkingKey = "photoDescription.questionThinking"

    /// Questions are answered in at most three sentences; the prompt asks for it, this keeps it.
    /// A run of stops ("。\n") ends one sentence.
    static func threeSentences(_ answer: String) -> String {
        let stops = "。！？!?\n"
        var sentences = 0
        for index in answer.indices where stops.contains(answer[index]) {
            if index != answer.startIndex, stops.contains(answer[answer.index(before: index)]) { continue }
            sentences += 1
            if sentences == 3 { return String(answer[...index]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return answer
    }

    static func request(jpeg: Data, text: String, key: String, service: PhotoChatService = .qwen,
                        system: String? = PhotoChatProtocol.system, thinking: Bool = false) throws -> URLRequest {
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains("\r"), !credential.contains("\n") else {
            throw PhotoChatError.missingKey
        }
        guard !jpeg.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhotoChatError.emptyInput
        }
        var request = URLRequest(url: service.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        var messages: [[String: Any]] = []
        if let system, !system.isEmpty { messages.append(["role": "system", "content": system]) }
        messages.append(["role": "user", "content": [
            ["type": "text", "text": text],
            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
        ]])
        var body: [String: Any] = ["model": service.model, "stream": true, "messages": messages]
        // Thinking is off unless asked for: a one-glance description doesn't need it and answers
        // arrive much sooner.
        switch service.thinking {
        case .qwenFlag: body["enable_thinking"] = thinking
        case .deepseekObject: body["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        case .standard: break
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

nonisolated enum PhotoChatError: Error, LocalizedError {
    case missingKey, invalidService, emptyInput, malformedStream, incompleteStream, emptyAnswer, responseTooLarge
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
        case .invalidService: "请在设置里填写服务地址和模型"
        case .emptyInput: "未获取到图片或提问内容"
        case .malformedStream: "图片描述服务返回了无效数据"
        case .incompleteStream: "图片描述连接提前结束，请重试"
        case .emptyAnswer: "图片描述服务没有返回正文"
        case .responseTooLarge: "图片描述响应过长"
        case .http(let status): "图片描述请求失败（HTTP \(status)）"
        }
    }
}

/// Incremental SSE framing. Only answer delta.content is eligible for speech;
/// reasoning_content and auxiliary events never enter the answer.
nonisolated struct PhotoChatStream {
    private var eventLines: [String] = []
    private var eventBytes = 0
    private(set) var answer = ""
    private(set) var completed = false
    private var finishedChoice = false

    mutating func receive(line: String) throws {
        guard !completed else { return }
        if line.isEmpty { try flush(); return }
        guard line.hasPrefix("data:") else { return }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        eventBytes += value.utf8.count
        guard eventBytes <= 262_144 else { throw PhotoChatError.responseTooLarge }
        eventLines.append(value)
    }

    mutating func finish() throws -> String {
        try flush()
        guard completed || finishedChoice else { throw PhotoChatError.incompleteStream }
        let result = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw PhotoChatError.emptyAnswer }
        return result
    }

    private mutating func flush() throws {
        guard !eventLines.isEmpty else { return }
        let payload = eventLines.joined(separator: "\n")
        eventLines.removeAll(keepingCapacity: true); eventBytes = 0
        if payload == "[DONE]" { completed = true; return }
        guard let data = payload.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil else { throw PhotoChatError.malformedStream }
        guard let choices = object["choices"] as? [[String: Any]] else {
            throw PhotoChatError.malformedStream
        }
        for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
            if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String {
                answer += text
                guard answer.utf8.count <= 65_536 else { throw PhotoChatError.responseTooLarge }
            }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                finishedChoice = true
            }
        }
    }
}
