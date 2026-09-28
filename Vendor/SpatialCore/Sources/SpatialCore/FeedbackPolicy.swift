import Foundation

public enum FeedbackEvent: Sendable, Equatable {
    case perceptionUnavailable(resultID: String)
    case centerObstacle(resultID: String, distance: Float, severity: Int)
    case observedCandidate(resultID: String, sector: Sector)
    public var resultID: String {
        switch self {
        case .perceptionUnavailable(let id), .centerObstacle(let id, _, _), .observedCandidate(let id, _): id
        }
    }
}

/// Deterministic, stateful feedback gate. It never emits from expired results and never calls a candidate safe.
public struct FeedbackPolicy: Sendable {
    private var lastResultID: String?
    private var lastUnavailableAt: Double = -.infinity
    private var lastObstacleAt: Double = -.infinity
    private var lastCandidateAt: Double = -.infinity
    private var lastSeverity = 0
    private var stableSector: Sector?
    private var stableCount = 0
    public init() {}

    public mutating func reset() {
        lastResultID = nil; lastSeverity = 0; stableSector = nil; stableCount = 0
    }

    public mutating func evaluate(_ result: SceneResult, now: Double) -> [FeedbackEvent] {
        guard result.isFresh(at: now), lastResultID != result.id else { return [] }
        lastResultID = result.id
        guard result.availability == .ready, result.tracking == .normal else {
            stableSector = nil; stableCount = 0; lastSeverity = 0
            if now - lastUnavailableAt >= 4 { lastUnavailableAt = now; return [.perceptionUnavailable(resultID: result.id)] }
            return []
        }
        var events: [FeedbackEvent] = []
        let center = result.observations.first { $0.sector == .center }?.groundDistance
        let severity: Int = center.map { $0 < 0.8 ? 2 : ($0 < 1.5 ? 1 : 0) } ?? 0
        if severity > lastSeverity && now - lastObstacleAt >= 2, let center {
            lastObstacleAt = now
            events.append(.centerObstacle(resultID: result.id, distance: center, severity: severity))
        }
        lastSeverity = severity
        let best = result.candidateChannels.sorted {
            if abs($0.minimumObservedWidth - $1.minimumObservedWidth) > 0.001 { return $0.minimumObservedWidth > $1.minimumObservedWidth }
            if abs($0.length - $1.length) > 0.001 { return $0.length > $1.length }
            return $0.sector.rawValue < $1.sector.rawValue
        }.first?.sector
        if best == stableSector { stableCount += 1 } else { stableSector = best; stableCount = best == nil ? 0 : 1 }
        if let best, stableCount == 3, now - lastCandidateAt >= 5 {
            lastCandidateAt = now
            events.append(.observedCandidate(resultID: result.id, sector: best))
        }
        return events
    }
}
