import Foundation

enum PRTSRuntimeProfile: String, CaseIterable, Identifiable {
    case minimal
    case perception
    case fullExperimental

    var id: String { rawValue }

    var localizationKey: String {
        switch self {
        case .minimal: return "settings.runtime.profile.minimal"
        case .perception: return "settings.runtime.profile.perception"
        case .fullExperimental: return "settings.runtime.profile.fullExperimental"
        }
    }

    var loadsLargeBrain: Bool { self == .fullExperimental }
    var enablesPerception: Bool { self != .minimal }
}
