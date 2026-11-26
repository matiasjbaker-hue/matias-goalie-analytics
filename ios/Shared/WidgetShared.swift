import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// Shared between the app and the NETRIX widget extension.
enum SharedConfig {
    static let appGroup = "group.com.alkhaldi.netrix"
    static let snapshotKey = "widget.snapshot"
    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
}

/// What the home and lock screen widgets show. Written by the app, read by the widget.
struct WidgetSnapshot: Codable, Equatable {
    struct LastGame: Codable, Equatable {
        var opponent: String
        var date: Date?
        var svPct: Double?
        var gameId: String
    }
    struct Pending: Codable, Equatable {
        var opponent: String
        var status: String // "Pending", "In review", "Needs action"
    }
    var goalieName: String
    var seasonSvPct: Double?
    var gsax: Double?
    var gamesCount: Int
    var recentSv: [Double]
    var lastGame: LastGame?
    var pending: Pending?
    var updatedAt: Date

    static let placeholder = WidgetSnapshot(
        goalieName: "Alex Morgan", seasonSvPct: 91.7, gsax: 1.4, gamesCount: 8,
        recentSv: [90.1, 92.3, 89.4, 93.1, 91.0, 94.2, 90.8, 92.9],
        lastGame: LastGame(opponent: "Lakeside Hawks", date: Date(), svPct: 92.9, gameId: "0"),
        pending: Pending(opponent: "Bay Storm", status: "In review"), updatedAt: Date())

    static func load() -> WidgetSnapshot? {
        guard let data = SharedConfig.defaults?.data(forKey: SharedConfig.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { SharedConfig.defaults?.set(data, forKey: SharedConfig.snapshotKey) }
    }
}

#if canImport(ActivityKit)
/// Live Activity for a film upload: lock screen and Dynamic Island progress.
struct FilmUploadAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var phase: String // "uploading", "finishing", "done", "failed"
    }
    var opponent: String
    var fileSize: String
}
#endif
