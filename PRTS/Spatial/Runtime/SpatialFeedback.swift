/// Device feedback consumes spatial snapshots through this boundary; the runtime does not
/// construct a feature's hardware implementation.
@MainActor
protocol SpatialFeedback: AnyObject {
    var status: String { get }
    func tick(_ snapshot: SharedSnapshot, diagnostics: DiagnosticRecorder, suspended: Bool)
    func reset()
}
