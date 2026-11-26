import Foundation
import UserNotifications
import BackgroundTasks
import UIKit

/// Turns changes in the goalie's data (a report published, film needing attention,
/// new coach feedback) into notifications. Works without a push server: the app
/// checks on launch, on return to the foreground, and in iOS background refresh.
enum ReportWatcher {
    static let refreshTaskID = "com.alkhaldi.netrix.refresh"

    enum Pref: String, CaseIterable {
        case reports = "notify.reports", feedback = "notify.feedback", uploads = "notify.uploads"
        var isOn: Bool { UserDefaults.standard.object(forKey: rawValue) as? Bool ?? true }
    }

    /// What the app last saw for a goalie, so only real changes notify.
    struct Snapshot: Codable, Equatable {
        var gameIds: Set<String> = []
        var requestStatus: [String: String] = [:]
        var noteIds: Set<String> = []
    }

    struct Change: Equatable {
        let title: String
        let body: String
        let route: String
        let pref: Pref
    }

    private static func key(_ goalieId: String) -> String { "watch.snapshot.\(goalieId)" }

    static func loadSnapshot(_ goalieId: String) -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key(goalieId)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ s: Snapshot, for goalieId: String) {
        if let data = try? JSONEncoder().encode(s) { UserDefaults.standard.set(data, forKey: key(goalieId)) }
    }

    static func snapshot(games: [Game], requests: [GameVideo], notes: [CoachNote]) -> Snapshot {
        Snapshot(gameIds: Set(games.map(\.id.value)),
                 requestStatus: Dictionary(requests.map { ($0.id.value, $0.reviewStatus.rawValue) }, uniquingKeysWith: { a, _ in a }),
                 noteIds: Set(notes.map(\.id.value)))
    }

    /// Changes since the last snapshot. The first look at an account records a baseline and reports nothing.
    static func diff(old: Snapshot?, games: [Game], requests: [GameVideo], notes: [CoachNote]) -> [Change] {
        guard let old else { return [] }
        var out: [Change] = []
        for g in games where !old.gameIds.contains(g.id.value) {
            out.append(Change(title: "Your report is ready", body: "vs \(g.opponentName): your analysis is published. Tap to see how you did.",
                              route: "game:\(g.id.value)", pref: .reports))
        }
        for r in requests {
            let before = old.requestStatus[r.id.value]
            guard before != r.reviewStatus.rawValue else { continue }
            let opp = r.requested?.opponent ?? "your game"
            switch r.reviewStatus {
            case .inReview where before != nil:
                out.append(Change(title: "Analyst review started", body: "An analyst is reviewing vs \(opp).", route: "request:\(r.id.value)", pref: .reports))
            case .needsAttention:
                out.append(Change(title: "Your game needs attention", body: r.adminNote ?? "The analyst needs something from you for vs \(opp).",
                                  route: "request:\(r.id.value)", pref: .reports))
            default: break
            }
        }
        for n in notes where !old.noteIds.contains(n.id.value) {
            out.append(Change(title: "New coach feedback", body: String(n.text.prefix(140)), route: "home", pref: .feedback))
        }
        return out
    }

    static func post(_ changes: [Change]) {
        for c in changes where c.pref.isOn {
            let content = UNMutableNotificationContent()
            content.title = c.title
            content.body = c.body
            content.sound = .default
            content.userInfo = ["route": c.route]
            content.threadIdentifier = c.pref.rawValue
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    static func requestPermissionIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: Background refresh

    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let work = Task {
                let ok = await checkInBackground()
                task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Fetches the signed-in goalie's games, film requests and notes, and notifies about changes.
    static func checkInBackground() async -> Bool {
        let db = SupabaseClient.shared
        guard let uid = await db.session?.user.id else { return true }
        do {
            let q = "user_id=eq.\(uid)"
            let games: [Game] = try await db.select("Games", query: "\(q)&select=*")
            let videos: [GameVideo] = try await db.select("game_videos",
                query: "\(q)&parent_video_id=is.null&select=id,user_id,game_id,requested_game,status,review_status,admin_note,created_at")
            let notes: [CoachNote] = (try? await db.select("coach_notes", query: "goalie_id=eq.\(uid)&select=id,text,game_id,created_at")) ?? []
            let requests = videos.filter { $0.gameId == nil && $0.reviewStatus != .approved && ($0.status ?? "") != "clip" }
            let old = loadSnapshot(uid)
            post(diff(old: old, games: games, requests: requests, notes: notes))
            save(snapshot(games: games, requests: requests, notes: notes), for: uid)
            await WidgetBridge.publish(goalieId: uid, games: games)
            return true
        } catch {
            return false
        }
    }
}
