import AVFoundation

enum AppAudioMode: Equatable { case speech, tone, recording }

/// The platform session is shared by every voice and microphone in the app.
nonisolated protocol AudioSessionDriving: Sendable {
    func activate(_ mode: AppAudioMode) throws
    func deactivate() throws
}

nonisolated private struct SystemAudioSession: AudioSessionDriving {
    func activate(_ mode: AppAudioMode) throws {
        let session = AVAudioSession.sharedInstance()
        switch mode {
        case .recording:
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker]
            )
        case .speech:
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        case .tone:
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
        }
        try session.setActive(true)
    }

    func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(
            false,
            options: [.notifyOthersOnDeactivation]
        )
    }
}

/// Activation transfers ownership. A delayed stop may release only the activation it owns,
/// so finishing an old guide, answer or recording cannot deactivate a newer output.
///
/// Deactivating takes about 570 ms on an iPhone 17 Pro Max, and the camera preview draws on the
/// main thread, so it runs on its own queue. It waits briefly because the next sentence often
/// follows at once; that activation cancels it instead of waiting for it to finish.
@MainActor
final class AudioSessionCoordinator {
    struct Lease: Equatable { fileprivate let order: UInt64 }
    static let shared = AudioSessionCoordinator(driver: SystemAudioSession())
    private static var lastIssuedOrder: UInt64 = 0
    nonisolated private static let queue = DispatchQueue(
        label: "PRTS.audioSession",
        qos: .userInitiated
    )
    private let driver: any AudioSessionDriving
    private let errors: ErrorReporter
    private let scheduleDeactivation: (DispatchWorkItem) -> Void
    private let deliverActivation: @Sendable (@escaping @Sendable () -> Void) -> Void
    private var current: Lease?
    // Keep the last delivery after release: an older completion must not take ownership again.
    private var lastDeliveredOrder: UInt64 = 0
    // Sync speech and async input can request the same route before activation returns.
    // Only the audio queue evaluates the result, once for all those callers.
    nonisolated private final class Activation: @unchecked Sendable {
        let mode: AppAudioMode
        let driver: any AudioSessionDriving
        private var cached: Result<Void, Error>?

        func run() -> Result<Void, Error> {
            if let cached { return cached }
            let result = Result { try driver.activate(mode) }
            cached = result
            return result
        }

        init(_ mode: AppAudioMode, driver: any AudioSessionDriving) {
            self.mode = mode
            self.driver = driver
        }
    }

    private var activation: Activation?
    private var requested: Lease?
    private var pendingDeactivation: DispatchWorkItem?

    init(
        driver: any AudioSessionDriving,
        errors: ErrorReporter = .init(source: .audio),
        deliverActivation: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = { $0() },
        scheduleDeactivation: @escaping (DispatchWorkItem) -> Void = {
            queue.asyncAfter(deadline: .now() + 0.25, execute: $0)
        }
    ) {
        self.driver = driver
        self.errors = errors
        self.deliverActivation = deliverActivation
        self.scheduleDeactivation = scheduleDeactivation
    }

    private func nextLease() -> Lease {
        Self.lastIssuedOrder += 1
        return Lease(order: Self.lastIssuedOrder)
    }

    private func request(_ mode: AppAudioMode, lease: Lease) -> Activation {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        requested = lease
        if let activation, activation.mode == mode { return activation }
        let next = Activation(mode, driver: driver)
        activation = next
        return next
    }

    private func finish(_ result: Result<Void, Error>, route: Activation, lease: Lease) throws
        -> Lease
    {
        do {
            try result.get()
        } catch {
            guard activation === route else { throw error }
            activation = nil
            requested = nil
            if current == nil { deactivate() }
            throw error
        }
        guard activation === route else { throw CancellationError() }
        if lease.order > lastDeliveredOrder {
            lastDeliveredOrder = lease.order
            current = lease
        }
        return lease
    }

    func activate(_ mode: AppAudioMode) throws -> Lease {
        let lease = nextLease()
        let route = request(mode, lease: lease)
        return try finish(Self.queue.sync { route.run() }, route: route, lease: lease)
    }

    func activateAsync(_ mode: AppAudioMode) async throws -> Lease {
        let lease = nextLease()
        let route = request(mode, lease: lease)
        let result = await withCheckedContinuation { done in
            Self.queue.async { [deliverActivation] in
                let result = route.run()
                deliverActivation { done.resume(returning: result) }
            }
        }
        return try finish(result, route: route, lease: lease)
    }

    func release(_ lease: Lease?) {
        guard let lease, current == lease else { return }
        current = nil
        if let requested, requested != lease { return }
        requested = nil
        activation = nil
        deactivate()
    }

    func resumeAfterInterruption() -> Bool {
        // Recheck the system, not the cached result; do not steal another output's lease.
        let mode = activation?.mode ?? .speech
        do {
            try Self.queue.sync { [driver] in try driver.activate(mode) }
            if activation == nil && current == nil {
                pendingDeactivation?.cancel()
                deactivate()
            }
            return true
        } catch {
            return false
        }
    }

    private func deactivate() {
        let work = DispatchWorkItem { [driver, errors] in
            do {
                try driver.deactivate()
            } catch {
                errors.record(error)
            }
        }
        pendingDeactivation = work
        scheduleDeactivation(work)
    }
}
