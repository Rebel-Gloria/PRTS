import Foundation

/// One invocation owns one ephemeral connection; cancellation tears it down.
/// Redirects are rejected so credentials and camera content stay at the requested endpoint.
nonisolated final class PhotoChatClient: NSObject, URLSessionTaskDelegate, Sendable {
    func describe(jpeg: Data, text: String, key: String,
                  configuration: URLSessionConfiguration = .ephemeral) async throws -> String {
        try Task.checkCancellation()
        let request = try PhotoChatProtocol.request(jpeg: jpeg, text: text, key: key)
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw PhotoChatError.malformedStream }
            guard (200..<300).contains(http.statusCode) else { throw PhotoChatError.http(http.statusCode) }
            var stream = PhotoChatStream()
            // Byte framing bounds memory even if a broken server never sends a newline.
            var line = Data()
            var received = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                received += 1
                guard received <= 2_097_152 else { throw PhotoChatError.responseTooLarge }
                if byte == 10 {
                    if line.last == 13 { line.removeLast() }
                    guard let text = String(data: line, encoding: .utf8) else { throw PhotoChatError.malformedStream }
                    try stream.receive(line: text)
                    line.removeAll(keepingCapacity: true)
                    if stream.completed { break }
                } else {
                    line.append(byte)
                    guard line.count <= 262_144 else { throw PhotoChatError.responseTooLarge }
                }
            }
            if !line.isEmpty {
                guard let text = String(data: line, encoding: .utf8) else { throw PhotoChatError.malformedStream }
                try stream.receive(line: text)
            }
            try Task.checkCancellation()
            return try stream.finish()
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
