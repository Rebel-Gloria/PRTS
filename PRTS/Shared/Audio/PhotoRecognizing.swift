import Foundation

/// Narrow hardware boundaries: tests substitute deterministic input/output while
/// production always uses the native implementations. There is no in-app mock mode.
@MainActor
protocol PhotoRecognizing: AnyObject {
    func start() async throws
    func endCapture()
    func finish() async throws -> String
    func cancel()
}
