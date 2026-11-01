import Foundation

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
        if line.isEmpty {
            try flush()
            return
        }
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
        eventLines.removeAll(keepingCapacity: true)
        eventBytes = 0
        if payload == "[DONE]" {
            completed = true
            return
        }
        guard let data = payload.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["error"] == nil
        else { throw PhotoChatError.malformedStream }
        guard let choices = object["choices"] as? [[String: Any]] else {
            throw PhotoChatError.malformedStream
        }
        for choice in choices where (choice["index"] as? Int ?? 0) == 0 {
            if let delta = choice["delta"] as? [String: Any], let text = delta["content"] as? String
            {
                answer += text
                guard answer.utf8.count <= 65_536 else { throw PhotoChatError.responseTooLarge }
            }
            if let reason = choice["finish_reason"] as? String, !reason.isEmpty {
                finishedChoice = true
            }
        }
    }
}
