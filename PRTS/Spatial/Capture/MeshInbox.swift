import ARKit
import Foundation

struct MeshJob: @unchecked Sendable {
    let anchor: ARMeshAnchor?
    let id: String
    let epoch: UInt64
    let time: Double
}
final class MeshInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [String: MeshJob] = [:]
    private var running = false
    func submit(_ job: MeshJob) -> (schedule: Bool, evicted: String?) {
        lock.lock()
        defer { lock.unlock() }
        var evicted: String?
        if pending[job.id] == nil, pending.count >= 32,
            let oldest = pending.min(by: { $0.value.time < $1.value.time })?.key
        {
            pending.removeValue(forKey: oldest)
            evicted = oldest
        }
        pending[job.id] = job
        if running { return (false, evicted) }
        running = true
        return (true, evicted)
    }
    func next() -> MeshJob? {
        lock.lock()
        defer { lock.unlock() }
        guard let key = pending.min(by: { $0.value.time < $1.value.time })?.key else {
            running = false
            return nil
        }
        return pending.removeValue(forKey: key)
    }
    func clear() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }
}
