import Foundation

nonisolated enum LiveCaptionPolicy {
    /// A video goes out on this beat, moving or not; the model answers "无" for a still scene.
    static let requestInterval: TimeInterval = 2
    /// 10 frames per second, the most a video carries.
    static let sampleInterval: TimeInterval = 0.1
    static let window: TimeInterval = 2
    static let maximumSamples = 20
    /// New frames per video in a still scene. The last frame of the previous video joins them.
    static let newFrames = 5
    /// Motion accumulated over a window, in mean grey levels: below the first a scene is still
    /// and above the second a person is clearly moving (measured on a recording of one person
    /// crouching and standing). Between them the video grows in step.
    static let stillMotion = 30.0
    static let fullMotion = 150.0
    /// Qwen needs at least four frames in a video.
    static let minimumVideoFrames = 4
    /// A request takes 3-5 s on a phone, longer than the beat, so requests overlap. Past this
    /// limit more uploads only slow each other down.
    static let maximumRequestsInFlight = 3
    /// One failed request is skipped, as the next is 2 s away; this many in a row ends captions.
    static let maximumConsecutiveFailures = 3
    /// Upload size sets most of the request time on a phone (docs/validation.md).
    static let imageQuality: CGFloat = 0.5

    static func frameCount(motion: Double) -> Int {
        let share = min(1, max(0, (motion - stillMotion) / (fullMotion - stillMotion)))
        return newFrames + Int((Double(maximumSamples - newFrames) * share).rounded())
    }

    static func answer(_ response: String, previous: String?) -> String? {
        let line = String(response.prefix { !$0.isNewline })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty, line != "无", line != "无。", line.count <= 24,
            !["照片", "画面", "镜头"].contains(where: line.contains), line != previous
        else { return nil }
        return line
    }
}
