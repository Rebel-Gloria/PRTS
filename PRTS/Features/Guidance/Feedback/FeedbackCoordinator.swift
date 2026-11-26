import Combine
import Foundation
import SpatialCore

@MainActor
final class FeedbackCoordinator: ObservableObject {
    private var policy = FeedbackPolicy()
    private var turnPolicy = TurnAnnouncementPolicy()
    private var routeSpeech = RouteAnnouncementPolicy()
    private var session = WaypointFeedbackSession()
    var reportedLoss: Bool { session.alerts.reportedLoss }

    private var hasWaypointFeedback = false
    private var turnGoal: UInt64?
    private var mutedSpeechThrough: UInt64 = 0
    private var withheldRouteThrough: UInt64 = 0

    func synchronizeSession(_ snapshot: SharedSnapshot, speech: SpeechManager) {
        if session.synchronize(
            epoch: snapshot.epoch,
            parameterVersion: snapshot.parameterVersion,
            planningEnabled: snapshot.pathOptions.enabled
        ) {
            resetFallback()
            speech.cancelPerceptionSpeech()
        }
    }

    /// Runs whenever vibration may play, also while live captions own the voice.
    func alert(
        _ snapshot: SharedSnapshot,
        waypoint: PathUpdate?,
        now: Double
    ) -> GuidanceAlert? {
        guard snapshot.running, snapshot.pathOptions.enabled, snapshot.geometryEnabled,
            !snapshot.interrupted, snapshot.frozen == nil, snapshot.thermalRaw < 3
        else {
            resetAlerts()
            return nil
        }
        let evidence = snapshot.feedbackEvidence(now: now)
        if let evidence, evidence != .mapped, let result = snapshot.result {
            withheldRouteThrough = max(withheldRouteThrough, result.frameID)
        }
        let eligible = (waypoint?.continuity?.frameID ?? 0) > withheldRouteThrough
        if evidence == .fullFieldObstacle {
            // This can interrupt loss, but it is not recovery of a navigable route.
            resetAlerts()
            return nil
        }
        if evidence == nil, eligible {
            // A retained route prevents a spurious loss, but isn't new evidence of recovery.
            resetAlerts()
            return nil
        }
        let available = eligible && evidence == .mapped
        return session.alerts.update(
            available: available,
            blocked: evidence == .mapped && waypoint?.waypointGuidance?.scenario == .blocked,
            leftMappedArea: !available && snapshot.hasLeftMappedArea(now: now),
            now: now
        )
    }

    /// Reset only the active alert timers; a new session discards the latches as well.
    func resetAlerts() { session.alerts.pause() }

    func pauseSpeech(through frameID: UInt64? = nil) {
        if let frameID { mutedSpeechThrough = max(mutedSpeechThrough, frameID) }
        session.speech.pauseObservations()
        policy.reset()  // A raw-sector candidate still needs consecutive observations.
    }

    func speakLoss(using speech: SpeechManager) {
        guard speech.voiceAnnouncementsEnabled else { return }
        session.speech.reset()  // Recovery can supersede this spoken loss, not a muted haptic.
        speech.speakPerception(speech.interfaceString("speech.guidance.lost"))
    }

    func consume(
        _ snapshot: SharedSnapshot,
        waypoint: PathUpdate?,
        raw: SceneResult?,
        speech: SpeechManager,
        now: Double
    ) {
        guard speech.voiceAnnouncementsEnabled else {
            pauseSpeech(through: snapshot.latestFeedbackFrameID)
            return
        }
        let evidence = snapshot.feedbackEvidence(now: now)
        if let result = snapshot.result, let evidence, evidence != .mapped {
            pauseSpeech()
            if evidence == .fullFieldObstacle {
                if result.frameID > mutedSpeechThrough,
                    let cue = session.speech.fullFieldCue(measuredAt: result.timestamp)
                {
                    speech.speakPerception(cue.chinese, english: cue.english)
                }
            } else if !session.speech.lastCueWasFullField && !reportedLoss {
                speech.cancelPerceptionSpeech()
            }
            return
        }
        // A reported loss or an already-issued close warning may finish during a depth gap.
        guard !reportedLoss else { return }
        guard evidence == .mapped, let result = snapshot.result,
            result.frameID > mutedSpeechThrough
        else {
            pauseSpeech()
            if waypoint == nil && !session.speech.lastCueWasFullField {
                speech.cancelPerceptionSpeech()
            }
            return
        }
        if snapshot.pathOptions.enabled {
            let routeFrame = snapshot.pathUpdate.continuity?.frameID
            guard (routeFrame ?? 0) > max(mutedSpeechThrough, withheldRouteThrough) else {
                pauseSpeech()
                return
            }
            consumeDirection(snapshot, waypoint: waypoint, speech: speech, now: now)
        } else if let raw, raw.frame.sessionEpoch == result.epoch,
            raw.frame.parameterVersion == result.parameterVersion,
            raw.frame.frameID == result.frameID
        {
            consume(raw, now: now, speech: speech)
        }
    }

