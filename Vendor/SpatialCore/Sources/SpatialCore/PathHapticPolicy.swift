import Foundation

public struct PathHapticSegment: Codable, Sendable, Equatable {
    public var relativeTime: Double
    public var duration: Double
    public var intensity: Float
    public var sharpness: Float
    public init(relativeTime: Double,duration: Double,intensity: Float,sharpness: Float) {
        self.relativeTime = relativeTime;self.duration = duration;self.intensity = intensity;self.sharpness = sharpness
    }
}
public struct PathHapticPulse: Codable, Sendable, Equatable {
    public var kind: String
    public var intensity: Float
    public var duration: Double // Total pattern span, including the gap in a left doublet.
    public var segments: [PathHapticSegment]? = nil // Optional for reading build8/9 records.
}
/// One actuator: left=two short taps, right=one longer pulse. Repeated bounded patterns,
/// not an indefinitely queued haptic player. Alignment is ANGLE only, never a safety signal.
public struct PathHapticPolicy: Sendable {
    private var lastPulse = -Double.infinity,lastUpdate = -Double.infinity
    private var alignedSince: Double?,awaySince: Double?
    private var latched = false
    private var side = 0
    public private(set) var mode = "paused"
    public private(set) var stopCurrentPattern = false
    public init() {}
    public mutating func reset() { self = .init() }
    /// A failed API submission is not an acknowledged alignment cue.
    public mutating func reject(_ pulse: PathHapticPulse) {
        if pulse.kind == "aligned_once" { latched = false;alignedSince = nil }
        side = 0;mode = "paused";stopCurrentPattern = true
    }
    public mutating func update(heading: PathHeading?,now: Double,enabled: Bool,threshold raw: Float,alignmentDegrees rawAlignment: Float = 5) -> PathHapticPulse? {
        stopCurrentPattern = false
        guard now.isFinite,now >= lastUpdate else { stopCurrentPattern = true;return nil }
        let resumed = now-lastUpdate > 0.25
        lastUpdate = now
        guard enabled,let h = heading,h.angleDegrees.isFinite else {
            alignedSince = nil;awaySince = nil;side = 0;mode = "paused";stopCurrentPattern = true;return nil
        }
        if resumed { alignedSince = nil;awaySince = nil }
        let threshold = raw.isFinite ? min(30,max(6,raw)) : 12
        let alignment = rawAlignment.isFinite ? min(threshold-2,max(2,rawAlignment)) : min(5,threshold-2)
        let angle = abs(h.angleDegrees)
        if latched {
            mode = "aligned_latched"
            if angle >= threshold {
                if awaySince == nil { awaySince = now }
                guard now-awaySince! >= 0.25-0.000001 else { return nil }
                latched = false;side = 0;awaySince = nil
            } else { awaySince = nil;return nil }
        }
        if angle <= alignment {
            if side != 0 { stopCurrentPattern = true };side = 0
            mode = "aligning"
            if alignedSince == nil { alignedSince = now }
            guard now-alignedSince! >= 0.3-0.000001 else { return nil }
            latched = true;lastPulse = now;mode = "aligned_latched"
            return .init(kind:"aligned_once",intensity:1,duration:0.18,
                         segments:[.init(relativeTime:0,duration:0.18,intensity:1,sharpness:0.9)])
        }
        alignedSince = nil
        let nextSide = h.angleDegrees < 0 ? -1 : 1,changed = nextSide != side
        if changed { stopCurrentPattern = true };side = nextSide
        mode = side < 0 ? "left_double" : "right_long"
        let severity = min(1,max(0,(angle-alignment)/(60-alignment)))
        let interval = Double(0.85-0.4*severity)
        guard changed || now-lastPulse >= interval else { return nil }
        lastPulse = now
        let intensity: Float = 0.3+0.5*severity
        if side < 0 {
            let d = 0.06+Double(severity)*0.02,start = d+0.09
            return .init(kind:"left_double",intensity:intensity,duration:start+d,
                         segments:[.init(relativeTime:0,duration:d,intensity:intensity,sharpness:0.65),
                                   .init(relativeTime:start,duration:d,intensity:intensity,sharpness:0.65)])
        }
        let d = 0.18+Double(severity)*0.08
        return .init(kind:"right_long",intensity:intensity,duration:d,
                     segments:[.init(relativeTime:0,duration:d,intensity:intensity,sharpness:0.3)])
    }
}
