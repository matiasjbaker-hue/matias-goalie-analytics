import Foundation

/// Numbers shown in the app, computed the same way the website computes them
/// (index.html: computeGoalieSummary, calculateAdvancedForShots, computeGoalieReboundSummary).
/// Every figure traces back to a tagged shot or the game's own totals; nothing is estimated.
struct GameMetrics: Hashable {
    let game: Game
    let shotsAgainst: Int
    let saves: Int
    let goals: Int
    let minutes: Double?
    let taggedShots: Int
    let xGA: Double?
    let highDangerShots: Int
    let highDangerSaves: Int
    let reboundGood: Int
    let reboundTracked: Int
    let gradeCounts: [String: (shots: Int, saves: Int)]

    static func == (l: GameMetrics, r: GameMetrics) -> Bool { l.game.id == r.game.id }
    func hash(into h: inout Hasher) { h.combine(game.id) }

    var svPct: Double? { shotsAgainst > 0 ? Double(saves) / Double(shotsAgainst) * 100 : nil }
    var gaa: Double? {
        guard let minutes, minutes > 0 else { return nil }
        return Double(goals) / (minutes / 60)
    }
    /// Goals saved above expected: expected goals from tagged shots minus actual goals on them.
    var gsax: Double? {
        guard let xGA, taggedShots > 0 else { return nil }
        let taggedGoals = taggedGoalsCount
        return xGA - Double(taggedGoals)
    }
    private(set) var taggedGoalsCount: Int = 0
    var expectedSvPct: Double? {
        guard let xGA, taggedShots > 0 else { return nil }
        return (1 - xGA / Double(taggedShots)) * 100
    }
    var highDangerSvPct: Double? { highDangerShots > 0 ? Double(highDangerSaves) / Double(highDangerShots) * 100 : nil }
    var reboundGoodPct: Double? { reboundTracked > 0 ? Double(reboundGood) / Double(reboundTracked) * 100 : nil }

    init(game: Game, shots: [Shot], rebound: ReboundControl?) {
        self.game = game
        let tagged = shots
        let taggedGoals = tagged.filter(\.isGoal).count
        let fromGame = game.shotsAgainst ?? 0
        // Prefer the game's own totals; fall back to tagged shots when totals weren't entered.
        let sa = fromGame > 0 ? fromGame : tagged.count
        let ga = game.goalsAgainst ?? (fromGame > 0 ? max(0, fromGame - (game.saves ?? fromGame)) : taggedGoals)
        shotsAgainst = sa
        goals = ga
        saves = game.saves ?? max(0, sa - ga)
        minutes = game.minutesPlayed ?? game.gameLength
        taggedShots = tagged.count
        taggedGoalsCount = taggedGoals
        let xgs = tagged.compactMap(\.xg)
        xGA = xgs.isEmpty ? nil : xgs.reduce(0, +)
        let hd = tagged.filter(\.isHighDanger)
        highDangerShots = hd.count
        highDangerSaves = hd.filter { !$0.isGoal }.count
        reboundGood = rebound?.good ?? 0
        reboundTracked = (rebound?.good ?? 0) + (rebound?.bad ?? 0)
        var grades: [String: (Int, Int)] = [:]
        for s in tagged {
            let g = s.grade ?? "—"
            let cur = grades[g] ?? (0, 0)
            grades[g] = (cur.0 + 1, cur.1 + (s.isGoal ? 0 : 1))
        }
        gradeCounts = grades.mapValues { (shots: $0.0, saves: $0.1) }
    }
}

enum StatPeriod: String, CaseIterable, Identifiable {
    case week = "Week", month = "Month", season = "Season"
    var id: String { rawValue }
}

/// Totals over a set of games (a season, a month...).
struct SummaryMetrics {
    let games: [GameMetrics]

    var count: Int { games.count }
    var shotsAgainst: Int { games.reduce(0) { $0 + $1.shotsAgainst } }
    var saves: Int { games.reduce(0) { $0 + $1.saves } }
    var goals: Int { games.reduce(0) { $0 + $1.goals } }
    var svPct: Double? { shotsAgainst > 0 ? Double(saves) / Double(shotsAgainst) * 100 : nil }
    var gaa: Double? {
        let mins = games.compactMap(\.minutes).reduce(0, +)
        let goalsWithMinutes = games.filter { $0.minutes != nil }.reduce(0) { $0 + $1.goals }
        return mins > 0 ? Double(goalsWithMinutes) / (mins / 60) : nil
    }
    var goalsPerGame: Double? { count > 0 ? Double(goals) / Double(count) : nil }
    var shotsPerGame: Double? { count > 0 ? Double(shotsAgainst) / Double(count) : nil }
    var savesPerGame: Double? { count > 0 ? Double(saves) / Double(count) : nil }
    var gsax: Double? {
        let vals = games.compactMap(\.gsax)
        return vals.isEmpty ? nil : vals.reduce(0, +)
    }
    var highDangerSvPct: Double? {
        let s = games.reduce(0) { $0 + $1.highDangerShots }
        let v = games.reduce(0) { $0 + $1.highDangerSaves }
        return s > 0 ? Double(v) / Double(s) * 100 : nil
    }
    var reboundGoodPct: Double? {
        let t = games.reduce(0) { $0 + $1.reboundTracked }
        let g = games.reduce(0) { $0 + $1.reboundGood }
        return t > 0 ? Double(g) / Double(t) * 100 : nil
    }
    var expectedSvPct: Double? {
        let tagged = games.reduce(0) { $0 + $1.taggedShots }
        let xga = games.compactMap(\.xGA).reduce(0, +)
        return tagged > 0 ? (1 - xga / Double(tagged)) * 100 : nil
    }
    var taggedShots: Int { games.reduce(0) { $0 + $1.taggedShots } }
}

// MARK: - Formatting

enum Fmt {
    static func pct(_ v: Double?, digits: Int = 1) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }
    static func signed(_ v: Double?, digits: Int = 1) -> String {
        guard let v else { return "—" }
        let r = (v * pow(10, Double(digits))).rounded() / pow(10, Double(digits))
        return (r > 0 ? "+" : "") + String(format: "%.\(digits)f", r)
    }
    static func num(_ v: Double?, digits: Int = 1) -> String {
        guard let v else { return "—" }
        return String(format: "%.\(digits)f", v)
    }
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f
    }()
    static let longDate: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE d MMM yyyy"; return f
    }()
    static let monthYear: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"; return f
    }()
    static let dayMonth: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM"; return f
    }()
    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func relative(_ d: Date?) -> String {
        guard let d else { return "" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
}
