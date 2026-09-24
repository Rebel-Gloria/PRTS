import AVFoundation
import Combine
import CoreMedia
import PRTSAppleModels
import PRTSContracts

@MainActor
final class PRTSBackendBridge: ObservableObject {
    enum Status: Equatable {
        case idle, initializing, ready, paused, degraded(String), closed

        var message: String {
            switch self {
            case .idle: return "Backend idle — minimal mode"
            case .initializing: return "Initializing backend"
            case .ready: return "Backend ready"
            case .paused: return "Backend paused"
            case let .degraded(reason): return "Models unavailable — \(reason)"
            case .closed: return "Backend closed"
            }
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var latestCommand = "Enter a command to validate the contract path"
    @Published private(set) var convertedFrameCount = 0
    @Published private(set) var lastError: String?

    var onSpeechRequest: ((SpeechRequest) -> Void)?
    var playbackSink: ((Bool) -> Void)?
    var onPlaybackChange: ((Bool) -> Void)?
    var onCancelSpeech: (() -> Void)?
    var onCue: ((String, SessionTime) -> Void)?
    var onAttentionEvent: (() -> Void)?

    private let frameQueue = DispatchQueue(label: "com.prts.backend.frame-bridge", qos: .userInitiated)
    private let lock = NSLock()
    nonisolated(unsafe) private var newestSample: CMSampleBuffer?
    nonisolated(unsafe) private var drainScheduled = false
    nonisolated(unsafe) private var stopped = false
    nonisolated(unsafe) private var nextSequence: UInt64 = 0
    nonisolated(unsafe) private var lastAcceptedAt: SessionTime = 0
    nonisolated(unsafe) private var pendingFrame: RGBFrame?
    nonisolated(unsafe) private var framePublishScheduled = false
    private var lastFrameTimestamp: SessionTime = 0
    private let frameInterval: SessionTime = 0.2 // bounded 5 fps ingress until perception is explicitly enabled
    private(set) var latestFrame: RGBFrame?

    func initialize() {
        guard status == .idle || status == .paused else { return }
        status = .initializing
        // The pinned Apple package intentionally builds a light target until its XCFramework/models exist.
        if PRTSAppleRuntimeCapability.coreSessionAvailable {
            status = .degraded("full model runtime adapter is not configured")
        } else {
            status = .degraded("full PRTSCoreSession and model artifacts are not included")
        }
    }

    func setActive(_ active: Bool) {
        guard !stopped else { return }
        if active {
            if status == .idle || status == .paused { initialize() }
        } else {
            pause()
        }
    }

    func pause() {
        lock.lock()
        newestSample = nil
        lock.unlock()
        if status != .closed { status = .paused }
        playbackSink?(false)
    }

    func setPlaybackFromTTS(_ active: Bool) {
        // Wired to PRTSCoreSession.setPlayback when the full session is available.
        playbackSink?(active)
    }

    func handleMemoryWarning() {
        if UserDefaults.standard.string(forKey: "prts.runtimeProfile") == PRTSRuntimeProfile.fullExperimental.rawValue {
            UserDefaults.standard.set(PRTSRuntimeProfile.perception.rawValue, forKey: "prts.runtimeProfile")
        }
        pause()
        status = .degraded("memory warning — nonessential model work stopped; restart in perception/minimal mode")
    }

    func close() {
        lock.lock()
        stopped = true
        newestSample = nil
        lock.unlock()
        onPlaybackChange?(false)
        playbackSink?(false)
        status = .closed
    }

    /// Contract-only smoke path: this uses the pinned backend's real command parser.
    /// It does not claim to run PRTSCoreSession or produce navigation/model output.
    @discardableResult
    func pushText(_ text: String) -> TaskIntent? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            latestCommand = "Please enter a command"
            return nil
        }
        guard let intent = CommandRouter.parse(trimmed) else {
            latestCommand = "Contract parser: no command intent for “\(trimmed)”"
            return nil
        }
        let detail = [intent.action, intent.kind, intent.target, intent.direction, intent.query]
            .compactMap { $0 }
            .joined(separator: " · ")
        latestCommand = "Contract intent: \(detail) (models not running)"
        return intent
    }

    /// CoreEvent delivery point. When the full runtime is supplied, route events here from its
    /// callback; all UI/audio effects are dispatched to MainActor by the caller.
    func receive(_ event: CoreEvent) {
        if let request = event.speechRequest { onSpeechRequest?(request) }
        if event.type == "speech_cancel" {
            onCancelSpeech?()
            onPlaybackChange?(false)
        }
        if event.type == "attention" || event.type == "target_found" { onAttentionEvent?() }
        if event.type == "sound_cue",
           let cue = event.payload["cue"]?.string,
           let expiry = event.payload["expires_s"]?.number {
            onCue?(cue, expiry)
        }
    }

    nonisolated func consume(_ sampleBuffer: CMSampleBuffer) {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        guard now - lastAcceptedAt >= frameInterval else { lock.unlock(); return }
        lastAcceptedAt = now
        newestSample = sampleBuffer
        let shouldSchedule = !drainScheduled
        if shouldSchedule { drainScheduled = true }
        lock.unlock()
        if shouldSchedule { frameQueue.async { [weak self] in self?.drainFrames() } }
    }

    private func publishNewestFrame() {
        while true {
            lock.lock()
            let frame = pendingFrame
            pendingFrame = nil
            if frame == nil { framePublishScheduled = false }
            lock.unlock()
            guard let frame else { return }
            guard status != .paused, status != .closed else { continue }
            latestFrame = frame
            lastFrameTimestamp = frame.timestamp
            convertedFrameCount += 1
        }
    }

    nonisolated private func drainFrames() {
        while true {
            lock.lock()
            let sample = newestSample
            newestSample = nil
            if sample == nil { drainScheduled = false }
            let isStopped = stopped
            lock.unlock()
            guard !isStopped, let sample else { return }
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sample) else {
                Task { @MainActor [weak self] in self?.lastError = "Camera sample has no image buffer" }
                continue
            }
            let timestamp = ProcessInfo.processInfo.systemUptime
            nextSequence &+= 1
            do {
                let frame = try CameraAdapter.frame(pixelBuffer, timestamp: timestamp, sequence: nextSequence)
                lock.lock()
                pendingFrame = frame
                let shouldPublish = !framePublishScheduled
                if shouldPublish { framePublishScheduled = true }
                lock.unlock()
                if shouldPublish {
                    Task { @MainActor [weak self] in self?.publishNewestFrame() }
                }
            } catch {
                Task { @MainActor [weak self] in self?.lastError = "Camera adapter: \(error)" }
            }
        }
    }
}

extension PRTSBackendBridge: CameraFrameConsumer {
    nonisolated func consumeVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        consume(sampleBuffer)
    }
}
