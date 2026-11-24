import Foundation

public enum DiagnosticStream: String, Codable, Sendable, CaseIterable {
    case events, capture, analysis, render, mesh, heartbeat, prediction, path
}

public struct DiagnosticPacket: Sendable {
    public var json: Data
    public var binary: Data?
    public init(json: Data, binary: Data? = nil) {
        self.json = json
        self.binary = binary
    }
}

public enum DiagnosticJSON {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "+inf",
            negativeInfinity: "-inf",
            nan: "nan"
        )
        return try encoder.encode(value)
    }
}

public struct DiagnosticStatus: Codable, Sendable {
    public var runID: String = ""
    public var bytesWritten = 0
    public var pending = 0
    public var pendingBytes = 0
    public var attempted: [String: Int] = [:]
    public var written: [String: Int] = [:]
    public var dropped: [String: Int] = [:]
    public var failed: [String: Int] = [:]
    public var error: String?
    public var limitReached = false
    public var lastCheckpointUptime: Double = 0
    public var lastLifecycle = "launch"
    public var maximumPendingObserved = 0
    public var maximumPendingBytesObserved = 0
    public var lastQueueWaitMS: Double = 0
    public var lastEncodeMS: Double = 0
    public var lastCompressionMS: Double = 0
    public var lastWriteMS: Double = 0
    public var droppedTotal: Int { dropped.values.reduce(0, +) }
    public init() {}
}
