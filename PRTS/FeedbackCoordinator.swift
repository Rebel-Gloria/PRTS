import Combine
import Foundation
import SpatialCore

@MainActor
final class FeedbackCoordinator: ObservableObject {
    private var policy = FeedbackPolicy()
    private(set) var lastConsumedResultID: String?
    private(set) var lastSpokenResultID: String?

    func reset() { policy.reset(); lastConsumedResultID = nil; lastSpokenResultID = nil }

    func consume(_ result: SceneResult, now: Double = ProcessInfo.processInfo.systemUptime,
                 speech: SpeechManager, haptics: HapticManager) {
        lastConsumedResultID = result.id
        for event in policy.evaluate(result, now: now) {
            lastSpokenResultID = event.resultID
            switch event {
            case .perceptionUnavailable:
                speech.speakPerception("感知暂不可用")
                // Direction haptics are owned solely by PathHaptics.
            case .centerObstacle(_, let distance, _):
                speech.speakPerception(String(format: "前方障碍，约 %.1f 米", distance),
                             english: String(format: "Obstacle ahead, about %.1f meters", distance))

            case .observedCandidate(_, let sector):
                let zh = sector == .left ? "左侧" : (sector == .right ? "右侧" : "中间")
                let en = sector == .left ? "left" : (sector == .right ? "right" : "center")
                speech.speakPerception("\(zh)存在观测候选通道", english: "Observed candidate channel in the \(en)")

            }
        }
    }
}

@MainActor
private extension SpeechManager {
    func speakPerception(_ chinese: String,english: String) { speakPerception((followSystemLanguageEnabled ? SpeechLanguage.fromSystemLanguage() : selectedLanguage) == .chinese ? chinese : english) }
}
