import AVFoundation

/// App announcement voice profile and deterministic A/B tones, synthesized locally.
/// Handles user-requested answers, status prompts and tones for descriptions, live captions and
/// text reading; SpeechManager handles obstacle announcements.
@MainActor
final class AnswerAudioOutput: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private let makeUtterance: (String) -> AVSpeechUtterance
    private var player: AVAudioPlayer?
    private var activeUtterance: ObjectIdentifier?
    private var activeCue: UUID?
    private let audioSession: AudioSessionCoordinator
    private var audioLease: AudioSessionCoordinator.Lease?
    var onFinished: (() -> Void)?

    override convenience init() {
        self.init(makeUtterance: { SpeechVoice.utterance($0) })
    }

    convenience init(makeUtterance: @escaping (String) -> AVSpeechUtterance) {
        self.init(makeUtterance: makeUtterance, audioSession: .shared)
    }

    init(
        makeUtterance: @escaping (String) -> AVSpeechUtterance,
        audioSession: AudioSessionCoordinator
    ) {
        self.makeUtterance = makeUtterance
        self.audioSession = audioSession
        super.init()
        synthesizer.delegate = self
    }

    func cue(_ cue: AnswerCue) async throws {
        let id = UUID()
        activeCue = id
        // Short taps must not activate an input audio route or require microphone access.
        let lease = try await audioSession.activateAsync(cue == .record ? .recording : .tone)
        guard activeCue == id else {
            audioSession.release(lease)
            throw CancellationError()
        }
        audioLease = lease
        let tone = try await Task.detached { try Tone(cue) }.value
        guard activeCue == id else { throw CancellationError() }
        player = tone.player
        guard tone.player.play() else { throw OutputError.cueUnavailable }
    }

    func speak(_ text: String) throws {
        audioLease = try audioSession.activate(.speech)
        let utterance = makeUtterance(text)
        activeUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    func stop() {
        activeCue = nil
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        player = nil
        audioSession.release(audioLease)
        audioLease = nil
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == id else { return }
            self.activeUtterance = nil
            self.onFinished?()
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        // Explicit stop has already cleared activeUtterance; a system cancellation still ends
        // the current playback so its owner can release the session and reset its controls.
        speechSynthesizer(synthesizer, didFinish: utterance)
    }

    /// Preparing the player takes tens of milliseconds, so it happens before the main thread
    /// takes it. It is not used off the main thread after this.
    private struct Tone: @unchecked Sendable {
        let player: AVAudioPlayer

        init(_ cue: AnswerCue) throws {
            player = try AVAudioPlayer(data: AnswerAudioOutput.toneData(for: cue))
            player.prepareToPlay()
        }
    }

    enum OutputError: LocalizedError {
        case cueUnavailable
        var errorDescription: String? {
            AppLocalization.interfaceString("photo.error.cueUnavailable")
        }
    }

    nonisolated static func toneData(for cue: AnswerCue) -> Data {
        wave(frequency: cue == .submit ? 880 : 440)
    }

    nonisolated private static func wave(frequency: Double) -> Data {
        let rate = 16_000
        let count = 1_600
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var v = value.littleEndian
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        ascii("RIFF")
        u32(UInt32(36 + count * 2))
        ascii("WAVEfmt ")
        u32(16)
        u16(1)
        u16(1)
        u32(UInt32(rate))
        u32(UInt32(rate * 2))
        u16(2)
        u16(16)
        ascii("data")
        u32(UInt32(count * 2))
        for i in 0..<count {
            let envelope = min(1, Double(min(i, count - 1 - i)) / 160)
            let sample = Int16(
                sin(2 * .pi * frequency * Double(i) / Double(rate)) * 8_000 * envelope
            )
            u16(UInt16(bitPattern: sample))
        }
        return data
    }
}
