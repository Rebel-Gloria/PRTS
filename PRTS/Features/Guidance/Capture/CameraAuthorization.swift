import AVFoundation

@MainActor
enum CameraAuthorization {
    static func request() async throws -> Bool {
        try Task.checkCancellation()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined:
            return try await wait {
                AVCaptureDevice.requestAccess(for: .video, completionHandler: $0)
            }
        case .denied, .restricted: return false
        @unknown default: return false
        }
    }

    static func wait(
        request: (@escaping @Sendable (Bool) -> Void) -> Void
    ) async throws -> Bool {
        let stream = AsyncStream<Bool> { continuation in
            request {
                continuation.yield($0)
                continuation.finish()
            }
        }
        for await allowed in stream {
            try Task.checkCancellation()
            return allowed
        }
        throw CancellationError()
    }
}
