import Foundation
import AVFoundation

@MainActor
final class PRTSSpatialCueEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!

    override init() {
        super.init()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    func start() { try? engine.start() }

    func stop() { player.stop(); isPlaying = false }

    func playObstacleCue(distanceMeters: Float, azimuthRadians: Float) {
        let clampedDistance = max(0.2, min(4.5, distanceMeters))
        let urgency = 1 - clampedDistance / 4.5
        let frequency = 520.0 + Double(urgency) * 260.0
        let duration = 0.055
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
        buffer.frameLength = frames
        let pan = max(-1, min(1, sin(azimuthRadians)))
        let leftGain = Float((1 - pan) * 0.5)
        let rightGain = Float((1 + pan) * 0.5)
        for channel in 0..<2 {
            guard let data = buffer.floatChannelData?[channel] else { continue }
            let gain = channel == 0 ? leftGain : rightGain
            for index in 0..<Int(frames) { data[index] = sinf(Float(2 * Double.pi * frequency * Double(index) / format.sampleRate)) * gain * 0.45 }
        }
        player.scheduleBuffer(buffer)
        if !engine.isRunning { start() }
        player.play()
        isPlaying = true
    }
}
