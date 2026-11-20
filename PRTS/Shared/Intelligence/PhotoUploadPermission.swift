import Foundation

nonisolated enum PhotoUploadPermission {
    static let key = "photoDescription.uploadAllowed"

    static func isAllowed(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}
