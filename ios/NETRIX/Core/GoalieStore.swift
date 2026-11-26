import Foundation
import SwiftUI

/// One row in History / Recent analysis: either an analysed game, or film still being reviewed.
struct GameEntry: Identifiable, Hashable {
    enum Kind: Hashable { case analysed(GameMetrics), request(GameVideo) }
    let kind: Kind

    var id: String {
        switch kind {
        case .analysed(let m): return "g-\(m.game.id)"
        case .request(let v): return "v-\(v.id)"
        }
    }
    var title: String {
        switch kind {
        case .analysed(let m): return "vs \(m.game.opponentName)"
        case .request(let v): return "vs \(v.requested?.opponent ?? "Opponent")"
        }
    }
    var date: Date? {
        switch kind {
        case .analysed(let m): return m.game.date
        case .request(let v): return DateParse.parse(v.requested?.date) ?? v.createdAt
        }
    }
    var status: GameStatus {
        switch kind {
        case .analysed: return .completed
        case .request(let v):
            switch v.reviewStatus {
            case .received: return .pending
            case .inReview: return .inReview
            case .needsAttention: return .needsAction
            case .approved: return .completed
            }
        }
    }
    var metrics: GameMetrics? { if case .analysed(let m) = kind { return m } else { return nil } }
    var video: GameVideo? { if case .request(let v) = kind { return v } else { return nil } }
}

enum GameStatus: String, CaseIterable, Identifiable {
    case pending = "Pending", inReview = "In review", completed = "Completed", needsAction = "Needs action"
    var id: String { rawValue }
}

/// Everything shown for one goalie: their own account, or the goalie a coach picked.
@MainActor
final class GoalieStore: ObservableObject {
    @Published private(set) var profile: Profile?
    @Published private(set) var games: [GameMetrics] = []
    @Published private(set) var requests: [GameVideo] = []
    @Published private(set) var notes: [CoachNote] = []
    @Published private(set) var access: GoalieAccess?
    /// Film that became a game (approved), for "report ready" times in the inbox.
    @Published private(set) var approvedFilms: [GameVideo] = []
    /// What changed since the app last looked (report published, needs attention, new note).
    @Published var lastChanges: [ReportWatcher.Change] = []
    @Published private(set) var isLoading = false
    @Published private(set) var hasLoaded = false
    @Published var error: AppError?

    private(set) var goalieId: String?

