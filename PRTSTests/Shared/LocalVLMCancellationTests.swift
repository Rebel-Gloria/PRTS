import CPRTSLocalVLM
import Foundation
import Testing

@testable import LocalVLM

struct LocalVLMCancellationTests {
    @Test func cancellationBeforeQueueStartsReachesNativeFlag() async throws {
        let queue = DispatchQueue(label: "test.localVLM.queued")
        queue.suspend()
        let task = Task {
            try await LocalVLMCancellation.run(on: queue) { cancel in
                #expect(prts_vlm_cancel_is_requested(cancel.handle) == 1)
                throw CancellationError()
            }
        }
        task.cancel()
        queue.resume()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationDuringNativeReadAndLifetimeUntilReturn() async {
        let entered = TestSignal()
        let release = DispatchSemaphore(value: 0)
        let queue = DispatchQueue(label: "test.localVLM.running")
        let task = Task {
            try await LocalVLMCancellation.run(on: queue) { cancel in
                #expect(prts_vlm_cancel_is_requested(cancel.handle) == 0)
                Task { await entered.signal() }
                release.wait()
                #expect(prts_vlm_cancel_is_requested(cancel.handle) == 1)
                throw CancellationError()
            }
        }
        await entered.wait()
        task.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func cancellationStorageIsReleasedAfterQueueCompletion() async throws {
        final class Reference: @unchecked Sendable {
            private let lock = NSLock()
            private weak var value: LocalVLMCancellation?
            func set(_ value: LocalVLMCancellation) { lock.withLock { self.value = value } }
            var released: Bool { lock.withLock { value == nil } }
        }
        let reference = Reference()
        let queue = DispatchQueue(label: "test.localVLM.lifetime")
        _ = try await LocalVLMCancellation.run(on: queue) { cancel in
            reference.set(cancel)
            #expect(!reference.released)
            return "done"
        }
        await withCheckedContinuation { done in queue.async { done.resume() } }
        #expect(reference.released)
    }
}
