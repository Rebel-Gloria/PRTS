import AppIntents
import Combine

enum HomeCommand: Equatable { case start, stop, describe }

/// Intents run in the app process. The home screen consumes the pending command once it is
/// active, so a cold launch from Siri still starts the camera.
@MainActor
final class HomeCommandCenter: ObservableObject {
    static let shared = HomeCommandCenter()
    @Published var pending: HomeCommand?
}
