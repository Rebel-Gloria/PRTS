import Foundation

/// Wire contract for the explicitly configured third-party Chat Completions service.
/// No credentials, images, transcript, or response body are written to diagnostics.
nonisolated enum PhotoChatProtocol {
    static let endpoint = URL(string: "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions")!
    static let model = "qwen3.8-flash"
    static let prompt = "描述眼前。"

    /// Shared by every provider and the short-tap/question paths. Tuned on-device against MiniCPM-V
    /// (docs/design/PHOTO_PROMPT.md): rules plus "don't" list plus concrete examples; placeholder
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

    /// Applied only to a completed long-press transcript; short taps keep `prompt`.
    static let spokenQuestionPrefix = "简短回答盲人的问题："

    static func request(jpeg: Data, text: String, key: String, service: PhotoChatService = .qwen,
                        system: String? = PhotoChatProtocol.system) throws -> URLRequest {
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
        // Thinking is off: a one-glance description doesn't need it and answers arrive much sooner.
        switch service.thinking {
        case .qwenFlag: body["enable_thinking"] = false
        case .deepseekObject: body["thinking"] = ["type": "disabled"]
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
