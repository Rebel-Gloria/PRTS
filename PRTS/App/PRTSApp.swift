/// Application composition root. Creates shared speech/haptic services and hosts the home screen.

import SwiftUI

@main
struct PRTSApp: App {
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var hapticManager = HapticManager()

    init() {
        // Initializes product retention/migration before any feature can report an error.
        _ = ErrorLog.application
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speechManager)
                .environmentObject(hapticManager)
                .environment(\.locale, speechManager.interfaceLocale)
        }
    }
}
