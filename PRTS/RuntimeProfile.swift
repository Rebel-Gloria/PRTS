import Foundation

enum PRTSRuntimeProfile: String, CaseIterable, Identifiable {
    case minimal
    case perception
    case fullExperimental

    var id: String { rawValue }
    var label: String {
        switch self {
        case .minimal: return "Minimal — UI, camera, system TTS, contracts"
        case .perception: return "Perception — segmentation/detection (when available)"
        case .fullExperimental: return "Full / experimental — explicitly opt in"
        }
    }

    var loadsLargeBrain: Bool { self == .fullExperimental }
    var enablesPerception: Bool { self != .minimal }
}
