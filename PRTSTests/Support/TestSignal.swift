import Foundation

actor TestSignal {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signalled = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
