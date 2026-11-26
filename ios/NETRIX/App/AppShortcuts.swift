import AppIntents
import Foundation

/// Routes requested before the UI is ready (Shortcuts, Siri, widgets) wait here.
enum LaunchRoute {
    static var pending: String?
    static func open(_ route: String) {
        pending = route
        NotificationCenter.default.post(name: .openRoute, object: route)
    }
}

struct SubmitGameIntent: AppIntent {
    static var title: LocalizedStringResource = "Submit a game"
    static var description = IntentDescription("Start submitting game film to NETRIX for analysis.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { LaunchRoute.open("submit"); return .result() }
}

struct ShowStatsIntent: AppIntent {
    static var title: LocalizedStringResource = "Show my season stats"
    static var description = IntentDescription("Open your NETRIX performance trends.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { LaunchRoute.open("stats"); return .result() }
}

struct ShowLatestReportIntent: AppIntent {
    static var title: LocalizedStringResource = "Show my latest report"
    static var description = IntentDescription("Open your most recent NETRIX game report.")
    static var openAppWhenRun = true
    @MainActor func perform() async throws -> some IntentResult { LaunchRoute.open("latest"); return .result() }
}

struct NetrixShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SubmitGameIntent(), phrases: ["Submit a game to \(.applicationName)", "Upload game film to \(.applicationName)"],
                    shortTitle: "Submit a game", systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ShowLatestReportIntent(), phrases: ["Show my latest \(.applicationName) report"],
                    shortTitle: "Latest report", systemImageName: "chart.bar.doc.horizontal")
        AppShortcut(intent: ShowStatsIntent(), phrases: ["Show my \(.applicationName) stats"],
                    shortTitle: "Season stats", systemImageName: "chart.line.uptrend.xyaxis")
    }
}
