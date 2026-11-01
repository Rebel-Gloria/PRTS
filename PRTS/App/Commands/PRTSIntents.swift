import AppIntents
import Combine

/// The only shortcut: one Action button press starts guidance, the next stops it.
struct ToggleGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.toggle.title"
    static let description = IntentDescription("intent.toggle.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        HomeCommandCenter.shared.toggleRequested = true
        return .result()
    }
}

struct PRTSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // Neutral phrases only: "Stop" would start guidance when it is not running.
        AppShortcut(
            intent: ToggleGuidanceIntent(),
            phrases: [
                "Start or stop \(.applicationName)", "开始或停止 \(.applicationName)",
                "\(.applicationName) 开始或停止",
            ],
            shortTitle: "intent.toggle.short",
            systemImageName: "playpause.fill"
        )
    }
}
