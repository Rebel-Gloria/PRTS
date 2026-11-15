import Foundation

/// One invocation owns one ephemeral connection; cancellation tears it down.
/// Redirects are rejected so credentials and camera content stay at the requested endpoint.
nonisolated final class PhotoChatClient: NSObject, URLSessionTaskDelegate, Sendable {
    func describe(
        jpeg: Data,
        text: String,
        key: String,
        service: PhotoChatService? = .qwen,
        system: String?,
        thinking: Bool = false,
        maxTokens: Int? = nil,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> String {
        try Task.checkCancellation()
        guard let service else { throw PhotoChatError.invalidService }
        let request = try PhotoChatProtocol.request(
            jpeg: jpeg,
            text: text,
            key: key,
            service: service,
            system: system,
            thinking: thinking,
            maxTokens: maxTokens
        )
        return try await send(request, configuration: configuration)
    }

    func send(
        _ request: URLRequest,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> String {
        #if PRTS_DEV
        let recordingID = UUID().uuidString
        let recordingGeneration =
            DevInteractionRecording.recordingGeneration ?? RecordingStore.shared.admissionGeneration
        var recordedResponse = Data()
        defer {
            if !recordedResponse.isEmpty {
                RecordingStore.shared.attachment(
                    data: recordedResponse,
                    kind: "model_response_stream",
                    fileExtension: "sse",
                    metadata: ["requestID": recordingID],
                    generation: recordingGeneration
                )
            }
        }
        RecordingStore.shared.event(
            "model_request_started",
            details: [
                "requestID": recordingID,
                "interactionID": DevInteractionRecording.interactionID ?? "unavailable",
            ],
            generation: recordingGeneration
        )
        // The body contains the exact prompts and image/video inputs. Headers and URLs can
        // carry credentials, so they never enter a recording.
        if let body = request.httpBody {
            RecordingStore.shared.attachment(
                data: body,
                kind: "model_request",
                fileExtension: "json",
                metadata: ["requestID": recordingID, "backend": "cloud"],
                generation: recordingGeneration
            )
        }
        #endif
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let answer = try await withTaskCancellationHandler {
                let (bytes, response) = try await session.bytes(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw PhotoChatError.malformedStream
                }
                #if PRTS_DEV
                RecordingStore.shared.event(
                    "model_http_response",
                    details: ["requestID": recordingID, "status": String(http.statusCode)],
                    generation: recordingGeneration
                )
                #endif
                guard (200..<300).contains(http.statusCode) else {
                    throw PhotoChatError.http(http.statusCode)
                }
                var stream = PhotoChatStream()
                // Byte framing bounds memory even if a broken server never sends a newline.
                var line = Data()
                var received = 0
                for try await byte in bytes {
                    try Task.checkCancellation()
                    received += 1
                    guard received <= 2_097_152 else { throw PhotoChatError.responseTooLarge }
                    #if PRTS_DEV
                    recordedResponse.append(byte)
                    #endif
                    if byte == 10 {
                        if line.last == 13 { line.removeLast() }
                        guard let text = String(data: line, encoding: .utf8) else {
                            throw PhotoChatError.malformedStream
                        }
                        try stream.receive(line: text)
                        line.removeAll(keepingCapacity: true)
                        if stream.completed { break }
                    } else {
                        line.append(byte)
                        guard line.count <= 262_144 else { throw PhotoChatError.responseTooLarge }
                    }
                }
                if !line.isEmpty {
                    guard let text = String(data: line, encoding: .utf8) else {
                        throw PhotoChatError.malformedStream
                    }
                    try stream.receive(line: text)
                }
                try Task.checkCancellation()
                return try stream.finish()
            } onCancel: {
                session.invalidateAndCancel()
            }
            #if PRTS_DEV
            RecordingStore.shared.event(
                "model_request_completed",
                details: ["requestID": recordingID, "answer": answer],
                generation: recordingGeneration
            )
            #endif
            return answer
        } catch {
            #if PRTS_DEV
            DevInteractionRecording.failure(
                error,
                feature: "cloud_model",
                id: recordingID,
                generation: recordingGeneration
            )
            #endif
            throw error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
