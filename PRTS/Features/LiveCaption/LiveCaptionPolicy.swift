import Foundation

nonisolated enum LiveCaptionPolicy {
    static let minimumRequestInterval: TimeInterval = 2
    static let sampleInterval: TimeInterval = 0.2
    static let window: TimeInterval = 3
    static let maximumSamples = 15
    /// Qwen needs at least four frames in a video.
    static let minimumVideoFrames = 4
    static let maximumVideoFrames = 13
    static let initialCharactersPerSecond = 4.5

    static func answer(_ response: String, previous: String?) -> String? {
        let line = String(response.prefix { !$0.isNewline })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != "无", line != "无。", line.count <= 20,
            !["照片", "画面", "镜头"].contains(where: line.contains), line != previous
        else { return nil }
        return line
    }

    static func requestTime(
        now: TimeInterval,
        lastRequest: TimeInterval,
        speechEnd: TimeInterval?,
        modelDuration: TimeInterval
    ) -> TimeInterval {
        max(now, lastRequest + minimumRequestInterval, (speechEnd ?? now) - modelDuration)
    }

    static func updatedSpeechRate(
        _ rate: Double,
        characters: Int,
        duration: TimeInterval
    ) -> Double {
        rate * 0.75 + Double(characters) / duration * 0.25
    }
}