    /// Uses the same angle hysteresis as haptics, independently of vibration hardware.
    private func consumeDirection(
        _ snapshot: SharedSnapshot,
        waypoint: PathUpdate?,
        speech: SpeechManager,
        now: Double
    ) {
        if waypoint != nil || snapshot.pathUpdate.waypointGuidance != nil {
            hasWaypointFeedback = true
            guard let update = waypoint else {
                session.speech.pauseObservations()
                speech.cancelPerceptionSpeech()
                return
            }
            let canStart = update.canStartWaypointFeedback(
                now: now,
                maxAge: snapshot.parameters.maxResultAge
            )
            let heading = snapshot.pathHeading(now: now)
            if session.speech.interruptIfObsolete(
                update: update,
                heading: heading,
                threshold: snapshot.pathOptions.deviationDegrees,
                newObservation: canStart
            ) {
                speech.cancelPerceptionSpeech()
            }
            guard canStart else {
                session.speech.pauseObservations()
                return
            }
            if let cue = session.speech.cue(
                update: update,
                heading: heading,
                now: now,
                deviationDegrees: snapshot.pathOptions.deviationDegrees,
                alignmentDegrees: snapshot.pathOptions.alignmentDegrees,
                maxResultAge: snapshot.parameters.maxResultAge,
                canSpeak: !speech.isSpeakingPerception
            ) {
                speech.speakPerception(cue.chinese, english: cue.english)
            }
            return
        }
        if hasWaypointFeedback {
            speech.cancelPerceptionSpeech()
            session.speech.pauseObservations()
            hasWaypointFeedback = false
        }
        // Do not interrupt an obstacle warning, or consume the one-shot latch before it can
        // actually speak. Re-evaluate the LIVE route once the current utterance finishes.
        guard !speech.isSpeakingPerception else { return }
        if turnGoal != snapshot.pathUpdate.goal?.id {
            turnPolicy.reset()
            turnGoal = snapshot.pathUpdate.goal?.id
        }
        let heading = snapshot.pathOptions.enabled ? snapshot.pathHeading(now: now) : nil
        let side = turnPolicy.update(
            heading: heading,
            now: now,
            threshold: snapshot.pathOptions.deviationDegrees,
            alignment: snapshot.pathOptions.alignmentDegrees
        )
        if let cue = routeSpeech.cue(
            strategy: snapshot.pathUpdate.strategy,
            side: side,
            hasHeading: heading != nil
        ) {
            session.speech.reset()
            speech.speakPerception(cue.chinese, english: cue.english)
        }
    }

    private(set) var lastConsumedResultID: String?
    private(set) var lastSpokenResultID: String?

    func reset() {
        session = .init()
        resetFallback()
    }

    private func resetFallback() {
        hasWaypointFeedback = false
        policy = .init()
        turnPolicy.reset()
        routeSpeech.reset()
        turnGoal = nil
        mutedSpeechThrough = 0
        withheldRouteThrough = 0
        lastConsumedResultID = nil
        lastSpokenResultID = nil
    }

    func consume(
        _ result: SceneResult,
        now: Double = ProcessInfo.processInfo.systemUptime,
        speech: SpeechManager,
        announceCandidates: Bool = true
    ) {
        lastConsumedResultID = result.id
        for event in policy.evaluate(result, now: now) {
            switch event {
            case .perceptionUnavailable:
                session.speech.reset()
                lastSpokenResultID = event.resultID
                speech.speakPerception("暂时看不清", english: "Can't see clearly")
                return
            case .centerObstacle(_, let distance, _):
                session.speech.reset()
                lastSpokenResultID = event.resultID
                speech.speakPerception(
                    ObstacleRouteSpeech.level(distance, chinese: true),
                    english: ObstacleRouteSpeech.level(distance, chinese: false)
                )
                return

            case .observedCandidate(_, let sector):
                guard announceCandidates else { continue }
                session.speech.reset()
                lastSpokenResultID = event.resultID
                let zh = sector == .left ? "左侧" : (sector == .right ? "右侧" : "中间")
                let en = sector == .left ? "left" : (sector == .right ? "right" : "center")
                speech.speakPerception("\(zh)可走", english: "Open on the \(en)")

            }
        }
    }
}
