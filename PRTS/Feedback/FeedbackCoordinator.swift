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
    private var waypointSpeechIdentity: String?
    private var turnEpoch: UInt64?
    private var turnGoal: UInt64?
    private var turnVersion: UInt64?

    /// Uses the same angle hysteresis as haptics, independently of vibration hardware.
    func consumeDirection(_ snapshot: SharedSnapshot, speech: SpeechManager,
                          now: Double = ProcessInfo.processInfo.systemUptime) {
        guard speech.voiceAnnouncementsEnabled else { turnPolicy.reset();routeSpeech.reset();waypointSpeech.reset();return }
        if snapshot.pathUpdate.waypointGuidance != nil {
            if turnEpoch != snapshot.epoch || turnVersion != snapshot.parameterVersion {
                waypointSpeech.reset(); turnEpoch = snapshot.epoch; turnVersion = snapshot.parameterVersion
            }
            guard let update = snapshot.activeWaypointUpdate(now: now), let state = update.waypointGuidance else {
                speech.cancelPerceptionSpeech(); waypointSpeech.reset(); waypointSpeechIdentity = nil
                return
            }
            let identity = "\(snapshot.epoch):\(snapshot.parameterVersion):\(update.goal?.id ?? 0):\(state.scenario.rawValue)"
            if waypointSpeechIdentity != identity {
                // A queued/spoken turn from the old goal must not survive an atomic handoff.
                speech.cancelPerceptionSpeech()
                waypointSpeechIdentity = identity
            }
            guard !speech.isSpeakingPerception else { return }
            if let cue = waypointSpeech.cue(update: update, heading: snapshot.pathHeading(now: now),
                now: now, deviationDegrees: snapshot.pathOptions.deviationDegrees) {
                speech.speakPerception(cue.chinese, english: cue.english)
            }
            return
        }
        if waypointSpeechIdentity != nil {
            speech.cancelPerceptionSpeech(); waypointSpeech.reset(); waypointSpeechIdentity = nil
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

    func reset() { waypointSpeech.reset(); waypointSpeechIdentity = nil; policy.reset(); turnPolicy.reset(); routeSpeech.reset(); turnEpoch = nil; turnGoal = nil; turnVersion = nil; lastConsumedResultID = nil; lastSpokenResultID = nil }

    /// A missing result pauses output, not the identity of a held manoeuvre. Lifecycle,
    /// settings, epoch and parameter changes still use the explicit full reset above.
    func suspendResultFeedback(now: Double = ProcessInfo.processInfo.systemUptime) {
        policy.reset();lastConsumedResultID = nil;lastSpokenResultID = nil
        _ = turnPolicy.update(heading:nil,now:now,threshold:12,alignment:5)
    }

    func consume(_ result: SceneResult, now: Double = ProcessInfo.processInfo.systemUptime,
                 speech: SpeechManager, haptics: HapticManager, announceCandidates: Bool = true) {
        lastConsumedResultID = result.id
        for event in policy.evaluate(result, now: now) {
            lastSpokenResultID = event.resultID
            switch event {
            case .perceptionUnavailable:
                speech.speakPerception("感知暂不可用")
                return // Direction haptics are owned solely by PathHaptics.
            case .centerObstacle(_, let distance, _):
                speech.speakPerception(String(format: "前方障碍，约 %.1f 米", distance),
                             english: String(format: "Obstacle ahead, about %.1f meters", distance))
                return

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
