import Foundation
import LocalVLM
import os

nonisolated enum TextReadingBackend {
    /// First question: looks at the photo (the slow part, about 1.3 s) and says what the text is on.
    /// The budget only fits one word. A longer answer is judged by what arrived, because this
    /// step only labels the text and must not fail the reader that copies it.
    static func surface(of jpeg: Data, maxTokens: Int = 8) async throws -> TextReadingAnswer.Surface
    {
        let received = OSAllocatedUnfairLock(initialState: "")
        do {
            return TextReadingAnswer.Surface(
                answer: try await PhotoLocalModel.describe(
                    jpeg: jpeg,
                    prompt: TextReadingPrompt.surfaceQuestion,
                    system: TextReadingPrompt.system,
                    maxTokens: maxTokens,
                    onText: { piece in received.withLock { $0 += piece } }
                )
            )
        } catch LocalVLM.Failure.outputLimit {
            return TextReadingAnswer.Surface(answer: received.withLock { $0 })
        }
    }

    /// Second question about the photo `surface(of:)` just looked at; the copy streams into `onText`.
    static func copy(onText: @escaping @Sendable (String) -> Void) async throws -> String {
        try await PhotoLocalModel.ask(
            TextReadingPrompt.copyQuestion,
            maxTokens: TextReadingPrompt.maxTokens,
            onText: onText
        )
    }

    /// The cloud provider chosen for text reading: one request says what the text is on and copies it.
    static func remote(jpeg: Data, key: String, service: PhotoChatService) async throws -> (
        TextReadingAnswer.Surface, String
    ) {
        try parseRemoteAnswer(
            try await PhotoChatClient().describe(
                jpeg: jpeg,
                text: TextReadingPrompt.remotePrompt,
                key: key,
                service: service,
                system: TextReadingPrompt.remoteSystem
            )
        )
    }

    /// A leading reasoning block is metadata only when followed by the expected answer envelope.
    /// Ambiguous or incomplete envelopes fail into the existing reader fallback.
    static func parseRemoteAnswer(
        _ response: String
    ) throws -> (TextReadingAnswer.Surface, String) {
        var text = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("<think>") {
            guard let end = text.range(of: "</think>") else {
                throw PhotoChatError.malformedStream
            }
            let remainder = String(text[end.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let heading = String(remainder.prefix { !$0.isNewline })
                .trimmingCharacters(in: .whitespaces)
            guard
                remainder == TextReadingPrompt.none
                    || TextReadingAnswer.Surface(rawValue: heading) != nil
            else { throw PhotoChatError.malformedStream }
            text = remainder
        }
        let copy = copyBeforeStrayMarker(text).trimmingCharacters(in: .whitespacesAndNewlines)
        if copy == TextReadingPrompt.none || copy == TextReadingPrompt.none + "。" {
            return (.object, "")
        }
        let line = copy.prefix { !$0.isNewline }
        let heading = line.trimmingCharacters(in: .whitespaces)
        guard let surface = TextReadingAnswer.Surface(rawValue: heading) else {
            return (.object, copy)
        }
        return (surface, String(copy.dropFirst(line.count)))
    }

    /// Paired tags within the copy are literal OCR text; only an unmatched closing marker stops it.
    private static func copyBeforeStrayMarker(_ text: String) -> String {
        var position = text.startIndex
        var openings = 0
        while let closing = text.range(of: "</think>", range: position..<text.endIndex) {
            var cursor = position
            while let opening = text.range(of: "<think>", range: cursor..<closing.lowerBound) {
                openings += 1
                cursor = opening.upperBound
            }
            guard openings > 0 else {
                return String(text[..<closing.lowerBound])
            }
            openings -= 1
            position = closing.upperBound
        }
        return text
    }
}