    func load(goalieId: String, force: Bool = false) async {
        if isLoading { return }
        if !force && hasLoaded && self.goalieId == goalieId { return }
        if self.goalieId != goalieId { reset() }
        self.goalieId = goalieId
        isLoading = true
        error = nil
        defer { isLoading = false }

        let db = SupabaseClient.shared
        let uid = "eq.\(goalieId)"
        do {
            async let profilesQ: [Profile] = db.select("profiles", query: "id=\(uid)&select=*")
            async let gamesQ: [Game] = db.select("Games", query: "user_id=\(uid)&select=*&order=date.desc")
            async let shotsQ: [Shot] = db.select("Shots", query: "user_id=\(uid)&select=*")
            async let reboundsQ: [ReboundControl] = (try? await db.select("goalierebound_control", query: "user_id=\(uid)&select=*")) ?? []
            async let videosQ: [GameVideo] = (try? await db.select("game_videos",
                query: "user_id=\(uid)&parent_video_id=is.null&select=*&order=created_at.desc")) ?? []
            async let notesQ: [CoachNote] = (try? await db.select("coach_notes", query: "goalie_id=\(uid)&select=*&order=created_at.desc")) ?? []
            async let accessQ: [GoalieAccess] = (try? await db.select("goalie_access", query: "user_id=\(uid)&select=*")) ?? []

            let (profiles, gameRows, shots, rebounds, videos, noteRows, accessRows) =
                try await (profilesQ, gamesQ, shotsQ, reboundsQ, videosQ, notesQ, accessQ)

            let shotsByGame = Dictionary(grouping: shots, by: { $0.gameId ?? "" })
            let reboundByGame = Dictionary(rebounds.map { ($0.gameId ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            profile = profiles.first
            games = gameRows
                .map { GameMetrics(game: $0, shots: shotsByGame[$0.id.value] ?? [], rebound: reboundByGame[$0.id.value]) }
                .sorted { ($0.game.date ?? .distantPast) > ($1.game.date ?? .distantPast) }
            // Film whose game already exists is shown as that game; the rest are open requests.
            requests = videos.filter { $0.gameId == nil && $0.reviewStatus != .approved && ($0.status ?? "") != "clip" }
            notes = noteRows
            access = accessRows.first
            approvedFilms = videos.filter { $0.gameId != nil && ($0.status ?? "") != "clip" }
            hasLoaded = true
            // Notice changes and refresh the home screen widget.
            let old = ReportWatcher.loadSnapshot(goalieId)
            lastChanges = ReportWatcher.diff(old: old, games: gameRows, requests: requests, notes: noteRows)
            ReportWatcher.save(ReportWatcher.snapshot(games: gameRows, requests: requests, notes: noteRows), for: goalieId)
            WidgetBridge.publish(store: self)
        } catch let e as AppError {
            error = e
        } catch {
            self.error = AppError(message: error.localizedDescription)
        }
    }

    func reset() {
        profile = nil; games = []; requests = []; notes = []; access = nil; approvedFilms = []; lastChanges = []
        hasLoaded = false
    }

    // MARK: Derived

    var entries: [GameEntry] {
        let all = requests.map { GameEntry(kind: .request($0)) } + games.map { GameEntry(kind: .analysed($0)) }
        return all.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Games in the profile's current season (all games if seasons weren't recorded).
    var seasonGames: [GameMetrics] {
        guard let season = profile?.season?.trimmingCharacters(in: .whitespaces).lowercased(), !season.isEmpty else { return games }
        let inSeason = games.filter { ($0.game.season ?? "").trimmingCharacters(in: .whitespaces).lowercased() == season }
        return inSeason.isEmpty ? games : inSeason
    }

    func games(in period: StatPeriod) -> [GameMetrics] {
        switch period {
        case .season: return seasonGames
        case .month: return games.filter { ($0.game.date ?? .distantPast) > Date().addingTimeInterval(-30 * 86400) }
        case .week: return games.filter { ($0.game.date ?? .distantPast) > Date().addingTimeInterval(-7 * 86400) }
        }
    }

    func note(for game: Game) -> CoachNote? {
        notes.first { $0.gameId == game.id.value }
    }

    var latestNote: CoachNote? { notes.first }

    func approvedAt(_ game: Game) -> Date? {
        approvedFilms.first { $0.gameId == game.id.value }?.approvedAt
    }

    // MARK: Inbox

    struct InboxItem: Identifiable, Hashable {
        enum Kind: Hashable { case report, review, attention, feedback, submitted }
        let id: String
        let kind: Kind
        let title: String
        let body: String
        let date: Date
        let route: AppRoute?
    }

    var inbox: [InboxItem] {
        var items: [InboxItem] = []
        for m in games.prefix(30) {
            let when = approvedAt(m.game) ?? m.game.date ?? .distantPast
            let sv = m.svPct.map { " · \(Fmt.pct($0))% save percentage" } ?? ""
            items.append(InboxItem(id: "g\(m.game.id)", kind: .report, title: "Report ready",
                                   body: "vs \(m.game.opponentName)\(sv)", date: when, route: .game(m)))
        }
        for r in requests {
            let opp = r.requested?.opponent ?? "your game"
            let when = r.createdAt ?? .distantPast
            switch r.reviewStatus {
            case .needsAttention:
                items.append(InboxItem(id: "r\(r.id)", kind: .attention, title: "Needs your attention",
                                       body: r.adminNote ?? "The analyst needs something from you for vs \(opp).", date: when, route: .request(r)))
            case .inReview:
                items.append(InboxItem(id: "r\(r.id)", kind: .review, title: "In review", body: "An analyst is reviewing vs \(opp).", date: when, route: .request(r)))
            default:
                items.append(InboxItem(id: "r\(r.id)", kind: .submitted, title: "Game submitted", body: "vs \(opp) is waiting for an analyst.", date: when, route: .request(r)))
            }
        }
        for n in notes.prefix(20) {
            items.append(InboxItem(id: "n\(n.id)", kind: .feedback, title: "Coach feedback", body: n.text,
                                   date: n.createdAt ?? .distantPast, route: nil))
        }
        return items.sorted { $0.date > $1.date }
    }

    private var seenKey: String { "inbox.seen.\(goalieId ?? "")" }
    var unreadCount: Int {
        let seen = UserDefaults.standard.double(forKey: seenKey)
        guard seen > 0 else { return min(inbox.count, 9) > 0 ? 1 : 0 }
        return inbox.filter { $0.date.timeIntervalSince1970 > seen }.count
    }
    func markInboxSeen() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: seenKey)
        objectWillChange.send()
    }
}

#if DEBUG
// MARK: - Debug-only sample data for visual QA in the simulator (launch with -NXScreen <name>).
// Never compiled into Release/TestFlight builds.
extension GoalieStore {
    func loadSample(empty: Bool = false) {
        func decode<T: Decodable>(_ json: String) -> [T] { (try? JSONDecoder().decode([T].self, from: Data(json.utf8))) ?? [] }
        profile = decode("""
        [{"id":"sample","full_name":"Alex Morgan","role":"goalie","team":"Northside Wolves","season":"2026-27","level":"U18 · AAA / Elite","catches":"L","height_in":70}]
        """).first
        hasLoaded = true
        guard !empty else { return }
        let opps = ["Lakeside Hawks", "Northside Wolves", "East Valley", "River City", "Harbour Kings", "Mountain Ridge", "Lakeside Hawks", "Bay Storm"]
        let rows: [(Int, Int, Int)] = [(28, 26, -3), (35, 32, -10), (24, 23, -17), (31, 28, -24), (27, 24, -31), (30, 28, -38), (22, 20, -45), (33, 30, -52)]
        var gameJSON: [String] = [], shots: [Shot] = []
        for (i, r) in rows.enumerated() {
            let d = Fmt.isoDay.string(from: Date().addingTimeInterval(Double(r.2) * 86400))
            gameJSON.append(#"{"id":\#(i + 1),"date":"\#(d)","opponent":"\#(opps[i])","home_away":"\#(i % 2 == 0 ? "Home" : "Away")","team_goals":\#(3 + i % 2),"opponent goals":\#(r.0 - r.1),"shots_against":\#(r.0),"saves":\#(r.1),"goals_against":\#(r.0 - r.1),"minutes_played":60,"season":"2026-27"}"#)
            var shotJSON: [String] = []
            for k in 0..<r.0 {
                let grade = ["A+", "A", "B", "C", "C", "B"][k % 6]
                let xg = ["A+": 0.2, "A": 0.1, "B": 0.05, "C": 0.02][grade]!
                shotJSON.append(#"{"game_id":\#(i + 1),"outcome":"\#(k < r.0 - r.1 ? "goal" : "save")","xg":\#(xg),"xg_grade":"\#(grade)"}"#)
            }
            shots += decode("[" + shotJSON.joined(separator: ",") + "]")
        }
        let games: [Game] = decode("[" + gameJSON.joined(separator: ",") + "]")
        let byGame = Dictionary(grouping: shots, by: { $0.gameId ?? "" })
        let reb: [ReboundControl] = decode(#"[{"game_id":1,"blocker_good":5,"blocker_bad":2,"pad_stick_good":6,"pad_stick_bad":1}]"#)
        self.games = games.map { GameMetrics(game: $0, shots: byGame[$0.id.value] ?? [], rebound: $0.id.value == "1" ? reb.first : nil) }
        requests = decode(#"[{"id":99,"user_id":"sample","review_status":"in_review","created_at":"\#(ISO8601DateFormatter().string(from: Date()))","requested_game":{"date":"\#(Fmt.isoDay.string(from: Date()))","opponent":"Bay Storm","team_goals":2,"opponent_goals":1,"goalie_note":"Watch my post integration.","focus_areas":["Positioning"]}}]"#)
        notes = decode(#"[{"id":1,"text":"Strong lateral movement. Work on tracking the second-chance rebound earlier.","game_id":1,"created_at":"\#(ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200)))"}]"#)
    }
}
#endif
