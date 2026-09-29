/// Converts one accepted spatial result into rate-limited speech/haptic events.

import Combine
import Foundation
import SpatialCore

@MainActor
final class FeedbackCoordinator: ObservableObject {
    private var policy = FeedbackPolicy()
    private var turnPolicy = TurnAnnouncementPolicy()
    private var turnEpoch: UInt64?
    private var turnGoal: UInt64?
    private var turnVersion: UInt64?

    /// Uses the same angle hysteresis as haptics, independently of vibration hardware.
    func consumeDirection(_ snapshot: SharedSnapshot, speech: SpeechManager,
                          now: Double = ProcessInfo.processInfo.systemUptime) {
        guard speech.voiceAnnouncementsEnabled else { turnPolicy.reset(); return }
        if turnEpoch != snapshot.epoch || turnGoal != snapshot.pathUpdate.goal?.id || turnVersion != snapshot.parameterVersion {
            turnPolicy.reset(); turnEpoch = snapshot.epoch; turnGoal = snapshot.pathUpdate.goal?.id
            turnVersion = snapshot.parameterVersion
        }
        let heading = snapshot.pathOptions.enabled ? snapshot.pathHeading(now:now) : nil
        if let side = turnPolicy.update(heading:heading, now:now,
                                       threshold:snapshot.pathOptions.deviationDegrees,
                                       alignment:snapshot.pathOptions.alignmentDegrees) {
            speech.speakPerception(side < 0 ? "向左转" : "向右转",
                                   english:side < 0 ? "Turn left" : "Turn right")
        }
    }
    private(set) var lastConsumedResultID: String?
    private(set) var lastSpokenResultID: String?

    func reset() { policy.reset(); turnPolicy.reset(); turnEpoch = nil; turnGoal = nil; turnVersion = nil; lastConsumedResultID = nil; lastSpokenResultID = nil }

    func consume(_ result: SceneResult, now: Double = ProcessInfo.processInfo.systemUptime,
                 speech: SpeechManager, haptics: HapticManager, announceCandidates: Bool = true) {
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
                guard announceCandidates else { continue }
                let zh = sector == .left ? "左侧" : (sector == .right ? "右侧" : "中间")
                let en = sector == .left ? "left" : (sector == .right ? "right" : "center")
                speech.speakPerception("\(zh)有通道", english: "Observed candidate channel in the \(en)")

            }
        }
    }
}

@MainActor
private extension SpeechManager {
    func speakPerception(_ chinese: String,english: String) { speakPerception((followSystemLanguageEnabled ? SpeechLanguage.fromSystemLanguage() : selectedLanguage) == .chinese ? chinese : english) }
}

/// One announcement per directional episode. Brief missing frames retain the latch;
/// only confirmed alignment or a change of side re-arms it.
struct TurnAnnouncementPolicy {
    private var angles = PathHapticPolicy()
    private var announcedSide = 0
    mutating func reset() { self = .init() }
    mutating func update(heading: PathHeading?, now: Double,
                         threshold: Float, alignment: Float) -> Int? {
        _ = angles.update(heading:heading, now:now, enabled:true,
                          threshold:threshold, alignmentDegrees:alignment)
        if angles.mode == "aligned_latched" { announcedSide = 0; return nil }
        let side = angles.mode == "left_double" ? -1 : (angles.mode == "right_long" ? 1 : 0)
        guard side != 0, side != announcedSide else { return nil }
        announcedSide = side
        return side
    }
}
