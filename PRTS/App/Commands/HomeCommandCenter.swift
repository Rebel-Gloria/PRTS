import AppIntents
import Combine

/// Intents run in the app process. The home screen consumes the request once it is active, so a
/// cold launch from Siri or the Action button still starts the camera.
@MainActor
final class HomeCommandCenter: ObservableObject {
    static let shared = HomeCommandCenter()
    @Published var toggleRequested = false
}
