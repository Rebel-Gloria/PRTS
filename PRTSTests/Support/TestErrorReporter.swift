@testable import PRTS

/// Tests inject failures on purpose; those must not reach the device's product error log.
extension ErrorReporter {
    static let ignored = ErrorReporter(record: { _ in })
}
