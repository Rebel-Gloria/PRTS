/// Directional haptic policy for the fixed world-space target; never creates a route.

import CoreHaptics
import UIKit
import SpatialCore

/// One short, immediate pattern at a time. No queued timers or background vibration.
@MainActor final class PathHaptics {
    private var engine: CHHapticEngine?
    private var player: (any CHHapticPatternPlayer)?
    private var policy = PathHapticPolicy()
    private var epoch: UInt64?,version: UInt64?,goalID: UInt64?
    private var lastLog: Double = 0
    private var lastStatus = ""
    private var unavailableUntil: Double = 0
    var status = "等待路径"
    func stop(reset: Bool = false,preserveAlignment: Bool = false) {
        try? player?.stop(atTime:CHHapticTimeImmediate); player = nil
        if reset { if !preserveAlignment { policy.reset() }; engine?.stop(completionHandler:nil); engine = nil }
    }
    func tick(_ snapshot: SharedSnapshot,diagnostics: DiagnosticRecorder,suspended: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        if epoch != snapshot.epoch || version != snapshot.parameterVersion {
            stop(reset:true); epoch = snapshot.epoch; version = snapshot.parameterVersion;goalID = nil
        }
        if let id = snapshot.pathUpdate.goal?.id,id != goalID {
            stop();policy.reset();goalID = id
        }
        let requested = snapshot.pathOptions.enabled && snapshot.pathOptions.haptics && !suspended && UIApplication.shared.applicationState == .active
        let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        let enabled = requested && supported && now >= unavailableUntil
        let heading = enabled ? snapshot.pathHeading(now:now) : nil
        var pulse: PathHapticPulse?
        if heading == nil { stop() }
        pulse = policy.update(heading:heading,now:now,enabled:enabled,threshold:snapshot.pathOptions.deviationDegrees,alignmentDegrees:snapshot.pathOptions.alignmentDegrees)
        if policy.stopCurrentPattern { stop() }
        if !requested { status = "振动关闭／暂停" }
        else if !supported { status = "设备不支持触觉反馈" }
        else if now < unavailableUntil { status = "触觉错误退避中，未确认振动完成" }
        else if heading == nil { status = "振动暂停：无有效路径或方向不可用" }
        else { status = CHHapticEngine.capabilitiesForHardware().supportsHaptics ? (policy.mode == "aligned_latched" ? "已对准，静默至明显偏离（非安全确认）" : (policy.mode == "left_double" ? "连线偏左：双短振" : (policy.mode == "right_long" ? "连线偏右：长振" : "对准确认中"))) : "设备不支持触觉反馈" }
        if let pulse {
            status = play(pulse,now:now)
            if !status.hasPrefix("submitted_") { policy.reject(pulse) }
        }
        if pulse != nil || status != lastStatus || now-lastLog >= 0.5 {
            lastLog = now; lastStatus = status
            if snapshot.running || pulse != nil {
                diagnostics.pathFeedback(epoch:snapshot.epoch,frameID:snapshot.frame?.id ?? 0,pathID:snapshot.activePath(now:now)?.path.id,heading:heading,pulse:pulse,status:status)
            }
        }
    }
    private func play(_ pulse: PathHapticPulse,now: Double) -> String {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return "unsupported_haptics" }
        guard now >= unavailableUntil else { return "haptics_error_backoff" }
        do {
            if engine == nil {
                let e = try CHHapticEngine(); e.playsHapticsOnly = true; e.isAutoShutdownEnabled = true
                e.resetHandler = { [weak self] in Task { @MainActor in self?.stop(reset:true,preserveAlignment:true) } }
                e.stoppedHandler = { [weak self] _ in Task { @MainActor in self?.player = nil } }
                engine = e
            }
            guard let engine else { return "haptics_unavailable" }
            try engine.start()
            try? player?.stop(atTime:CHHapticTimeImmediate)
            let segments = pulse.segments ?? [.init(relativeTime:0,duration:pulse.duration,intensity:pulse.intensity,sharpness:0.35)]
            let events = segments.map { segment in
                CHHapticEvent(eventType:.hapticContinuous,parameters:[
                    CHHapticEventParameter(parameterID:.hapticIntensity,value:segment.intensity),
                    CHHapticEventParameter(parameterID:.hapticSharpness,value:segment.sharpness)
                ],relativeTime:segment.relativeTime,duration:segment.duration)
            }
            player = try engine.makePlayer(with:CHHapticPattern(events:events,parameters:[]))
            try player?.start(atTime:CHHapticTimeImmediate)
            return "submitted_\(pulse.kind)" // API acceptance is not proof the user felt a vibration.
        } catch {
            stop(reset:true,preserveAlignment:true); unavailableUntil = now+2
            return "haptics_error: \(error.localizedDescription)"
        }
    }
}
