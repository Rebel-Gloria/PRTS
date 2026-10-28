/// Siri, Shortcuts, the Action button and Back Tap reach the home screen without touching it.

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

struct StartGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.start.title"
    static let description = IntentDescription("intent.start.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        HomeCommandCenter.shared.pending = .start
        return .result()
    }
}

struct StopGuidanceIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.stop.title"
    static let description = IntentDescription("intent.stop.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        HomeCommandCenter.shared.pending = .stop
        return .result()
    }
}

struct DescribeSceneIntent: AppIntent {
    static let title: LocalizedStringResource = "intent.describe.title"
    static let description = IntentDescription("intent.describe.description")
    static let openAppWhenRun = true

    @MainActor func perform() async throws -> some IntentResult {
        HomeCommandCenter.shared.pending = .describe
        return .result()
    }
}

struct PRTSShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartGuidanceIntent(),
                    phrases: ["Start \(.applicationName)", "\(.applicationName) 开始", "用 \(.applicationName) 开始避障"],
                    shortTitle: "intent.start.short", systemImageName: "play.fill")
        AppShortcut(intent: StopGuidanceIntent(),
                    phrases: ["Stop \(.applicationName)", "\(.applicationName) 停止", "停止 \(.applicationName)"],
                    shortTitle: "intent.stop.short", systemImageName: "stop.fill")
        AppShortcut(intent: DescribeSceneIntent(),
                    phrases: ["Describe with \(.applicationName)", "\(.applicationName) 描述画面", "用 \(.applicationName) 拍照描述"],
                    shortTitle: "intent.describe.short", systemImageName: "camera.fill")
    }
}
