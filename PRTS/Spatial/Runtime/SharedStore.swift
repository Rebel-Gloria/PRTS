import ARKit
import Foundation
import SpatialCore
import simd

/// All shared mutable fields are protected by one short-held lock. No processing or I/O under the lock.
final class SharedStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = SharedSnapshot()
    func read() -> SharedSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    func update(_ block: (inout SharedSnapshot) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        block(&value)
    }
}
