/// Application composition root. Creates shared speech/haptic services and hosts the home screen.

import SwiftUI

@main
struct PRTSApp: App {
    @State private var runtimeID = UUID()
    @State private var resumeCamera = false
    @State private var resetError: String?
    @StateObject private var speechManager = SpeechManager()
    @StateObject private var hapticManager = HapticManager()

    init() {
        // Initializes product retention/migration before any feature can report an error.
        _ = ErrorLog.application
        do {
            try RecordingArchive.removePreviousExports()
        } catch {
            ErrorLog.application.record(error, source: .storage)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(
                startAutomatically: resumeCamera,
                initialError: resetError,
                restartApplication: { resume, error in
                    resumeCamera = resume
                    resetError = error
                    runtimeID = UUID()
                }
            )
                .id(runtimeID)
                .environmentObject(speechManager)
                .environmentObject(hapticManager)
                .environment(\.locale, speechManager.interfaceLocale)
        }
    }
}
