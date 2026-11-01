import AppIntents
import Combine

/// Starts the camera or leaves text reading. Keep the intent type for saved shortcuts.
struct ToggleGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.toggle.title"
    static let description = IntentDescription("intent.toggle.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        HomeCommandCenter.shared.startRequested = true
        return .result()
    }
}

struct PRTSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Start requests never stop an already running camera.
        AppShortcut(
            intent: ToggleGuidanceIntent(),
            phrases: [
                "Start \(.applicationName)", "开始 \(.applicationName)",
                "\(.applicationName) 开始",
            ],
            shortTitle: "intent.toggle.short",
            systemImageName: "play.fill"
        )
    }
}
