import AVFoundation

/// Separate answer voice and deterministic A/B tones, all synthesized locally.
@MainActor
final class PhotoAudioOutput: NSObject, AVSpeechSynthesizerDelegate {
    enum Cue { case submit, record }
    private let synthesizer = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var activeUtterance: ObjectIdentifier?
    private var ownsSession = false
    var onFinished: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func cue(_ cue: Cue) throws {
        let session = AVAudioSession.sharedInstance()
        if cue == .record {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker])
        } else {
            // Short taps must not activate an input audio route or require microphone access.
            try session.setCategory(.playback, mode: .default, options: [.duckOthers])
        }
        try session.setActive(true)
        ownsSession = true
        player = try AVAudioPlayer(data: Self.toneData(for: cue))
        guard player?.play() == true else { throw OutputError.cueUnavailable }
    }

    func speak(_ text: String) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try session.setActive(true)
        ownsSession = true
        let utterance = Self.answerUtterance(text)
        activeUtterance = ObjectIdentifier(utterance)
        synthesizer.speak(utterance)
    }

    static func answerUtterance(_ text: String) -> AVSpeechUtterance {
        let utterance = AVSpeechUtterance(string: text)
        let defaultID = AVSpeechSynthesisVoice(language: "zh-CN")?.identifier
        let alternate = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "zh-CN" && $0.identifier != defaultID }
            .sorted { $0.identifier < $1.identifier }.first
        utterance.voice = alternate ?? AVSpeechSynthesisVoice(language: "zh-CN")
        // Devices with only one Chinese voice still have a distinct lower-pitch profile.
        utterance.pitchMultiplier = 0.8
        utterance.rate = 0.46
        return utterance
    }

    func stop() {
        activeUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop(); player = nil
        if ownsSession {
            ownsSession = false
            try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            guard let self, self.activeUtterance == id else { return }
            self.activeUtterance = nil
            self.onFinished?()
        }
    }

    enum OutputError: LocalizedError {
        case cueUnavailable
        var errorDescription: String? { "无法播放拍照提示音，请重试" }
    }

    static func toneData(for cue: Cue) -> Data {
        wave(frequency: cue == .submit ? 880 : 440)
    }

    private static func wave(frequency: Double) -> Data {
        let rate = 16_000, count = 1_600
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        ascii("RIFF"); u32(UInt32(36 + count * 2)); ascii("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2)); u16(2); u16(16)
        ascii("data"); u32(UInt32(count * 2))
        for i in 0..<count {
            let envelope = min(1, Double(min(i, count - 1 - i)) / 160)
            let sample = Int16(sin(2 * .pi * frequency * Double(i) / Double(rate)) * 8_000 * envelope)
            u16(UInt16(bitPattern: sample))
        }
        return data
    }
}
