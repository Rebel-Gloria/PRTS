/// Converts one accepted spatial result into rate-limited speech/haptic events.

import Combine
import Foundation
import SpatialCore

@MainActor
final class FeedbackCoordinator: ObservableObject {
    private var policy = FeedbackPolicy()
    private var turnPolicy = TurnAnnouncementPolicy()
    private var routeSpeech = RouteAnnouncementPolicy()
    private var waypointSpeech = ObstacleRouteAnnouncementPolicy()
    private var hasWaypointFeedback = false
    private var turnEpoch: UInt64?
    private var turnGoal: UInt64?
    private var turnVersion: UInt64?

    /// Uses the same angle hysteresis as haptics, independently of vibration hardware.
    func consumeDirection(_ snapshot: SharedSnapshot, speech: SpeechManager,
                          now: Double = ProcessInfo.processInfo.systemUptime) {
        guard speech.voiceAnnouncementsEnabled else { turnPolicy.reset();routeSpeech.reset();waypointSpeech.reset();return }
        if snapshot.pathUpdate.waypointGuidance != nil {
            if turnEpoch != snapshot.epoch || turnVersion != snapshot.parameterVersion {
                waypointSpeech.reset(); speech.cancelPerceptionSpeech(); turnEpoch = snapshot.epoch; turnVersion = snapshot.parameterVersion
            }
            hasWaypointFeedback = true
            guard let update = snapshot.activeWaypointUpdate(now: now) else {
                // A dropped/stale frame pauses speech without re-arming its one-shot latch.
                speech.cancelPerceptionSpeech()
                return
            }
            let heading = snapshot.pathHeading(now: now)
            if waypointSpeech.interruptIfObsolete(update:update,heading:heading,threshold:snapshot.pathOptions.deviationDegrees) {
                speech.cancelPerceptionSpeech()
            }
            if let cue = waypointSpeech.cue(update:update,heading:heading,now:now,
                deviationDegrees:snapshot.pathOptions.deviationDegrees,canSpeak:!speech.isSpeakingPerception) {
                speech.speakPerception(cue.chinese, english: cue.english)
            }
            return
        }
        if hasWaypointFeedback {
            speech.cancelPerceptionSpeech(); waypointSpeech.reset(); hasWaypointFeedback = false
        }
        if turnEpoch != snapshot.epoch || turnVersion != snapshot.parameterVersion { routeSpeech.reset() }
        // Do not interrupt an obstacle warning, or consume the one-shot latch before it can
        // actually speak. Re-evaluate the LIVE route once the current utterance finishes.
        guard !speech.isSpeakingPerception else { return }
        if turnEpoch != snapshot.epoch || turnGoal != snapshot.pathUpdate.goal?.id || turnVersion != snapshot.parameterVersion {
            turnPolicy.reset(); turnEpoch = snapshot.epoch; turnGoal = snapshot.pathUpdate.goal?.id
            turnVersion = snapshot.parameterVersion
        }
        let heading = snapshot.pathOptions.enabled ? snapshot.pathHeading(now:now) : nil
        let side = turnPolicy.update(heading:heading, now:now,
                                     threshold:snapshot.pathOptions.deviationDegrees,
                                     alignment:snapshot.pathOptions.alignmentDegrees)
        if let cue = routeSpeech.cue(strategy:snapshot.pathUpdate.strategy,side:side,hasHeading:heading != nil) {
            speech.speakPerception(cue.chinese,english:cue.english)
        }
    }
    private(set) var lastConsumedResultID: String?
    private(set) var lastSpokenResultID: String?

    func reset() { waypointSpeech.reset(); hasWaypointFeedback = false; policy.reset(); turnPolicy.reset(); routeSpeech.reset(); turnEpoch = nil; turnGoal = nil; turnVersion = nil; lastConsumedResultID = nil; lastSpokenResultID = nil }

    func consume(_ result: SceneResult, now: Double = ProcessInfo.processInfo.systemUptime,
                 speech: SpeechManager, announceCandidates: Bool = true) {
        lastConsumedResultID = result.id
        for event in policy.evaluate(result, now: now) {
            lastSpokenResultID = event.resultID
            switch event {
            case .perceptionUnavailable:
                speech.speakPerception("暂时看不清")
                return // Direction haptics are owned solely by PathHaptics.
            case .centerObstacle(_, let distance, _):
                speech.speakPerception(ObstacleRouteSpeech.level(distance, chinese: true),
                                       english: ObstacleRouteSpeech.level(distance, chinese: false))
                return

            case .observedCandidate(_, let sector):
                guard announceCandidates else { continue }
                let zh = sector == .left ? "左侧" : (sector == .right ? "右侧" : "中间")
                let en = sector == .left ? "left" : (sector == .right ? "right" : "center")
                speech.speakPerception("\(zh)可走", english: "Open on the \(en)")

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
