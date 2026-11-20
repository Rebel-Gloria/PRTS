import Foundation

/// Narrow hardware boundaries: tests substitute deterministic input/output while
/// production always uses the native implementations. There is no in-app mock mode.
@MainActor
protocol PhotoRecognizing: AnyObject {
    func start(onDeviceOnly: Bool) async throws
    /// False when released before the microphone started; there is nothing to submit.
    func endCapture() -> Bool
    func finish() async throws -> String
    func cancel()
}
