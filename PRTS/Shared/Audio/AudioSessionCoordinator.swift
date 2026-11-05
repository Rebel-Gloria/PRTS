import AVFoundation

enum AppAudioMode: Equatable { case speech, tone, recording }

/// The platform session is shared by every voice and microphone in the app.
protocol AudioSessionDriving: Sendable {
    func activate(_ mode: AppAudioMode) throws
    func deactivate() throws
}

private struct SystemAudioSession: AudioSessionDriving {
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
    struct Lease: Equatable { fileprivate let id = UUID() }
    static let shared = AudioSessionCoordinator(driver: SystemAudioSession())
    nonisolated private static let queue = DispatchQueue(
        label: "PRTS.audioSession",
        qos: .userInitiated
    )
    private let driver: any AudioSessionDriving
    private let errors: ErrorReporter
    private let scheduleDeactivation: (DispatchWorkItem) -> Void
    private var current: Lease?
    private var activeMode: AppAudioMode?
    private var pendingDeactivation: DispatchWorkItem?

    init(
        driver: any AudioSessionDriving,
        errors: ErrorReporter = .init(source: .audio),
        scheduleDeactivation: @escaping (DispatchWorkItem) -> Void = {
            queue.asyncAfter(deadline: .now() + 0.25, execute: $0)
        }
    ) {
        self.driver = driver
        self.errors = errors
        self.scheduleDeactivation = scheduleDeactivation
    }

    func activate(_ mode: AppAudioMode) throws -> Lease {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        // The recording cue and the recognizer both ask for the same session in one press.
        if current == nil || activeMode != mode {
            do {
                let driver = driver
                try Self.queue.sync { try driver.activate(mode) }
            } catch {
                if current == nil { deactivate() }
                throw error
            }
        }
        let lease = Lease()
        current = lease
        activeMode = mode
        return lease
    }

    func release(_ lease: Lease?) {
        guard let lease, current == lease else { return }
        current = nil
        activeMode = nil
        deactivate()
    }

    /// For work that starts with a press: the session can take over 100 ms to change category, so
    /// recording and cues wait for it off the main thread. The returned lease may already be stale
    /// if the caller was cancelled while waiting; it releases that lease itself.
    func activateAsync(_ mode: AppAudioMode) async throws -> Lease {
        pendingDeactivation?.cancel()
        pendingDeactivation = nil
        let previous = (lease: current, mode: activeMode)
        let lease = Lease()
        current = lease
        activeMode = mode
        guard previous.lease == nil || previous.mode != mode else { return lease }
        do {
            let driver = driver
            try await withCheckedThrowingContinuation {
                (done: CheckedContinuation<Void, Error>) in
                Self.queue.async { done.resume(with: Result { try driver.activate(mode) }) }
            }
        } catch {
            if current == lease {
                current = previous.lease
                activeMode = previous.mode
                if current == nil { deactivate() }
            }
            throw error
        }
        return lease
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
