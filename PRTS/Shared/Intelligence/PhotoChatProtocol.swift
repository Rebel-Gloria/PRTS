import Foundation

/// Wire contract for the explicitly configured third-party Chat Completions service.
/// No credentials, images, transcript, or response body are written to diagnostics.
nonisolated enum PhotoChatProtocol {
    static let endpoint = URL(
        string: "https://maas.qianwenaiapi.com/compatible-mode/v1/chat/completions"
    )!
    static let model = "qwen3.8-flash"
    static func request(
        jpeg: Data,
        text: String,
        key: String,
        service: PhotoChatService = .qwen,
        system: String? = PhotoPrompts.system,
        thinking: Bool = false,
        maxTokens: Int? = nil
    ) throws -> URLRequest {
        guard !jpeg.isEmpty else { throw PhotoChatError.emptyInput }
        return try request(
            content: [
                ["type": "text", "text": text],
                ["type": "image_url", "image_url": ["url": dataURL(jpeg)]],
            ],
            text: text,
            key: key,
            service: service,
            system: system,
            thinking: thinking,
            maxTokens: maxTokens
        )
    }

    static func dataURL(_ jpeg: Data) -> String {
        "data:image/jpeg;base64,\(jpeg.base64EncodedString())"
    }

    static func request(
        content: [[String: Any]],
        text: String,
        key: String,
        service: PhotoChatService,
        system: String?,
        thinking: Bool,
        maxTokens: Int?
    ) throws -> URLRequest {
        let credential = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !credential.isEmpty, !credential.contains("\r"), !credential.contains("\n") else {
            throw PhotoChatError.missingKey
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        messages.append(["role": "user", "content": content])
        var body: [String: Any] = ["model": service.model, "stream": true, "messages": messages]
        // Thinking is off unless asked for: a one-glance description doesn't need it and answers
        // arrive much sooner.
        switch service.thinking {
        case .qwenFlag: body["enable_thinking"] = thinking
        case .deepseekObject: body["thinking"] = ["type": thinking ? "enabled" : "disabled"]
        case .standard: break
        }
        if let maxTokens { body["max_tokens"] = maxTokens }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}
