import AVFoundation

enum AppAudioMode: Equatable { case speech, tone, recording }

/// The platform session is shared by every voice and microphone in the app.
@MainActor
protocol AudioSessionDriving {
    func activate(_ mode: AppAudioMode) throws
    func deactivate() throws
}

@MainActor
private struct SystemAudioSession: AudioSessionDriving {
    private let session = AVAudioSession.sharedInstance()

    func activate(_ mode: AppAudioMode) throws {
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
        try session.setActive(false, options: [.notifyOthersOnDeactivation])
    }
}

/// Activation transfers ownership. A delayed stop may release only the activation it owns,
/// so finishing an old guide, answer or recording cannot deactivate a newer output.
@MainActor
final class AudioSessionCoordinator {
    struct Lease: Equatable { fileprivate let id = UUID() }
    static let shared = AudioSessionCoordinator(driver: SystemAudioSession())
    private let driver: any AudioSessionDriving
    private let errors: ErrorReporter
    private var current: Lease?

    init(driver: any AudioSessionDriving, errors: ErrorReporter = .init(source: .audio)) {
        self.driver = driver
        self.errors = errors
    }

    func activate(_ mode: AppAudioMode) throws -> Lease {
        try driver.activate(mode)
        let lease = Lease()
        current = lease
        return lease
    }

    func release(_ lease: Lease?) {
        guard let lease, current == lease else { return }
        current = nil
        do {
            try driver.deactivate()
        } catch {
            errors.record(error)
        }
    }
}
