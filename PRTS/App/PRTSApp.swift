/// Application composition root. Creates shared speech/haptic services and hosts the restored home screen.

import SwiftUI

@main
struct PRTSApp: App {
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var hapticManager = HapticManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(speechManager)
                .environmentObject(hapticManager)
                .environment(\.locale, speechManager.interfaceLocale)
        }
    }
}
