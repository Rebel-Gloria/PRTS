import Foundation

/// Wire contract for the explicitly configured third-party Chat Completions service.
/// No credentials, images, transcript, or response body are written to diagnostics.
nonisolated enum PhotoChatProtocol {
    static let endpoint = URL(string: "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions")!
    static let model = "qwen3.8-flash"
    static let prompt = "请面向盲人，用简短、凝练、易理解的语言描述这张图片。重点说明图片中的主要物体、人物或场景，以及它们之间的空间位置、方向、距离和几何关系。不要加入无关细节控制在一句到两句话内。"

    /// Applied only to a completed long-press transcript; short taps keep `prompt`.
    static let spokenQuestionPrefix = "请面向盲人，用简短、凝练、易理解的语言回答用户提出的请求，内容如下："

    static func request(jpeg: Data, text: String, key: String) throws -> URLRequest {
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains("\r"), !credential.contains("\n") else {
            throw PhotoChatError.missingKey
        }
        guard !jpeg.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PhotoChatError.emptyInput
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "stream": true, "enable_thinking": true,
            "messages": [["role": "user", "content": [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
            ]]]
        ])
        return request
    }
}

nonisolated enum PhotoChatError: Error, LocalizedError {
    case missingKey, emptyInput, malformedStream, incompleteStream, emptyAnswer, responseTooLarge
    case http(Int)
    var errorDescription: String? {
        switch self {
        case .missingKey: "请先在设置中保存 API Key"
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
