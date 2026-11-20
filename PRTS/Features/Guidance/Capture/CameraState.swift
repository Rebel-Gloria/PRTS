nonisolated enum CameraUnavailableReason: Equatable {
    case noRearCamera

    var localizationKey: String {
        switch self {
        case .noRearCamera:
            return "camera.error.noRearCamera"
        }
    }
}

nonisolated enum CameraState: Equatable {
    case idle
    case requestingPermission
    case starting
    case running
    case permissionDenied
    case unavailable(CameraUnavailableReason)

    func statusLocalizationKey(lowVisionMode: Bool) -> String {
        switch self {
        case .idle:
            return "camera.status.idle"
        case .requestingPermission:
            return "camera.status.requestingPermission"
        case .starting:
            return "camera.status.starting"
        case .running:
            return lowVisionMode ? "settings.lowVision" : "camera.status.running"
        case .permissionDenied:
            return "camera.status.permissionDenied"
        case .unavailable:
            return "camera.status.unavailable"
        }
    }

    var speechLocalizationKey: String {
        switch self {
        case .idle:
            return "speech.camera.idle"
        case .requestingPermission:
            return "speech.camera.requestingPermission"
        case .starting:
            return "speech.camera.starting"
        case .running:
            return "speech.camera.running"
        case .permissionDenied:
            return "speech.camera.permissionDenied"
        case .unavailable:
            return "speech.camera.unavailable"
        }
    }

    var accessibilityLocalizationKey: String {
        switch self {
        case .idle:
            return "accessibility.camera.ready"
        case .requestingPermission:
            return "accessibility.camera.requestingPermission"
        case .starting:
            return "accessibility.camera.starting"
        case .running:
            return "accessibility.camera.running"
        case .permissionDenied:
            return "accessibility.camera.permissionDenied"
        case .unavailable:
            return "accessibility.camera.unavailable"
        }
    }

    var isBusy: Bool {
        self == .requestingPermission || self == .starting
    }
}
