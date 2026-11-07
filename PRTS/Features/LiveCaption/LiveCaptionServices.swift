import Foundation

@MainActor
struct LiveCaptionServices {
    var errors = ErrorReporter(source: .liveCaption)
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var uploadAllowed: () -> Bool
    var provider: () -> PhotoChatProvider

    init(defaults: UserDefaults = .standard) {
        uploadAllowed = { defaults.bool(forKey: "photoDescription.uploadAllowed") }
        provider = { LiveCaptionModel.current(defaults) }
    }
}
